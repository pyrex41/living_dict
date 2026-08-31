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

    promo = Enum.find(events, &(&1["kind"] == "dictionary.promoted"))
    assert promo["payload"]["word"] == "INSTALL"
    assert promo["payload"]["contract"] == "( key path -- | read, write )"
    assert promo["payload"]["effects"] == ["read", "write"]
    # INSTALL's WRITE-FILE path is a stack argument, not a literal.
    assert promo["payload"]["path_region"] == ["**"]
    assert promo["payload"]["task_families"] == []
    assert promo["payload"]["primitive_contract"] == LdHost.Forth.primitive_contract()
    assert is_binary(promo["payload"]["parent_dict"])
    assert String.length(promo["payload"]["parent_dict"]) == 64
    refute String.starts_with?(promo["payload"]["parent_dict"], "sha256:")

    objects = Path.join(result.run_dir, "objects")
    assert File.dir?(objects)
    # parent_dict is D_n before this promote; interned D* lives under objects/
    blobs = Path.wildcard(Path.join(objects, "*/*"))
    assert blobs != []

    identity = LdHost.Dictionary.load_identity(Path.join(result.run_dir, "dictionary"), "INSTALL")
    assert identity["effects"] == ["read", "write"]
    assert identity["path_region"] == ["**"]
    assert identity["task_families"] == []
  end

  test "promoted word with literal WRITE-FILE persists that path as path_region" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{: GREET ( -- | write ) S" hello from the beam\n" S" greet.txt" WRITE-FILE DROP ; } <>
          ~s{GREET RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "literal write"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("greet", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)

    assert result.success
    assert result.promoted_words == ["GREET"]

    events =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    promo = Enum.find(events, &(&1["kind"] == "dictionary.promoted"))
    assert promo["payload"]["effects"] == ["write"]
    assert promo["payload"]["path_region"] == ["greet.txt"]
    assert promo["payload"]["task_families"] == []
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

  test "LD_CARTRIDGE=0 ignores stub cartridge execute; program still runs" do
    ws = workspace()
    prev = System.get_env("LD_CARTRIDGE")
    System.put_env("LD_CARTRIDGE", "0")

    envelope = %{
      "language" => "forth",
      "program" => @good_envelope["program"],
      "artifacts" => @good_envelope["artifacts"],
      "rationale" => "cartridge ignored",
      "cartridge" => %{
        "parent" => nil,
        "memory_view" => "workspace-head",
        "action_topology" => "sequential",
        "capabilities" => ["read", "write", "exec"],
        "budget" => %{"writes" => 8, "execs" => 2},
        "definitions" => %{"INSTALL" => ": INSTALL ( -- ) ;"},
        "entrypoint" => "UNKNOWN-WORD-MUST-NOT-RUN"
      }
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      try do
        Run.run("greet", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 1)
      after
        if prev, do: System.put_env("LD_CARTRIDGE", prev), else: System.delete_env("LD_CARTRIDGE")
      end

    assert result.success
    refute Run.cartridge_enabled?()
    kinds =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.map(& &1["kind"])

    refute "dictionary.overlay.proposed" in kinds
    refute "dictionary.overlay.admitted" in kinds
    refute "dictionary.overlay.rejected" in kinds
    assert "critic.accepted" in kinds
    assert File.read!(Path.join(ws, "greet.txt")) =~ "hello"
  end

  test "retrieved mode subsets observe/prelude; load-all keeps mixed-family words" do
    shared =
      System.tmp_dir!()
      |> Path.join("ldretrun-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    LdHost.Dictionary.save_words(shared, [
      {"CONFIG", ~s{S" x" S" app/config.py" WRITE-FILE DROP}, "( -- | write )"},
      {"PARSER", ~s{S" x" S" src/records.py" WRITE-FILE DROP}, "( -- | write )"}
    ])

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{S" hello from the beam\n" S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "no colon reuse"
    }

    {:ok, seen} = Agent.start_link(fn -> nil end)

    planner = fn _g, obs, _f ->
      Agent.update(seen, fn _ -> obs end)
      {:ok, envelope, %{input_tokens: 2, output_tokens: 1}}
    end

    ws = workspace()

    retrieved =
      Run.run("greet",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        dictionary_dir: shared,
        dict_mode: :retrieved,
        allowed_effects: ["read", "write", "exec"],
        allowed_globs: ["app/config.py", "greet.txt"],
        forbidden_globs: ["tests/**", "TASK.md"],
        max_episodes: 1
      )

    assert retrieved.success
    assert retrieved.dict_mode == :retrieved
    assert retrieved.prelude_words == ["CONFIG"]
    refute retrieved.retrieve_query == "*"
    refute Map.has_key?(retrieved.retrieve_query, "family")
    obs = Agent.get(seen, & &1)
    assert obs =~ "CONFIG"
    refute obs =~ "PARSER"

    trace = File.read!(Path.join(retrieved.run_dir, "trace.jsonl"))
    assert trace =~ "dictionary.retrieve"
    assert trace =~ "app/config.py"

    ws2 = workspace()

    load_all =
      Run.run("greet",
        workspace: ws2,
        contract: contract(),
        planner_fn: planner,
        dictionary_dir: shared,
        dict_mode: :load_all,
        allowed_globs: ["app/config.py", "greet.txt"],
        forbidden_globs: ["tests/**"],
        max_episodes: 1
      )

    assert load_all.dict_mode == :load_all
    assert load_all.retrieve_query == "*"
    assert "CONFIG" in load_all.prelude_words
    assert "PARSER" in load_all.prelude_words
    assert load_all.prelude_bytes > retrieved.prelude_bytes
  end

  test "Exp 0 hidden-verifier contract is the Run gates judge on an oracle workspace" do
    task =
      LdHost.Bench.Exp0.load_task(
        Path.join([LdHost.Critic.repo_root(), "eval", "tasks", "config-08"])
      )

    ws = workspace()
    File.rm_rf!(ws)
    File.cp_r!(Path.join(task.dir, "repo"), ws)
    File.cp_r!(Path.join([task.dir, "protected", "oracle", "files"]), ws)

    envelope = %{
      "language" => "forth",
      "program" => ~s{RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{},
      "rationale" => "measure hidden verifier only"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{input_tokens: 1, output_tokens: 1}} end

    result =
      Run.run(task.goal,
        workspace: ws,
        contract: task.contract,
        planner_fn: planner,
        dict_mode: :retrieved,
        allowed_effects: task.allowed_effects,
        allowed_globs: task.allowed_globs ++ ["claims.json", ".sb/*"],
        forbidden_globs: task.forbidden_globs,
        max_episodes: 1
      )

    assert result.success
    assert result.judge == "approved contract"
    assert result.report.ok == true
  end

  test "identical artifacts with a tweaked program are blocked" do
    ws = workspace()
    {:ok, log} = Agent.start_link(fn -> [] end)

    planner = fn _g, _o, feedback ->
      Agent.update(log, &[feedback | &1])
      n = Agent.get(log, &length/1)

      env = %{
        "language" => "forth",
        "program" =>
          ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP} <>
            String.duplicate(" DROP", rem(n, 2)),
        "artifacts" => %{"greet.txt" => "not hello\n"},
        "rationale" => "attempt #{n}"
      }

      {:ok, env, %{}}
    end

    result = Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 3)
    refute result.success
    feedbacks = Agent.get(log, &Enum.reverse/1)
    assert Enum.any?(feedbacks, &(&1 =~ "identical artifacts resubmitted"))
  end

  test "gate failure observation is diffs and failed checks, not a full tree dump" do
    ws = workspace()
    File.write!(Path.join(ws, "greet.txt"), "start\n")
    {:ok, obs_log} = Agent.start_link(fn -> [] end)
    {:ok, n} = Agent.start_link(fn -> 0 end)

    planner = fn _g, obs, _f ->
      Agent.update(n, &(&1 + 1))
      i = Agent.get(n, & &1)
      if i > 1, do: Agent.update(obs_log, &[obs | &1])

      body = if i == 1, do: "wrong\n", else: "hello from the beam\n"

      env = %{
        "language" => "forth",
        "program" =>
          ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
        "artifacts" => %{"greet.txt" => body},
        "rationale" => "ep#{i}"
      }

      {:ok, env, %{}}
    end

    result = Run.run("goal", workspace: ws, contract: contract(), planner_fn: planner, max_episodes: 2)
    assert result.success

    obs = Agent.get(obs_log, &hd/1)
    assert obs =~ "FAILED CHECKS"
    assert obs =~ "PRODUCT DIFF"
    assert obs =~ "greet.txt"
    # fail-view lists names, not the full ``` dump of every file
    refute obs =~ "WORKSPACE FILES:\ngreet.txt:\n```"
  end

  test "INSTALL plumbing note appears when retrieved prelude has INSTALL-*" do
    ws = workspace()
    dict = Path.join(workspace(), "dict")
    File.mkdir_p!(Path.join(dict, "words"))

    File.write!(
      Path.join(dict, "words/INSTALL-GREET.fs"),
      ": INSTALL-GREET ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"
    )

    File.write!(
      Path.join(dict, "words/INSTALL-GREET.identity.json"),
      JSON.encode!(%{"effects" => ["read", "write"], "path_region" => ["greet.txt"], "task_families" => []})
    )

    {:ok, obs_log} = Agent.start_link(fn -> [] end)

    planner = fn _g, obs, _f ->
      Agent.update(obs_log, &[obs | &1])

      {:ok,
       %{
         "language" => "forth",
         "program" => ~s{S" greet.txt" INSTALL-GREET RUN-GATES DROP RECEIPT DROP},
         "artifacts" => %{"greet.txt" => "hello from the beam\n"},
         "rationale" => "call plumbing"
       }, %{}}
    end

    result =
      Run.run("goal",
        workspace: ws,
        contract: contract(),
        planner_fn: planner,
        dictionary_dir: dict,
        dict_mode: :retrieved,
        allowed_globs: ["greet.txt"],
        max_episodes: 1
      )

    assert result.success
    obs = Agent.get(obs_log, &hd/1)
    assert obs =~ "PLUMBING"
    assert obs =~ "INSTALL-GREET"
  end

  test "successful product write persists a policy fact sidecar" do
    ws = workspace()
    File.mkdir_p!(Path.join(ws, "app"))

    py = """
    DEFAULTS = {'compatibility_mode': False, "retries": 2}
    ALIASES = {}
    def normalize(user):
        raise KeyError(k)
    """

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE DROP RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"app/config.py" => py},
      "rationale" => "config"
    }

    contract = %{
      claims: [%{"id" => "py", "kind" => "file", "path" => "app/config.py", "min_bytes" => 10}],
      source: "hidden"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end
    result = Run.run("goal", workspace: ws, contract: contract, planner_fn: planner, max_episodes: 1)
    assert result.success

    policies = Path.wildcard(Path.join([result.run_dir, "dictionary", "policy", "*.json"]))
    assert policies != []
    fact = JSON.decode!(File.read!(hd(policies)))
    assert fact["forbids_aliases"] == true
    assert fact["must_raise_keyerror"] == true
    assert "app/config.py" in fact["path_region"]
  end
end
