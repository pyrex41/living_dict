defmodule LdHost.UniquenessTest do
  use ExUnit.Case

  alias LdHost.{Dispatcher, Forth, Ledger, Progress, Run, Space, Uniqueness}

  setup do
    for pid <- Task.Supervisor.children(LdHost.ObligationTaskSup), do: Process.exit(pid, :kill)
    :ok
  end

  defp tmp(prefix) do
    dir =
      System.tmp_dir!()
      |> Path.join("#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end

  defp contract do
    %{
      claims: [
        %{
          "id" => "greeting",
          "kind" => "check",
          "command" => "grep -q hello greet.txt",
          "timeout_seconds" => 5
        }
      ],
      source: "hidden"
    }
  end

  @define_install %{
    "language" => "forth",
    "program" =>
      ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
        ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello from the beam\n"},
    "rationale" => "define INSTALL"
  }

  @reuse_install %{
    "language" => "forth",
    "program" => ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello again\n"},
    "rationale" => "reuse INSTALL"
  }

  @zipper %{
    "language" => "forth",
    "program" =>
      ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello zipper\n"},
    "rationale" => "zipper instead of INSTALL"
  }

  defp seed_install(dict) do
    File.mkdir_p!(Path.join(dict, "words"))

    File.write!(
      Path.join([dict, "words", "INSTALL.fs"]),
      ": INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"
    )
  end

  test "two-task canned warm sequence calling INSTALL reports family_transfer > 0" do
    dict = tmp("lduniq-dict")
    planner1 = fn _g, _o, _f -> {:ok, @define_install, %{input_tokens: 1, output_tokens: 1}} end

    r1 =
      Run.run("first",
        workspace: tmp("lduniq-w1"),
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r1.success
    assert File.exists?(Path.join(r1.run_dir, "envelope.json"))

    planner2 = fn _g, _o, _f -> {:ok, @reuse_install, %{input_tokens: 1, output_tokens: 1}} end

    r2 =
      Run.run("second",
        workspace: tmp("lduniq-w2"),
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r2.success
    assert r2.promoted_words == ["INSTALL"]
    assert r2.judge == "approved contract"

    score =
      Uniqueness.score(%{
        "warm" => [
          Map.merge(r1, %{task: "t1", arm: "warm", dictionary_dir: dict}),
          Map.merge(r2, %{task: "t2", arm: "warm", dictionary_dir: dict})
        ]
      })

    assert score.family_transfer > 0
    assert score.contract_first == 1.0
  end

  test "seed-present unused prelude reports family_transfer 0" do
    dict = tmp("lduniq-seed")
    seed_install(dict)
    planner = fn _g, _o, _f -> {:ok, @zipper, %{input_tokens: 1, output_tokens: 1}} end

    result =
      Run.run("zipper",
        workspace: tmp("lduniq-zip"),
        contract: contract(),
        planner_fn: planner,
        dictionary_dir: dict,
        max_episodes: 1
      )

    # Covering rejects the zipper when INSTALL is seeded; either way the
    # catalog is present and unused as a Forth token in a later task.
    score =
      Uniqueness.score(%{
        :seed => ["INSTALL"],
        "warm" => [Map.merge(result, %{task: "t1", arm: "warm", dictionary_dir: dict})]
      })

    assert score.family_transfer == 0.0
  end

  test "replay planner_fn succeeds with model_calls == 0" do
    planner = fn _g, _o, _f -> {:ok, @define_install, %{input_tokens: 4, output_tokens: 2}} end

    first =
      Run.run("greet",
        workspace: tmp("lduniq-orig"),
        contract: contract(),
        planner_fn: planner,
        max_episodes: 1
      )

    assert first.success
    assert first.model_calls == 1

    envelope = Path.join(first.run_dir, "envelope.json") |> File.read!() |> JSON.decode!()
    refute envelope["artifacts"]["greet.txt"] =~ "hello from the beam"
    assert envelope["artifacts"]["greet.txt"] =~ ~r/^[0-9a-f]{64}$/
    assert envelope["program"] =~ "INSTALL"

    replay_ws = tmp("lduniq-replay")

    replayed =
      Uniqueness.replay(first.run_dir,
        workspace: replay_ws,
        contract: contract(),
        max_episodes: 1
      )

    assert replayed.success
    assert replayed.model_calls == 0
    assert replayed.judge == "approved contract"
    assert File.read!(Path.join(replay_ws, "greet.txt")) =~ "hello"

    score = Uniqueness.score(%{:replay => replayed, "warm" => [first]})
    assert score.replay_without_model
  end

  test "two-node canned envelope via node_view + Space reports wave speedup" do
    ws = tmp("lduniq-wave")

    nodes = [
      %{id: "a", writes: ["a.txt"], depends_on: [], program: ""},
      %{id: "b", writes: ["b.txt"], depends_on: [], program: ""}
    ]

    artifacts = %{"a.txt" => "A\n", "b.txt" => "B\n"}
    assert {:ok, metrics} = Uniqueness.measure_waves(ws, nodes, artifacts)
    assert metrics.nodes_parallel >= 2
    assert metrics.max_wave_width >= 2
    assert metrics.wall_ms_actual < metrics.wall_ms_serial_estimate
    assert File.read!(Path.join(ws, "a.txt")) == "A\n"
    assert File.read!(Path.join(ws, "b.txt")) == "B\n"

    score = Uniqueness.score(%{wave: metrics})
    assert score.wave_speedup.ok
    assert score.wave_speedup.nodes_parallel >= 2
  end

  test "obligation hold: crash expires, sibling reclaims generation+1, stale token cannot ack" do
    me = self()
    {:ok, space} = Space.start_link(record: fn kind, payload -> send(me, {:space, kind, payload}) end)
    {:ok, ledger} = Ledger.start_link(tmp("lduniq-orch"))
    {:ok, dispatcher} = Dispatcher.start_link(space: space, ledger: ledger)

    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :hide, args: ["30"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    ws = tmp("lduniq-hold")
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

    Process.exit(task_pid, :kill)
    assert_receive {:ld_progress, {:obligation, "hold-1"}, :crashed}, 2_000
    assert_receive {:space, "space.lease_expired", %{generation: 1}}, 2_000
    refute Space.ack(space, stale)

    assert_receive {:ld_progress, {:obligation, "hold-1"}, :spawned}, 2_000
    assert_receive {:space, "space.take", %{generation: 2}}, 2_000

    assert_receive {:ld_progress, {:obligation, "hold-1"}, {:completed, summary}}, 5_000
    assert summary.success
    assert summary.hold_ms == 2000
    Dispatcher.await_idle(dispatcher)
    refute Space.ack(space, stale)

    evidence = %{
      hold_ms: summary.hold_ms,
      double_ack: false,
      expired_on_crash: true,
      reclaim_generation: 2,
      stale_ack: false
    }

    score = Uniqueness.score(%{obligation: evidence})
    assert score.obligation_hold.ok
    assert score.obligation_hold.hold_ms == 2000
    refute score.obligation_hold.double_ack
    refute score.obligation_hold.stale_ack
  end

  test "host_words/0 is eval six plus USE-ARTIFACT, plus live-only USE-OBJECT and PATCH-FILE" do
    eval_abi = ~w(READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES RECEIPT)
    # USE-ARTIFACT is envelope lookup, still eval-facing; the two live-only
    # words landed in PR5 and must not be mistaken for eval 1.0 ABI growth.
    live_only = ~w(USE-OBJECT PATCH-FILE)
    words = Forth.host_words()
    assert eval_abi -- words == []
    assert "USE-ARTIFACT" in words
    assert live_only -- words == []
    assert (words -- (eval_abi ++ ["USE-ARTIFACT"] ++ live_only)) == []
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
end
