defmodule LdHost.RunTest do
  use ExUnit.Case

  alias LdHost.Run

  defp workspace do
    tmp = System.tmp_dir!() |> Path.join("ldrun-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmp
  end

  defp contract do
    %{
      claims: [
        %{"id" => "greeting", "kind" => "check", "command" => "grep -q hello greet.txt", "timeout_seconds" => 5}
      ],
      source: "hidden"
    }
  end

  @good_envelope %{
    "language" => "forth",
    "program" =>
      ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
        ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello from the beam\n"},
    "rationale" => "install greeting"
  }

  test "end-to-end success: critic accept, execute, gates green, word promoted" do
    ws = workspace()

    planner = fn _goal, _obs, _feedback -> {:ok, @good_envelope, %{input_tokens: 10, output_tokens: 5}} end

    result = Run.run("write a greeting file", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 2)

    assert result.success
    assert result.judge == "approved contract"
    assert result.model_calls == 1
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello"

    # typed promotion happened: word persisted with its contract in-band
    words_dir = Path.join([result.run_dir, "dictionary", "words"])
    assert File.exists?(Path.join(words_dir, "INSTALL.fs"))
    assert File.read!(Path.join(words_dir, "INSTALL.fs")) =~ "( key path -- | read, write )"

    # ledger: kernel events landed in order with the promoted word
    events =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    kinds = Enum.map(events, & &1["kind"])
    assert "contract.approved" in kinds
    assert "critic.accepted" in kinds
    assert "gates.measured" in kinds
    assert "dictionary.promoted" in kinds
    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..length(events))
  end

  test "advisory round trip: failed model check feeds back, next episode self-judges green" do
    ws = workspace()

    claims_json =
      JSON.encode!(%{claims: [%{id: "smoke", kind: "check", command: "grep -q hello greet.txt", timeout_seconds: 5}]})

    episode1 = %{
      "language" => "forth",
      "program" => ~s{S" claims.json" USE-ARTIFACT S" claims.json" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"claims.json" => claims_json},
      "rationale" => "write claims first"
    }

    episode2 = %{
      "language" => "forth",
      "program" =>
        ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
          ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello from advisory mode\n"},
      "rationale" => "satisfy the claim"
    }

    {:ok, feedback_log} = Agent.start_link(fn -> [] end)

    planner = fn _goal, _obs, feedback ->
      Agent.update(feedback_log, &[feedback | &1])
      envelope = if feedback == "", do: episode1, else: episode2
      {:ok, envelope, %{input_tokens: 1, output_tokens: 1}}
    end

    result = Run.run("greet", workspace: ws, planner_fn: planner, allow_model_checks: true, max_episodes: 4)

    # Episode 1 failed its own check; the id came back as backpressure.
    feedbacks = Agent.get(feedback_log, &Enum.reverse/1)
    assert Enum.at(feedbacks, 1) =~ "smoke"

    # Episode 2 self-judged success and the loop terminated there.
    assert result.success
    assert result.episodes == 2
    assert result.judge == "model-authored claims"
    assert [%{advisory: true, passed: true}] = result.report.claims
    assert result.promoted_words == ["INSTALL"]
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello"
  end

  test "critic rejection feeds back and duplicate resubmission is blocked" do
    ws = workspace()
    bad = %{"language" => "forth", "program" => "MYSTERY RECEIPT", "artifacts" => %{}, "rationale" => "bad"}

    {:ok, feedback_log} = Agent.start_link(fn -> [] end)

    planner = fn _goal, _obs, feedback ->
      Agent.update(feedback_log, &[feedback | &1])
      {:ok, bad, %{input_tokens: 1, output_tokens: 1}}
    end

    result = Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 3)

    refute result.success

    feedbacks = Agent.get(feedback_log, &Enum.reverse/1)
    assert Enum.at(feedbacks, 1) =~ "unknown word MYSTERY"
    assert Enum.at(feedbacks, 2) =~ "identical plan resubmitted"

    events =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    kinds = Enum.map(events, & &1["kind"])
    assert "critic.rejected" in kinds
    assert "episode.blocked_duplicate" in kinds
  end

  test "contractless word is quarantined, not persisted" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{: BARE DUP ; S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello\n"},
      "rationale" => "no contract"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

    assert result.success
    refute File.exists?(Path.join([result.run_dir, "dictionary", "words", "BARE.fs"]))

    trace = File.read!(Path.join(result.run_dir, "trace.jsonl"))
    assert trace =~ "dictionary.quarantined"
    assert trace =~ "missing contract"
  end

  test "warm dictionary: promoted word is callable next run without redefinition" do
    ws1 = workspace()
    shared_dict = System.tmp_dir!() |> Path.join("lddictshare-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end

    r1 = Run.run("first", workspace: ws1, contract: contract(), planner_fn: planner1, dictionary_dir: shared_dict, max_episodes: 1)
    assert r1.success

    # Second run: the plan CALLS the promoted word without defining it.
    ws2 = workspace()

    reuse = %{
      "language" => "forth",
      "program" => ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello again\n"},
      "rationale" => "reuse INSTALL"
    }

    planner2 = fn _g, obs, _f ->
      assert obs =~ "INSTALL"
      {:ok, reuse, %{}}
    end

    r2 = Run.run("second", workspace: ws2, contract: contract(), planner_fn: planner2, dictionary_dir: shared_dict, max_episodes: 1)

    assert r2.success
    assert File.read!(Path.join(ws2, "greet.txt")) =~ "hello again"
  end

  test "starved call of a promoted word rejects pre-I/O (the closed type hole)" do
    ws = workspace()
    shared_dict = System.tmp_dir!() |> Path.join("lddicthole-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end
    r1 = Run.run("seed", workspace: ws, contract: contract(), planner_fn: planner1, dictionary_dir: shared_dict, max_episodes: 1)
    assert r1.success

    ws2 = workspace()

    starved = %{
      "language" => "forth",
      "program" => ~s{INSTALL RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "starved call"
    }

    planner2 = fn _g, _o, _f -> {:ok, starved, %{}} end
    r2 = Run.run("starve", workspace: ws2, contract: contract(), planner_fn: planner2, dictionary_dir: shared_dict, max_episodes: 1)

    refute r2.success
    events = File.read!(Path.join(r2.run_dir, "events.jsonl"))
    assert events =~ "critic.rejected"
    assert events =~ "stack underflow at INSTALL"
    # No I/O happened: workspace untouched
    assert LdHost.Policy.snapshot(ws2) == %{}
  end

  test "seeded INSTALL is bound, not composed into the running program" do
    ws = workspace()
    dict = System.tmp_dir!() |> Path.join("lddictseed-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dict, "words"))

    File.write!(
      Path.join([dict, "words", "INSTALL.fs"]),
      ": INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"
    )

    program = ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP}

    envelope = %{
      "language" => "forth",
      "program" => program,
      "artifacts" => %{"greet.txt" => "hello from bound vocab\n"},
      "rationale" => "call seeded INSTALL"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("greet", workspace: ws, contract: contract(), planner_fn: planner, dictionary_dir: dict, max_episodes: 1)

    assert result.success
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello from bound vocab"

    ran =
      result.run_dir
      |> Path.join("trace.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(&(&1["type"] == "execution.program"))
      |> get_in(["data", "program"])

    assert ran == program
    refute ran =~ "USE-ARTIFACT"
    refute ran =~ "DUP"
  end

  test "starved seeded INSTALL still rejects pre-I/O via composed critic" do
    ws = workspace()
    dict = System.tmp_dir!() |> Path.join("lddictstarve-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dict, "words"))

    File.write!(
      Path.join([dict, "words", "INSTALL.fs"]),
      ": INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"
    )

    starved = %{
      "language" => "forth",
      "program" => ~s{INSTALL RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "starved seeded call"
    }

    planner = fn _g, _o, _f -> {:ok, starved, %{}} end
    result = Run.run("starve", workspace: ws, contract: contract(), planner_fn: planner, dictionary_dir: dict, max_episodes: 1)

    refute result.success
    events = File.read!(Path.join(result.run_dir, "events.jsonl"))
    assert events =~ "critic.rejected"
    assert events =~ "stack underflow at INSTALL"
    assert LdHost.Policy.snapshot(ws) == %{}
  end

  test "episode 1 interns; episode 2 installs by hash with empty artifacts" do
    ws = workspace()
    body = "hello from the beam\n"
    sha = LdHost.Policy.sha256_hex(body)

    episode1 = %{
      "language" => "forth",
      "program" => ~s{S" stash.txt" USE-ARTIFACT S" stash.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"stash.txt" => body},
      "rationale" => "intern the greeting body"
    }

    episode2 = %{
      "language" => "forth",
      "program" => ~s{S" #{sha}" USE-OBJECT S" greet.txt" WRITE-FILE RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "install by hash"
    }

    assert map_size(episode2["artifacts"]) == 0
    assert Enum.reduce(episode2["artifacts"], 0, fn {_k, v}, n -> n + byte_size(v) end) == 0

    {:ok, n} = Agent.start_link(fn -> 0 end)

    planner = fn _g, obs, _f ->
      i = Agent.get_and_update(n, fn i -> {i, i + 1} end)

      if i == 0 do
        {:ok, episode1, %{}}
      else
        assert obs =~ sha
        refute obs =~ "```"
        {:ok, episode2, %{}}
      end
    end

    result = Run.run("greet", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 3)

    assert result.success
    assert result.episodes == 2
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello"
    assert File.exists?(Path.join([result.run_dir, "objects", String.slice(sha, 0, 2), sha]))
  end

  test "two disjoint artifact keys dispatch one wave of node.ready" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{S" a.txt" USE-ARTIFACT S" a.txt" WRITE-FILE DROP } <>
          ~s{S" b.txt" USE-ARTIFACT S" b.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"a.txt" => "A\n", "b.txt" => "B\n"},
      "rationale" => "two files"
    }

    contract = %{
      claims: [
        %{"id" => "both", "kind" => "check", "command" => "test -f a.txt && test -f b.txt", "timeout_seconds" => 5}
      ],
      source: "hidden"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("pair", workspace: ws, contract: contract, planner_fn: planner, max_episodes: 1)

    assert result.success
    assert File.read!(Path.join(ws, "a.txt")) == "A\n"
    assert File.read!(Path.join(ws, "b.txt")) == "B\n"

    trace =
      result.run_dir
      |> Path.join("trace.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    outs =
      Enum.filter(trace, fn event ->
        event["type"] == "space.out" and get_in(event, ["data", "pattern_or_tuple", "kind"]) == "node.ready"
      end)

    takes = Enum.filter(trace, fn event -> event["type"] == "space.take" end)

    assert length(outs) == 2
    assert length(takes) == 2
    assert Enum.map(outs, &get_in(&1, ["data", "pattern_or_tuple", "wave"])) |> Enum.uniq() == [0]
    assert Enum.any?(trace, &(&1["type"] == "graph.wave.gates"))
  end

  test "overlapping writes in a wave are refused before I/O" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" => "RECEIPT DROP",
      "artifacts" => %{"greet.txt" => "hello\n"},
      "nodes" => [
        %{"id" => "left", "writes" => ["greet.txt"], "depends_on" => [], "program" => ""},
        %{"id" => "right", "writes" => ["greet.txt"], "depends_on" => [], "program" => ""}
      ],
      "rationale" => "overlap"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("overlap", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

    refute result.success
    refute File.exists?(Path.join(ws, "greet.txt"))
    events = File.read!(Path.join(result.run_dir, "events.jsonl"))
    refute events =~ "artifacts.applied"
    assert events =~ "critic.rejected"
  end

  test "overlay keeps in-band contracts and node programs are critic-checked" do
    src = ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;}
    overlaid = LdHost.Critic.overlay_live_words(src)
    assert overlaid =~ "( key path -- | read, write )"
    assert overlaid =~ "USE-ARTIFACT"

    patched = LdHost.Critic.overlay_live_words(~s{S" p" S" greet.txt" PATCH-FILE})
    assert patched =~ ~s{S" greet.txt" WRITE-FILE}
    refute patched =~ "PATCH-FILE"

    leaked = LdHost.Critic.overlay_live_words(~s{: FOO S" secret.txt" DROP ; PATCH-FILE})
    refute leaked =~ ~s{S" secret.txt" WRITE-FILE}

    ws = workspace()

    bad_contract = %{
      "language" => "forth",
      "program" =>
        ~s{: INSTALL ( key -- | write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
          ~s{S" greet.txt" S" greet.txt" INSTALL RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello\n"},
      "rationale" => "mismatched contract"
    }

    planner = fn _g, _o, _f -> {:ok, bad_contract, %{}} end
    result = Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)
    refute result.success
    events = File.read!(Path.join(result.run_dir, "events.jsonl"))
    assert events =~ "critic.rejected"

    ws2 = workspace()

    mystery = %{
      "language" => "forth",
      "program" => "RECEIPT DROP",
      "artifacts" => %{"a.txt" => "A\n"},
      "nodes" => [
        %{"id" => "a", "writes" => ["a.txt"], "depends_on" => [], "program" => "MYSTERY"}
      ],
      "rationale" => "node unknown word"
    }

    planner2 = fn _g, _o, _f -> {:ok, mystery, %{}} end
    r2 = Run.run("goal", workspace: ws2, contract: contract(), planner_fn: planner2, max_episodes: 1)
    refute r2.success
    refute File.exists?(Path.join(ws2, "a.txt"))
    events2 = File.read!(Path.join(r2.run_dir, "events.jsonl"))
    assert events2 =~ "critic.rejected"
    assert events2 =~ "MYSTERY"

    ws3 = workspace()

    dangling = %{
      "language" => "forth",
      "program" => "RECEIPT DROP",
      "artifacts" => %{"a.txt" => "A\n"},
      "nodes" => [
        %{"id" => "a", "writes" => ["a.txt"], "depends_on" => ["missing"], "program" => ""}
      ],
      "rationale" => "unknown dep"
    }

    planner3 = fn _g, _o, _f -> {:ok, dangling, %{}} end
    r3 = Run.run("goal", workspace: ws3, contract: contract(), planner_fn: planner3, max_episodes: 1)
    refute r3.success
    events3 = File.read!(Path.join(r3.run_dir, "events.jsonl"))
    assert events3 =~ "unknown depends_on"

    ws4 = workspace()

    glob_overlap = %{
      "language" => "forth",
      "program" => ~s{S" a.txt" USE-ARTIFACT S" a.txt" WRITE-FILE DROP RECEIPT DROP},
      "artifacts" => %{"a.txt" => "A\n", "*.txt" => "star\n"},
      "rationale" => "synthesized glob overlap"
    }

    planner4 = fn _g, _o, _f -> {:ok, glob_overlap, %{}} end
    r4 = Run.run("goal", workspace: ws4, contract: contract(), planner_fn: planner4, max_episodes: 1)
    refute r4.success
    refute File.exists?(Path.join(ws4, "a.txt"))
    events4 = File.read!(Path.join(r4.run_dir, "events.jsonl"))
    assert events4 =~ "critic.rejected"
    refute events4 =~ "artifacts.applied"

    ws5 = workspace()

    node_write = %{
      "language" => "forth",
      "program" => "RECEIPT DROP",
      "artifacts" => %{"a.txt" => "A\n"},
      "nodes" => [
        %{
          "id" => "a",
          "writes" => ["a.txt"],
          "depends_on" => [],
          "program" => ~s{S" leaked" S" other.txt" WRITE-FILE DROP}
        }
      ],
      "rationale" => "node write set"
    }

    planner5 = fn _g, _o, _f -> {:ok, node_write, %{}} end
    r5 = Run.run("goal", workspace: ws5, contract: contract(), planner_fn: planner5, max_episodes: 1)
    refute r5.success
    refute File.exists?(Path.join(ws5, "other.txt"))
    events5 = File.read!(Path.join(r5.run_dir, "events.jsonl"))
    assert events5 =~ "critic.rejected"

    ws6 = workspace()

    nodes_ok = %{
      "language" => "forth",
      "program" => "RECEIPT DROP",
      "artifacts" => %{"a.txt" => "A\n", "b.txt" => "B\n"},
      "nodes" => [
        %{"id" => "a", "writes" => ["a.txt"], "depends_on" => [], "program" => ""},
        %{"id" => "b", "writes" => ["b.txt"], "depends_on" => [], "program" => ""}
      ],
      "rationale" => "nodes persist gates"
    }

    pair_contract = %{
      claims: [
        %{"id" => "both", "kind" => "check", "command" => "test -f a.txt && test -f b.txt", "timeout_seconds" => 5}
      ],
      source: "hidden"
    }

    planner6 = fn _g, _o, _f -> {:ok, nodes_ok, %{}} end
    r6 = Run.run("pair", workspace: ws6, contract: pair_contract, planner_fn: planner6, max_episodes: 1)
    assert r6.success
    assert File.exists?(Path.join([ws6, ".sb", "discharge_report.json"]))
  end

  test "CAT host-word alias is not written to the dictionary" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{: CAT ( path -- | read ) READ-FILE DROP ; } <>
          ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP } <>
          ~s{S" greet.txt" CAT RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello\n"},
      "rationale" => "alias READ-FILE"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

    assert result.success
    refute File.exists?(Path.join([result.run_dir, "dictionary", "words", "CAT.fs"]))
    refute "CAT" in result.promoted_words

    events =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    evidence = Enum.filter(events, &(&1["kind"] == "dictionary.promotion_evidence"))
    assert Enum.any?(evidence, fn event ->
             event["payload"]["word"] == "CAT" and event["payload"]["eligible"] == false and
               event["payload"]["reasons"] == ["host-word alias"]
           end)
  end
end
