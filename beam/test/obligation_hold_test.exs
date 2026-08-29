defmodule LdHost.ObligationHoldTest do
  use ExUnit.Case

  alias LdHost.{Dispatcher, Ledger, Progress, Space}

  defp tmp(prefix) do
    dir =
      System.tmp_dir!()
      |> Path.join("#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end

  defp orchestrator(space_opts \\ []) do
    {:ok, space} = Space.start_link(space_opts)
    {:ok, ledger} = Ledger.start_link(tmp("ldhold-orch"))
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

  setup do
    for pid <- Task.Supervisor.children(LdHost.ObligationTaskSup), do: Process.exit(pid, :kill)
    :ok
  end

  test "hold keeps the lease live while probes pass, then acks" do
    %{space: space, ledger: ledger, dispatcher: dispatcher} = orchestrator()
    {_port, os_pid} = spawn_held_os_pid()
    ws = tmp("ldhold")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-1",
        "goal" => "keep pid alive",
        "workspace" => ws,
        "hold_ms" => 1000,
        "probe" => %{"kind" => "check", "command" => "kill -0 #{os_pid}", "timeout_seconds" => 5}
      })

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :spawned}, 2_000
    assert Space.leased_count(space) == 1
    Process.sleep(200)
    assert Space.leased_count(space) == 1

    assert_receive {:ld_progress, {:obligation, "hold-1"}, {:completed, summary}}, 3_000
    assert summary.success
    assert summary.hold_ms == 1000
    assert summary.probes >= 1
    assert summary.model_calls == 0

    Dispatcher.await_idle(dispatcher)
    assert Space.leased_count(space) == 0
    assert Space.bag_size(space) == 0

    trace = File.read!(Path.join(:sys.get_state(ledger).run_dir, "trace.jsonl"))
    assert trace =~ "obligation.completed"
    assert trace =~ "hold_ms"
    assert trace =~ "last_probe"
  end

  test "killing the pid before hold_ms fails with no planner_fn call" do
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
    ws = tmp("ldhold-fail")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "hold-1",
        "goal" => "keep pid alive",
        "workspace" => ws,
        "hold_ms" => 2000,
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
    assert_receive {:space, "space.lease_expired", %{generation: 1}}, 1_000
    refute_received {:space, "space.ack", _}
    refute Space.ack(space, stale)

    # Stop before the dispatcher tight-loops retakes of a dead probe.
    GenServer.stop(dispatcher)
    refute_received :planner_called

    trace = File.read!(Path.join(:sys.get_state(ledger).run_dir, "trace.jsonl"))
    assert trace =~ "obligation.failed"
    assert trace =~ "hold_ms"
    assert trace =~ "last_probe"
  end

  test "killing the agent mid-hold expires the lease; sibling retake; stale token cannot ack" do
    me = self()

    %{space: space, dispatcher: dispatcher} =
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
        "hold_ms" => 2000,
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

    assert_receive {:ld_progress, {:obligation, "hold-1"}, {:completed, summary}}, 5_000
    assert summary.success
    Dispatcher.await_idle(dispatcher)
    assert Space.bag_size(space) == 0
    refute Space.ack(space, stale)
  end
end
