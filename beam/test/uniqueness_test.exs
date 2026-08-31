defmodule LdHost.UniquenessTest do
  use ExUnit.Case

  alias LdHost.{Forth, Run, Uniqueness, Wave}

  test "Forth.host_words/0 is eval six plus USE-ARTIFACT plus live-only USE-OBJECT/PATCH-FILE" do
    eval = Forth.eval_host_words()
    live = Forth.live_host_words()
    assert eval == ~w(READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES RECEIPT USE-ARTIFACT)
    assert live == ~w(USE-OBJECT PATCH-FILE)
    assert Forth.host_words() == eval ++ live
  end

  test "two-task canned warm sequence calling INSTALL reports family_transfer > 0" do
    results = %{
      tasks: [
        %{id: "t1", used_words: [], promoted: ["INSTALL"], success: true, judge: "approved contract"},
        %{id: "t2", used_words: ["INSTALL"], promoted: [], success: true, judge: "approved contract"}
      ]
    }

    score = Uniqueness.score(results)
    assert score.family_transfer > 0
    assert score.contract_first == 1.0
  end

  test "seed-present unused prelude reports family_transfer 0" do
    results = %{
      prelude: ["INSTALL", "CAT"],
      tasks: [
        %{id: "t1", used_words: [], promoted: [], success: true, judge: "approved contract"}
      ]
    }

    assert Uniqueness.score(results).family_transfer == 0
  end

  test "replay planner_fn succeeds with model_calls == 0" do
    ws =
      System.tmp_dir!()
      |> Path.join("lduniq-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(ws)

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello from replay\n"},
      "rationale" => "replay"
    }

    contract = %{
      claims: [
        %{"id" => "greeting", "kind" => "check", "command" => "grep -q hello greet.txt", "timeout_seconds" => 5}
      ],
      source: "hidden"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{model_calls: 0, input_tokens: 0, output_tokens: 0}} end

    result = Run.run("replay", workspace: ws, contract: contract, planner_fn: planner, max_episodes: 1)
    assert result.success
    assert result.model_calls == 0

    score = Uniqueness.score(%{replay: %{success: result.success, model_calls: result.model_calls}})
    assert score.replay_without_model
  end

  test "two-node canned envelope via node_view + Space reports wave speedup" do
    nodes = [
      %{id: "a", writes: ["a.txt"], depends_on: [], program: ""},
      %{id: "b", writes: ["b.txt"], depends_on: [], program: ""}
    ]

    {:ok, waves} = Wave.plan_waves(nodes)
    assert length(hd(waves)) == 2

    timings = %{
      "a" => {"2026-01-01T00:00:00.000Z", "2026-01-01T00:00:00.080Z"},
      "b" => {"2026-01-01T00:00:00.010Z", "2026-01-01T00:00:00.090Z"}
    }

    metrics = Wave.compute_metrics(waves, timings, 90)
    assert metrics.nodes_parallel >= 2
    assert metrics.wall_ms_actual < metrics.wall_ms_serial_estimate

    score = Uniqueness.score(%{wave: metrics})
    assert score.wave_speedup
  end

  test "crash/reclaim/stale-token obligation_hold is derived, never invented zeros" do
    assert Uniqueness.score(%{}) == %{}

    score =
      Uniqueness.score(%{
        hold: %{double_ack: false, expired: true, generation: 2, acked: true}
      })

    assert score.obligation_hold
  end
end
