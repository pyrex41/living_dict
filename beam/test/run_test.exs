defmodule LdHost.RunTest do
  use ExUnit.Case

  alias LdHost.Run

  defp workspace do
    tmp =
      System.tmp_dir!()
      |> Path.join("ldrun-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    tmp
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

  @good_envelope %{
    "language" => "forth",
    "program" =>
      ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
        ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello from the beam\n"},
    "rationale" => "install greeting"
  }

  test "end-to-end success: critic accept, execute, gates green, word candidated" do
    ws = workspace()

    planner = fn _goal, _obs, _feedback ->
      {:ok, @good_envelope, %{input_tokens: 10, output_tokens: 5}}
    end

    result =
      Run.run("write a greeting file",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        max_episodes: 2
      )

    assert result.success
    assert result.judge == "approved contract"
    assert result.model_calls == 1
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello"

    # critic-accepted contracted word persists as a candidate; reuse is promotion
    words_dir = Path.join([result.run_dir, "dictionary", "words"])
    assert File.exists?(Path.join(words_dir, "INSTALL.fs"))
    assert File.read!(Path.join(words_dir, "INSTALL.fs")) =~ "( key path -- | read, write )"
    refute File.exists?(Path.join([result.run_dir, "dictionary", "promoted.txt"]))
    assert result.promoted_words == []

    # ledger: kernel events landed in order; first write is not dictionary.promoted
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
    refute "dictionary.promoted" in kinds
    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..length(events))
  end

  test "advisory round trip: failed model check feeds back, next episode self-judges green" do
    ws = workspace()

    claims_json =
      JSON.encode!(%{
        claims: [
          %{id: "smoke", kind: "check", command: "grep -q hello greet.txt", timeout_seconds: 5}
        ]
      })

    episode1 = %{
      "language" => "forth",
      "program" =>
        ~s{S" claims.json" USE-ARTIFACT S" claims.json" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
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

    result =
      Run.run("greet",
        workspace: ws,
        planner_fn: planner,
        allow_model_checks: true,
        max_episodes: 4
      )

    # Episode 1 failed its own check; the id came back as backpressure.
    feedbacks = Agent.get(feedback_log, &Enum.reverse/1)
    assert Enum.at(feedbacks, 1) =~ "smoke"

    # Episode 2 self-judged success and the loop terminated there.
    assert result.success
    assert result.episodes == 2
    assert result.judge == "model-authored claims"
    assert [%{advisory: true, passed: true}] = result.report.claims
    assert result.promoted_words == []
    assert File.exists?(Path.join([result.run_dir, "dictionary", "words", "INSTALL.fs"]))
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello"
  end

  test "critic rejection feeds back and duplicate resubmission is blocked" do
    ws = workspace()

    bad = %{
      "language" => "forth",
      "program" => "MYSTERY RECEIPT",
      "artifacts" => %{},
      "rationale" => "bad"
    }

    {:ok, feedback_log} = Agent.start_link(fn -> [] end)

    planner = fn _goal, _obs, feedback ->
      Agent.update(feedback_log, &[feedback | &1])
      {:ok, bad, %{input_tokens: 1, output_tokens: 1}}
    end

    result =
      Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 3)

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

    result =
      Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

    assert result.success
    refute File.exists?(Path.join([result.run_dir, "dictionary", "words", "BARE.fs"]))

    trace = File.read!(Path.join(result.run_dir, "trace.jsonl"))
    assert trace =~ "dictionary.quarantined"
    assert trace =~ "missing contract"
  end

  test "warm dictionary: promoted word is callable next run without redefinition" do
    ws1 = workspace()

    shared_dict =
      System.tmp_dir!()
      |> Path.join(
        "lddictshare-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end

    r1 =
      Run.run("first",
        workspace: ws1,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: shared_dict,
        max_episodes: 1
      )

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

    r2 =
      Run.run("second",
        workspace: ws2,
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: shared_dict,
        max_episodes: 1
      )

    assert r2.success
    assert File.read!(Path.join(ws2, "greet.txt")) =~ "hello again"
    assert r2.promoted_words == ["INSTALL"]

    trace_types =
      r2.run_dir
      |> Path.join("trace.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.map(& &1["type"])

    assert Enum.find_index(trace_types, &(&1 == "dictionary.reuse")) <
             Enum.find_index(trace_types, &(&1 == "dictionary.promote"))

    events =
      r2.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(
             events,
             &(&1["kind"] == "dictionary.promoted" and &1["payload"]["word"] == "INSTALL")
           )

    assert File.read!(Path.join(shared_dict, "promoted.txt")) =~ "INSTALL"
  end

  test "starved call of a candidate word rejects pre-I/O (the closed type hole)" do
    ws = workspace()

    shared_dict =
      System.tmp_dir!()
      |> Path.join(
        "lddicthole-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end

    r1 =
      Run.run("seed",
        workspace: ws,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: shared_dict,
        max_episodes: 1
      )

    assert r1.success

    ws2 = workspace()

    starved = %{
      "language" => "forth",
      "program" => ~s{INSTALL RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "starved call"
    }

    planner2 = fn _g, _o, _f -> {:ok, starved, %{}} end

    r2 =
      Run.run("starve",
        workspace: ws2,
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: shared_dict,
        max_episodes: 1
      )

    refute r2.success
    events = File.read!(Path.join(r2.run_dir, "events.jsonl"))
    assert events =~ "critic.rejected"
    assert events =~ "stack underflow at INSTALL"
    refute events =~ "dictionary.promoted"
    refute File.exists?(Path.join(shared_dict, "promoted.txt"))
    assert File.read!(Path.join(r2.run_dir, "trace.jsonl")) =~ "dictionary.reuse"
    # No I/O happened: workspace untouched
    assert LdHost.Policy.snapshot(ws2) == %{}
  end

  test "seeded INSTALL is bound, not composed into the running program" do
    ws = workspace()

    dict =
      System.tmp_dir!()
      |> Path.join(
        "lddictseed-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

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

    result =
      Run.run("greet",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        dictionary_dir: dict,
        max_episodes: 1
      )

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

    dict =
      System.tmp_dir!()
      |> Path.join(
        "lddictstarve-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

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

    result =
      Run.run("starve",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        dictionary_dir: dict,
        max_episodes: 1
      )

    refute result.success
    events = File.read!(Path.join(result.run_dir, "events.jsonl"))
    assert events =~ "critic.rejected"
    assert events =~ "stack underflow at INSTALL"
    assert LdHost.Policy.snapshot(ws) == %{}
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

    result =
      Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

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

  test "failed report.ok still candidates INSTALL" do
    ws = workspace()

    envelope = %{
      @good_envelope
      | "artifacts" => %{"greet.txt" => "not the greeting\n"}
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      Run.run("greet", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

    refute result.success
    assert File.exists?(Path.join([result.run_dir, "dictionary", "words", "INSTALL.fs"]))
    refute "INSTALL" in result.promoted_words
    refute File.exists?(Path.join([result.run_dir, "dictionary", "promoted.txt"]))

    events = File.read!(Path.join(result.run_dir, "events.jsonl"))
    refute events =~ "dictionary.promoted"
    assert events =~ "gates.measured"
  end

  test "second run that only calls INSTALL emits reuse then promoted" do
    ws1 = workspace()

    dict =
      System.tmp_dir!()
      |> Path.join(
        "lddictreuse-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end

    r1 =
      Run.run("first",
        workspace: ws1,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r1.success
    refute "INSTALL" in r1.promoted_words

    ws2 = workspace()

    reuse = %{
      "language" => "forth",
      "program" => ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello from install\n"},
      "rationale" => "call INSTALL"
    }

    planner2 = fn _g, _o, _f -> {:ok, reuse, %{}} end

    r2 =
      Run.run("second",
        workspace: ws2,
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r2.success
    assert r2.promoted_words == ["INSTALL"]
    assert File.read!(Path.join(ws2, "greet.txt")) =~ "hello from install"

    trace_types =
      r2.run_dir
      |> Path.join("trace.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.map(& &1["type"])

    reuse_at = Enum.find_index(trace_types, &(&1 == "dictionary.reuse"))
    promote_at = Enum.find_index(trace_types, &(&1 == "dictionary.promote"))
    assert reuse_at != nil
    assert promote_at != nil
    assert reuse_at < promote_at

    events =
      r2.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    kinds = Enum.map(events, & &1["kind"])
    assert "dictionary.promoted" in kinds
    refute "dictionary.reuse" in kinds
  end

  test "reuse plus trap does not promote" do
    ws1 = workspace()

    dict =
      System.tmp_dir!()
      |> Path.join(
        "lddicttrap-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end

    r1 =
      Run.run("first",
        workspace: ws1,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r1.success
    refute File.exists?(Path.join(dict, "promoted.txt"))

    ws2 = workspace()

    trap_reuse = %{
      "language" => "forth",
      "program" => ~s{S" greet.txt" S" greet.txt" INSTALL S" missing.txt" READ-FILE},
      "artifacts" => %{"greet.txt" => "hello from trap\n"},
      "rationale" => "reuse then missing read"
    }

    planner2 = fn _g, _o, _f -> {:ok, trap_reuse, %{}} end

    r2 =
      Run.run("trap-reuse",
        workspace: ws2,
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: dict,
        max_episodes: 1
      )

    refute r2.success
    assert r2.promoted_words == []
    refute File.exists?(Path.join(dict, "promoted.txt"))
    refute File.read!(Path.join(r2.run_dir, "events.jsonl")) =~ "dictionary.promoted"
    assert File.read!(Path.join(r2.run_dir, "trace.jsonl")) =~ "dictionary.reuse"
    assert File.read!(Path.join(r2.run_dir, "trace.jsonl")) =~ "execution.trap"
  end

  test "second reuse does not re-commit dictionary.promoted" do
    ws1 = workspace()

    dict =
      System.tmp_dir!()
      |> Path.join(
        "lddictidemp-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    planner1 = fn _g, _o, _f -> {:ok, @good_envelope, %{}} end

    r1 =
      Run.run("first",
        workspace: ws1,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r1.success

    reuse = %{
      "language" => "forth",
      "program" => ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello again\n"},
      "rationale" => "call INSTALL"
    }

    planner_reuse = fn _g, _o, _f -> {:ok, reuse, %{}} end

    r2 =
      Run.run("second",
        workspace: workspace(),
        contract: contract(),
        planner_fn: planner_reuse,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r2.success
    assert r2.promoted_words == ["INSTALL"]

    r3 =
      Run.run("third",
        workspace: workspace(),
        contract: contract(),
        planner_fn: planner_reuse,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r3.success
    assert r3.promoted_words == []
    refute File.read!(Path.join(r3.run_dir, "events.jsonl")) =~ "dictionary.promoted"
    assert File.read!(Path.join(r3.run_dir, "trace.jsonl")) =~ "dictionary.reuse"
    assert File.read!(Path.join(dict, "promoted.txt")) =~ "INSTALL"
  end

  @explore_envelope %{
    "language" => "forth",
    "program" =>
      ~s{: EXPLORE ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
        ~s{S" greet.txt" S" greet.txt" EXPLORE RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello from explore\n"},
    "rationale" => "define EXPLORE"
  }

  @reuse_explore_envelope %{
    "language" => "forth",
    "program" => ~s{S" greet.txt" S" greet.txt" EXPLORE RUN-GATES DROP RECEIPT DROP},
    "artifacts" => %{"greet.txt" => "hello from explore reuse\n"},
    "rationale" => "reuse EXPLORE"
  }

  test "EXPLORE-shaped body stays candidate until reuse" do
    ws1 = workspace()

    dict =
      System.tmp_dir!()
      |> Path.join(
        "lddictexplore-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    planner1 = fn _g, _o, _f -> {:ok, @explore_envelope, %{}} end

    r1 =
      Run.run("explore",
        workspace: ws1,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r1.success
    assert File.exists?(Path.join([dict, "words", "EXPLORE.fs"]))
    refute "EXPLORE" in r1.promoted_words
    refute File.exists?(Path.join(dict, "promoted.txt"))

    events1 = File.read!(Path.join(r1.run_dir, "events.jsonl"))
    refute events1 =~ "dictionary.promoted"

    ws2 = workspace()
    planner2 = fn _g, _o, _f -> {:ok, @reuse_explore_envelope, %{}} end

    r2 =
      Run.run("reuse-explore",
        workspace: ws2,
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r2.success
    assert r2.promoted_words == ["EXPLORE"]
    assert File.read!(Path.join(dict, "promoted.txt")) =~ "EXPLORE"

    kinds =
      r2.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.map(& &1["kind"])

    assert "dictionary.promoted" in kinds
  end
end
