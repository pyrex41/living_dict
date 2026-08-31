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
    assert Enum.at(feedbacks, 1) =~ "token 0:"
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

  @tag :observation
  test "observation lists hashes and UNUSED, not file bodies" do
    ws = workspace()

    dict =
      System.tmp_dir!()
      |> Path.join("ldobs-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dict, "words"))

    File.write!(
      Path.join([dict, "words", "INSTALL.fs"]),
      ": INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"
    )

    {:ok, log} = Agent.start_link(fn -> [] end)

    write = %{
      "language" => "forth",
      "program" =>
        ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello from the beam\n"},
      "rationale" => "write greeting"
    }

    planner1 = fn _g, obs, feedback ->
      Agent.update(log, &[{obs, feedback} | &1])
      {:ok, write, %{}}
    end

    r1 =
      Run.run("obs-write",
        workspace: ws,
        contract: contract(),
        planner_fn: planner1,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r1.success

    planner2 = fn _g, obs, feedback ->
      Agent.update(log, &[{obs, feedback} | &1])
      {:ok, write, %{}}
    end

    r2 =
      Run.run("obs-hashes",
        workspace: ws,
        contract: contract(),
        planner_fn: planner2,
        dictionary_dir: dict,
        max_episodes: 1
      )

    assert r2.success
    observations = Agent.get(log, &Enum.reverse/1) |> Enum.map(&elem(&1, 0))
    second = Enum.at(observations, 1)
    assert second =~ "UNUSED"
    assert second =~ "INSTALL"
    refute second =~ "hello from the beam"
    assert second =~ "WORKSPACE TREE"
    sha = LdHost.Policy.sha256_hex("hello from the beam\n")
    assert second =~ sha

    events = LdHost.Ledger.events(r1.run_dir)
    last = List.last(events)
    tree = LdHost.Store.as_of(events, last["sequence"])
    assert tree["greet.txt"] == LdHost.Policy.snapshot(ws)["greet.txt"]
  end

  test "canned episode 1 writes+interns; episode 2 USE-OBJECT with empty artifacts" do
    body = "hello from intern\n"
    ws1 = workspace()

    episode1 = %{
      "language" => "forth",
      "program" =>
        ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => body},
      "rationale" => "intern"
    }

    r1 =
      Run.run("intern",
        workspace: ws1,
        contract: contract(),
        planner_fn: fn _g, _o, _f -> {:ok, episode1, %{}} end,
        max_episodes: 1
      )

    assert r1.success
    sha = LdHost.Policy.sha256_hex(body)
    obj = Path.join([r1.run_dir, "objects", String.slice(sha, 0, 2), sha])
    assert File.exists?(obj)

    ws2 = workspace()
    run2 = Path.join(System.tmp_dir!(), "ldobj2-#{System.os_time(:nanosecond)}")
    File.mkdir_p!(run2)
    File.cp_r!(Path.join(r1.run_dir, "objects"), Path.join(run2, "objects"))

    episode2 = %{
      "language" => "forth",
      "program" =>
        ~s{S" #{sha}" USE-OBJECT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "by hash"
    }

    r2 =
      Run.run("by-hash",
        workspace: ws2,
        contract: contract(),
        planner_fn: fn _g, _o, _f -> {:ok, episode2, %{}} end,
        max_episodes: 1,
        run_dir: run2
      )

    assert r2.success
    assert File.read!(Path.join(ws2, "greet.txt")) == body
    env = run2 |> Path.join("envelope.json") |> File.read!() |> JSON.decode!()
    assert env["artifacts"] == %{}
  end

  test "pre-existing workspace file is interned and USE-OBJECT succeeds" do
    body = "hello seeded on disk\n"
    ws = workspace()
    File.write!(Path.join(ws, "greet.txt"), body)
    sha = LdHost.Policy.sha256_hex(body)

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{S" #{sha}" USE-OBJECT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "install by hash of seed"
    }

    result =
      Run.run("seed-hash",
        workspace: ws,
        contract: contract(),
        planner_fn: fn _g, _o, _f -> {:ok, envelope, %{}} end,
        max_episodes: 1
      )

    assert result.success
    obj = Path.join([result.run_dir, "objects", String.slice(sha, 0, 2), sha])
    assert File.exists?(obj)
    assert File.read!(Path.join(ws, "greet.txt")) == body
  end

  test "observation after write-then-trap shows live tree hashes" do
    ws = workspace()
    {:ok, log} = Agent.start_link(fn -> [] end)
    body = "hello from trap-write\n"

    trap = %{
      "language" => "forth",
      "program" =>
        ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP S" missing.txt" READ-FILE},
      "artifacts" => %{"greet.txt" => body},
      "rationale" => "write then trap"
    }

    recover = %{
      "language" => "forth",
      "program" => ~s{RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "recover"
    }

    planner = fn _g, obs, feedback ->
      Agent.update(log, &[{obs, feedback} | &1])
      {:ok, if(feedback == "", do: trap, else: recover), %{}}
    end

    result =
      Run.run("trap-obs",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        max_episodes: 2
      )

    assert result.success
    observations = Agent.get(log, &Enum.reverse/1) |> Enum.map(&elem(&1, 0))
    second = Enum.at(observations, 1)
    sha = LdHost.Policy.sha256_hex(body)
    assert second =~ "WORKSPACE TREE"
    assert second =~ sha
    refute second =~ "hello from trap-write"
    assert File.read!(Path.join(ws, "greet.txt")) == body
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
        %{
          "id" => "both",
          "kind" => "check",
          "command" => "test -f a.txt && test -f b.txt",
          "timeout_seconds" => 5
        }
      ],
      source: "hidden"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      Run.run("pair", workspace: ws, contract: contract, planner_fn: planner, max_episodes: 1)

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
        event["type"] == "space.out" and
          get_in(event, ["data", "pattern_or_tuple", "kind"]) == "node.ready"
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

    result =
      Run.run("overlap",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        max_episodes: 1
      )

    refute result.success
    refute File.exists?(Path.join(ws, "greet.txt"))
    events = File.read!(Path.join(result.run_dir, "events.jsonl"))
    refute events =~ "artifacts.applied"
    assert events =~ "critic.rejected"
  end

  test "serial and waved Run programs hash equal trees" do
    envelope = %{
      "language" => "forth",
      "program" => "RECEIPT DROP",
      "artifacts" => %{"a.txt" => "A\n", "b.txt" => "B\n"},
      "nodes" => [
        %{"id" => "a", "writes" => ["a.txt"], "depends_on" => [], "program" => ""},
        %{"id" => "b", "writes" => ["b.txt"], "depends_on" => [], "program" => ""}
      ],
      "rationale" => "eq"
    }

    contract = %{
      claims: [
        %{
          "id" => "both",
          "kind" => "check",
          "command" => "test -f a.txt && test -f b.txt",
          "timeout_seconds" => 5
        }
      ],
      source: "hidden"
    }

    run = fn workers ->
      ws = workspace()
      planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

      result =
        Run.run("eq",
          workspace: ws,
          contract: contract,
          planner_fn: planner,
          max_episodes: 1,
          wave_workers: workers
        )

      assert result.success
      receipt = result.run_dir |> Path.join("receipt.json") |> File.read!() |> JSON.decode!()
      {LdHost.Policy.snapshot(ws), receipt["workspace_after"], receipt["changed_files"]}
    end

    {serial_tree, serial_after, serial_changed} = run.(1)
    {waved_tree, waved_after, waved_changed} = run.(2)
    assert serial_tree == waved_tree
    assert serial_after == waved_after
    assert serial_changed == waved_changed
  end
end
