defmodule LdHost.ObligationHoldTest do
  use ExUnit.Case

  alias LdHost.{Dispatcher, Ledger, Obligation, Progress, Space}

  defp tmp(prefix) do
    dir =
      System.tmp_dir!()
      |> Path.join(
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp orchestrator(space_opts \\ []) do
    {:ok, ledger} = Ledger.start_link(tmp("ldhold-orch"))
    extra = Keyword.get(space_opts, :record)

    record = fn kind, payload ->
      Ledger.trace(ledger, kind, payload)
      if is_function(extra, 2), do: extra.(kind, payload)
    end

    {:ok, space} = Space.start_link(Keyword.put(space_opts, :record, record))
    {:ok, dispatcher} = Dispatcher.start_link(space: space, ledger: ledger)
    %{space: space, ledger: ledger, dispatcher: dispatcher}
  end

  defp spawn_held_os_pid do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :hide, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      kill_os_pid(pid)
    end)

    {port, pid}
  end

  defp kill_os_pid(pid) do
    System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp wait_until(fun, deadline_ms \\ 5_000) do
    if fun.() do
      :ok
    else
      if deadline_ms <= 0, do: flunk("condition never became true")
      Process.sleep(20)
      wait_until(fun, deadline_ms - 20)
    end
  end

  defp trace_events(ledger) do
    ledger
    |> then(&:sys.get_state(&1).run_dir)
    |> Path.join("trace.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp count_type(events, type), do: Enum.count(events, &(&1["type"] == type))

  setup do
    for pid <- Task.Supervisor.children(LdHost.ObligationTaskSup), do: Process.exit(pid, :kill)
    :ok
  end

  test "hold keeps the lease live while probes pass, then acks; model stays off" do
    me = self()

    planner_fn = fn _g, _o, _f ->
      send(me, :planner_called)
      {:error, "should not plan during hold"}
    end

    %{space: space, ledger: ledger, dispatcher: dispatcher} = orchestrator()

    :sys.replace_state(dispatcher, fn state ->
      %{state | run_opts: [planner_fn: planner_fn, max_episodes: 1]}
    end)

    {_port, os_pid} = spawn_held_os_pid()
    ws = tmp("ldhold")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-1",
        "goal" => "keep pid alive",
        "workspace" => ws,
        "hold_ms" => 400,
        "probe" => %{"kind" => "check", "command" => "kill -0 #{os_pid}", "timeout_seconds" => 5}
      })

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :spawned}, 2_000
    assert Space.leased_count(space) == 1
    Process.sleep(80)
    assert Space.leased_count(space) == 1

    assert_receive {:ld_progress, {:obligation, "hold-1"}, {:completed, summary}}, 3_000
    assert summary.success
    assert summary.hold_ms == 400
    assert summary.probes >= 1
    assert summary.model_calls == 0
    refute_received :planner_called

    Dispatcher.await_idle(dispatcher)
    assert Space.leased_count(space) == 0
    assert Space.bag_size(space) == 0

    events = trace_events(ledger)
    assert count_type(events, "obligation.completed") == 1
    assert count_type(events, "obligation.spawned") == 1
    assert count_type(events, "space.ack") == 1
    assert count_type(events, "space.lease_expired") == 0

    assert Enum.any?(events, fn e ->
             e["type"] == "obligation.completed" and get_in(e, ["data", "hold_ms"]) == 400
           end)
  end

  test "deterministic failing probe stops at max_attempts with backoff; ack not expire-and-retake" do
    me = self()

    %{space: space, ledger: ledger, dispatcher: dispatcher} =
      orchestrator(record: fn kind, payload -> send(me, {:space, kind, payload}) end)

    planner_fn = fn _g, _o, _f ->
      send(me, :planner_called)
      {:error, "should not plan during hold"}
    end

    :sys.replace_state(dispatcher, fn state ->
      %{state | run_opts: [planner_fn: planner_fn, max_episodes: 1]}
    end)

    ws = tmp("ldhold-fail")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-fail",
        "goal" => "probe false",
        "workspace" => ws,
        "hold_ms" => 5_000,
        "max_attempts" => 3,
        "backoff_ms" => 40,
        "probe" => %{"kind" => "check", "command" => "false", "timeout_seconds" => 5}
      })

    assert_receive {:ld_progress, {:obligation, "hold-fail"}, :spawned}, 2_000
    wait_until(fn -> map_size(:sys.get_state(dispatcher).running) == 1 end)
    %{claim: claim} = hd(Map.values(:sys.get_state(dispatcher).running))
    stale = claim.token

    assert_receive {:ld_progress, {:obligation, "hold-fail"}, {:failed, summary}}, 3_000
    assert summary.probe_failed
    refute summary.success
    assert summary.probes == 3
    assert summary.max_attempts == 3
    assert length(summary.attempt_log) == 3
    assert Enum.all?(summary.attempt_log, &(&1.returncode != 0))

    gaps =
      summary.attempt_log
      |> Enum.map(& &1.at_ms)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)

    assert length(gaps) == 2
    assert Enum.all?(gaps, &(&1 >= 30))

    Dispatcher.await_idle(dispatcher, 2_000)
    assert Space.bag_size(space) == 0
    assert Space.leased_count(space) == 0
    refute Space.ack(space, stale)
    refute_received :planner_called
    refute_received {:space, "space.lease_expired", _}

    # Stay idle: no hot retake.
    Process.sleep(150)
    refute_received {:ld_progress, {:obligation, "hold-fail"}, :spawned}

    events = trace_events(ledger)
    assert count_type(events, "obligation.spawned") == 1
    assert count_type(events, "obligation.failed") == 1
    assert count_type(events, "obligation.completed") == 0
    assert count_type(events, "space.ack") == 1
    assert count_type(events, "space.take") == 1
    assert count_type(events, "space.lease_expired") == 0

    failed = Enum.find(events, &(&1["type"] == "obligation.failed"))
    assert get_in(failed, ["data", "probe_failed"]) == true
    assert get_in(failed, ["data", "max_attempts"]) == 3
    assert get_in(failed, ["data", "probes"]) == 3

    types = Enum.map(events, & &1["type"])
    spawned_at = Enum.find_index(types, &(&1 == "obligation.spawned"))
    failed_at = Enum.find_index(types, &(&1 == "obligation.failed"))
    assert spawned_at < failed_at
  end

  test "killing the pid before hold_ms fails with no planner_fn call and no retake" do
    me = self()

    %{space: space, ledger: ledger, dispatcher: dispatcher} =
      orchestrator(record: fn kind, payload -> send(me, {:space, kind, payload}) end)

    planner_fn = fn _goal, _obs, _feedback ->
      send(me, :planner_called)
      {:error, "should not plan during hold"}
    end

    :sys.replace_state(dispatcher, fn state ->
      %{state | run_opts: [planner_fn: planner_fn, max_episodes: 1]}
    end)

    {_port, os_pid} = spawn_held_os_pid()
    ws = tmp("ldhold-kill")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-1",
        "goal" => "keep pid alive",
        "workspace" => ws,
        "hold_ms" => 2_000,
        "max_attempts" => 1,
        "probe" => %{"kind" => "check", "command" => "kill -0 #{os_pid}", "timeout_seconds" => 5}
      })

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :spawned}, 2_000
    wait_until(fn -> map_size(:sys.get_state(dispatcher).running) == 1 end)
    %{claim: claim} = hd(Map.values(:sys.get_state(dispatcher).running))
    stale = claim.token

    kill_os_pid(os_pid)

    assert_receive {:ld_progress, {:obligation, "hold-1"}, {:failed, summary}}, 3_000
    assert summary.probe_failed
    refute summary.success
    refute_received {:space, "space.lease_expired", _}
    assert_receive {:space, "space.ack", _}, 1_000
    refute Space.ack(space, stale)

    Dispatcher.await_idle(dispatcher)
    refute_received :planner_called
    Process.sleep(80)
    refute_received {:ld_progress, {:obligation, "hold-1"}, :spawned}

    events = trace_events(ledger)
    assert count_type(events, "obligation.failed") == 1
    assert count_type(events, "space.lease_expired") == 0
    assert count_type(events, "space.take") == 1
  end

  test "killing the agent mid-hold expires the lease; sibling retake; stale token cannot ack twice" do
    me = self()

    %{space: space, ledger: ledger, dispatcher: dispatcher} =
      orchestrator(record: fn kind, payload -> send(me, {:space, kind, payload}) end)

    {_port, os_pid} = spawn_held_os_pid()
    ws = tmp("ldhold-crash")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-1",
        "goal" => "keep pid alive",
        "workspace" => ws,
        "hold_ms" => 800,
        "probe" => %{"kind" => "check", "command" => "kill -0 #{os_pid}", "timeout_seconds" => 5}
      })

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :spawned}, 2_000

    wait_until(fn -> map_size(:sys.get_state(dispatcher).running) == 1 end)
    %{claim: claim, pid: task_pid} = hd(Map.values(:sys.get_state(dispatcher).running))
    stale = claim.token
    assert claim.generation == 1
    assert Process.alive?(task_pid)

    Process.exit(task_pid, :kill)

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :crashed}, 2_000
    assert_receive {:space, "space.lease_expired", %{generation: 1}}, 2_000

    refute Space.ack(space, stale)

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :spawned}, 2_000
    assert_receive {:space, "space.take", %{generation: 2}}, 2_000
    assert Space.leased_count(space) == 1

    wait_until(fn -> map_size(:sys.get_state(dispatcher).running) == 1 end)
    %{claim: claim2} = hd(Map.values(:sys.get_state(dispatcher).running))
    live = claim2.token
    assert claim2.generation == 2

    assert_receive {:ld_progress, {:obligation, "hold-1"}, {:completed, summary}}, 5_000
    assert summary.success
    Dispatcher.await_idle(dispatcher)
    assert Space.bag_size(space) == 0
    refute Space.ack(space, stale)
    refute Space.ack(space, live)

    events = trace_events(ledger)
    assert count_type(events, "obligation.crashed") == 1
    assert count_type(events, "obligation.completed") == 1
    assert count_type(events, "space.ack") == 1
    assert count_type(events, "space.lease_expired") == 1
    assert count_type(events, "space.take") == 2
  end

  test "hold/4 itself is bounded: false probe never exceeds max_attempts" do
    ws = tmp("ldhold-direct")

    {status, summary} =
      Obligation.hold(ws, %{"command" => "false", "timeout_seconds" => 2}, 10_000,
        max_attempts: 2,
        backoff_ms: 20
      )

    assert status == :failed
    assert summary.probe_failed
    assert summary.probes == 2
    assert summary.model_calls == 0
    assert length(summary.attempt_log) == 2
  end

  test "hold/4 fail-closed when deadline expires mid fail streak" do
    ws = tmp("ldhold-deadline")

    {status, summary} =
      Obligation.hold(ws, %{"command" => "false", "timeout_seconds" => 2}, 50,
        max_attempts: 3,
        backoff_ms: 40
      )

    assert status == :failed
    assert summary.probe_failed
    refute summary.success
    assert summary.probes >= 1
    assert summary.probes < 3
    assert summary.consecutive_fails < 3
    assert summary.consecutive_fails == summary.probes
  end

  test "hold/4 missing or unparseable probe fails closed without Cmd.sh" do
    ws = tmp("ldhold-noprobe")

    for probe <- [nil, %{}, %{"command" => ""}, %{"command" => "   "}, "not-a-map"] do
      {status, summary} = Obligation.hold(ws, probe, 10_000)
      assert status == :failed
      assert summary.probe_failed
      refute summary.success
      assert summary.probes == 0
      assert summary.attempt_log == []
    end
  end

  test "missing probe is acked, not expired-and-retaken" do
    me = self()

    %{space: space, ledger: ledger, dispatcher: dispatcher} =
      orchestrator(record: fn kind, payload -> send(me, {:space, kind, payload}) end)

    planner_fn = fn _g, _o, _f ->
      send(me, :planner_called)
      {:error, "should not plan during hold"}
    end

    :sys.replace_state(dispatcher, fn state ->
      %{state | run_opts: [planner_fn: planner_fn, max_episodes: 1]}
    end)

    ws = tmp("ldhold-noprobe-disp")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-noprobe",
        "goal" => "timer without probe",
        "workspace" => ws,
        "hold_ms" => 5_000
      })

    assert_receive {:ld_progress, {:obligation, "hold-noprobe"}, :spawned}, 2_000
    assert_receive {:ld_progress, {:obligation, "hold-noprobe"}, {:failed, summary}}, 2_000
    assert summary.probe_failed
    refute summary.success
    refute_received :planner_called
    refute_received {:space, "space.lease_expired", _}

    Dispatcher.await_idle(dispatcher, 2_000)
    Process.sleep(80)
    refute_received {:ld_progress, {:obligation, "hold-noprobe"}, :spawned}

    events = trace_events(ledger)
    assert count_type(events, "obligation.failed") == 1
    assert count_type(events, "space.ack") == 1
    assert count_type(events, "space.take") == 1
    assert count_type(events, "space.lease_expired") == 0
  end
end
