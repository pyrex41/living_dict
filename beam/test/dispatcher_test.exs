defmodule LdHost.DispatcherTest do
  use ExUnit.Case

  alias LdHost.{Dispatcher, Ledger, Progress, Space}

  defp tmp(prefix) do
    dir =
      System.tmp_dir!()
      |> Path.join(
        "#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp orchestrator do
    {:ok, ledger} = Ledger.start_link(tmp("ldorch"))
    record = fn kind, payload -> Ledger.trace(ledger, kind, payload) end
    {:ok, space} = Space.start_link(record: record)
    {:ok, dispatcher} = Dispatcher.start_link(space: space, ledger: ledger)
    %{space: space, ledger: ledger, dispatcher: dispatcher}
  end

  defp canned_planner do
    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
          ~s{S" out.txt" S" out.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"out.txt" => "obligation output\n"},
      "rationale" => "one increment"
    }

    fn _goal, _obs, _feedback -> {:ok, envelope, %{input_tokens: 1, output_tokens: 1}} end
  end

  defp trace_events(ledger) do
    ledger
    |> then(&:sys.get_state(&1).run_dir)
    |> Path.join("trace.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  test "obligation lifecycle: out -> take -> jido agent runs the loop -> ack + ledger" do
    %{space: space, ledger: ledger, dispatcher: dispatcher} = orchestrator()

    :sys.replace_state(dispatcher, fn state ->
      %{state | run_opts: [planner_fn: canned_planner(), max_episodes: 1]}
    end)

    ws = tmp("ldob")
    Progress.subscribe(:all)

    {:ok, _} =
      Space.out(space, %{
        "kind" => "obligation",
        "id" => "ob-1",
        "goal" => "write an output file",
        "workspace" => ws,
        "contract" => %{
          "claims" => [
            %{"id" => "out", "kind" => "check", "command" => "grep -q obligation out.txt"}
          ]
        }
      })

    assert_receive {:ld_progress, {:obligation, "ob-1"}, :spawned}, 2_000
    assert_receive {:ld_progress, {:obligation, "ob-1"}, {:completed, summary}}, 15_000
    assert summary.success
    assert File.read!(Path.join(ws, "out.txt")) =~ "obligation"

    Dispatcher.await_idle(dispatcher)
    assert Space.leased_count(space) == 0
    assert Space.bag_size(space) == 0

    events = trace_events(ledger)
    types = Enum.map(events, & &1["type"])
    assert "obligation.spawned" in types
    assert "obligation.completed" in types
    assert "space.ack" in types
    refute "space.lease_expired" in types
    spawned_at = Enum.find_index(types, &(&1 == "obligation.spawned"))
    completed_at = Enum.find_index(types, &(&1 == "obligation.completed"))
    assert spawned_at < completed_at
  end

  test "deny-by-default: goalless and workspaceless obligations are refused, not looped" do
    %{space: space, ledger: ledger} = orchestrator()

    {:ok, _} =
      Space.out(space, %{"kind" => "obligation", "id" => "ob-bad", "workspace" => "/nope/nothing"})

    ledger_dir = :sys.get_state(ledger).run_dir

    wait_until(fn ->
      File.exists?(Path.join(ledger_dir, "trace.jsonl")) and
        File.read!(Path.join(ledger_dir, "trace.jsonl")) =~ "obligation.denied"
    end)

    assert Space.bag_size(space) == 0
    assert Space.leased_count(space) == 0
    events = File.read!(Path.join(ledger_dir, "trace.jsonl"))
    assert events =~ "space.ack"
    refute events =~ "space.lease_expired"
  end

  test "two obligations run concurrently in disjoint workspaces" do
    %{space: space, dispatcher: dispatcher} = orchestrator()

    :sys.replace_state(dispatcher, fn state ->
      %{state | run_opts: [planner_fn: canned_planner(), max_episodes: 1]}
    end)

    ws1 = tmp("ldc1")
    ws2 = tmp("ldc2")
    Progress.subscribe(:all)

    contract = %{
      "claims" => [%{"id" => "out", "kind" => "check", "command" => "test -s out.txt"}]
    }

    for {id, ws} <- [{"ob-a", ws1}, {"ob-b", ws2}] do
      {:ok, _} =
        Space.out(space, %{
          "kind" => "obligation",
          "id" => id,
          "goal" => "g",
          "workspace" => ws,
          "contract" => contract
        })
    end

    assert_receive {:ld_progress, {:obligation, _}, {:completed, _}}, 15_000
    assert_receive {:ld_progress, {:obligation, _}, {:completed, _}}, 15_000

    assert File.exists?(Path.join(ws1, "out.txt"))
    assert File.exists?(Path.join(ws2, "out.txt"))
  end

  defp wait_until(fun, deadline_ms \\ 5_000) do
    if fun.() do
      :ok
    else
      if deadline_ms <= 0, do: flunk("condition never became true")
      Process.sleep(50)
      wait_until(fun, deadline_ms - 50)
    end
  end
end
