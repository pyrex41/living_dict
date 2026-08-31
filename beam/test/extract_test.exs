defmodule LdHost.ExtractTest do
  use ExUnit.Case

  alias LdHost.{Dictionary, Extract, Retrieve, Run}

  defp tmp(prefix) do
    path =
      System.tmp_dir!()
      |> Path.join("#{prefix}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    path
  end

  defp dict_dir do
    dir = tmp("ldextract-dict")
    File.mkdir_p!(Path.join(dir, "words"))
    dir
  end

  defp workspace, do: tmp("ldextract-ws")

  defp config_contract do
    %{
      claims: [
        %{
          "id" => "config",
          "kind" => "check",
          "command" => "test -f app/config.py",
          "timeout_seconds" => 5
        }
      ],
      source: "hidden"
    }
  end

  defp idiom_program(path, extras \\ []) do
    writes =
      [path | extras]
      |> Enum.map(fn p -> ~s[S" #{p}" USE-ARTIFACT S" #{p}" WRITE-FILE DROP] end)
      |> Enum.join(" ")

    writes <> " RUN-GATES DROP RECEIPT DROP"
  end

  test "enabled? defaults on; LD_EXTRACT=0 disables" do
    prev = System.get_env("LD_EXTRACT")

    try do
      System.delete_env("LD_EXTRACT")
      assert Extract.enabled?()
      assert Extract.enabled?([])
      refute Extract.enabled?(extract: false)
      refute Extract.enabled?(extract: "0")
      System.put_env("LD_EXTRACT", "0")
      refute Extract.enabled?()
      assert Extract.enabled?(extract: true)
    after
      if prev, do: System.put_env("LD_EXTRACT", prev), else: System.delete_env("LD_EXTRACT")
    end
  end

  test "idiom with app/config.py + claims.json yields one word, product path_region only" do
    program =
      idiom_program("app/config.py", ["claims.json"]) <>
        ~s{ S" .sb/hidden" USE-ARTIFACT S" .sb/hidden" WRITE-FILE DROP}

    assert Extract.product_writes(program) == ["app/config.py"]
    assert {:ok, cand} = Extract.candidate(program)
    assert cand.name == "INSTALL-APP-CONFIG"
    assert cand.path_region == ["app/config.py"]
    assert cand.contract == "( key -- | read, write )"
    assert cand.body == "DUP USE-ARTIFACT SWAP WRITE-FILE DROP"
    refute cand.source =~ "RUN-GATES"
    refute cand.source =~ "claims.json"
  end

  test "no product writes and missing idiom do not extract" do
    assert Extract.candidate(~s{S" claims.json" USE-ARTIFACT S" claims.json" WRITE-FILE DROP}) ==
             :none

    assert Extract.candidate(~s{S" hi" S" app/config.py" WRITE-FILE DROP}) == :none
    assert Extract.candidate("RUN-GATES RECEIPT") == :none
  end

  test "same source second time writes no new file" do
    dir = dict_dir()
    program = idiom_program("app/config.py", ["claims.json"])
    assert {:ok, cand} = Extract.candidate(program)
    assert [{"INSTALL-APP-CONFIG", _sha}] = Extract.persist(dir, cand)
    assert File.exists?(Path.join([dir, "words", "INSTALL-APP-CONFIG.fs"]))
    assert Extract.identical_source?(dir, cand)
    assert Extract.persist(dir, cand) == []
  end

  test "two regions two names; retrieve config grant hits only the config word" do
    dir = dict_dir()

    {:ok, config} = Extract.candidate(idiom_program("app/config.py"))
    {:ok, parser} = Extract.candidate(idiom_program("src/records.py"))
    assert config.name != parser.name
    assert config.name == "INSTALL-APP-CONFIG"
    assert parser.name == "INSTALL-SRC-RECORDS"

    Extract.persist(dir, config)
    Extract.persist(dir, parser)

    assert Dictionary.load_identity(dir, config.name)["path_region"] == ["app/config.py"]
    assert Dictionary.load_identity(dir, parser.name)["path_region"] == ["src/records.py"]

    index = Retrieve.index(dictionary_dir: dir)
    config_q = Retrieve.host_query(["read", "write", "exec"], ["app/config.py"], ["tests/**"])
    parser_q = Retrieve.host_query(["read", "write", "exec"], ["src/records.py"], ["tests/**"])

    assert Retrieve.candidates(index, config_q) == ["INSTALL-APP-CONFIG"]
    assert Retrieve.candidates(index, parser_q) == ["INSTALL-SRC-RECORDS"]
  end

  test "critic reject / reserved name emits evidence and writes no .fs" do
    ws = workspace()
    dir = dict_dir()
    program = idiom_program("app/config.py", ["claims.json"])
    {:ok, cand} = Extract.candidate(program)
    reserved = %{cand | name: "WRITE-FILE", source: Extract.definition_source("WRITE-FILE")}

    assert {:reject, reasons} = Extract.admit(reserved, prelude: "", allowed_globs: ["**"])
    assert Enum.any?(reasons, &(&1 =~ "reserved"))
    refute File.exists?(Path.join([dir, "words", "WRITE-FILE.fs"]))

    envelope = %{
      "language" => "forth",
      "program" => program,
      "artifacts" => %{
        "app/config.py" => "x = 1\n",
        "claims.json" => "{}\n"
      },
      "rationale" => "extract reserved via admit unit; run uses safe name"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      Run.run("config",
        workspace: ws,
        contract: config_contract(),
        planner_fn: planner,
        dictionary_dir: dir,
        max_episodes: 1,
        extract: true
      )

    assert result.success
    assert File.exists?(Path.join([dir, "words", "INSTALL-APP-CONFIG.fs"]))
    refute File.exists?(Path.join([dir, "words", "WRITE-FILE.fs"]))

    # Force a reserved-name refuse through Extract.candidate name override.
    assert {:refuse, refused, refuse_reasons} =
             Extract.candidate(program, name: "RECEIPT")

    assert refused.name == "RECEIPT"
    assert refuse_reasons == ["reserved or unsafe name"]
  end

  test "planner-defined contracted word still promotes; extract does not overwrite" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{: INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
          ~s{S" app/config.py" S" app/config.py" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"app/config.py" => "x = 1\n"},
      "rationale" => "planner colon wins"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      Run.run("config",
        workspace: ws,
        contract: config_contract(),
        planner_fn: planner,
        max_episodes: 1
      )

    assert result.success
    assert result.promoted_words == ["INSTALL"]
    words_dir = Path.join([result.run_dir, "dictionary", "words"])
    assert File.exists?(Path.join(words_dir, "INSTALL.fs"))
    refute File.exists?(Path.join(words_dir, "INSTALL-APP-CONFIG.fs"))

    events =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    promoted = for %{"kind" => "dictionary.promoted"} = e <- events, do: e["payload"]["word"]
    assert promoted == ["INSTALL"]
  end

  test "extract-after-success persists INSTALL-APP-CONFIG when the planner defines no colon" do
    ws = workspace()

    envelope = %{
      "language" => "forth",
      "program" => idiom_program("app/config.py", ["claims.json"]),
      "artifacts" => %{
        "app/config.py" => "timeout = 1\n",
        "claims.json" => "{}\n"
      },
      "rationale" => "artifact dump"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      Run.run("config",
        workspace: ws,
        contract: config_contract(),
        planner_fn: planner,
        max_episodes: 1,
        allowed_globs: ["app/config.py", "claims.json", ".sb/*"]
      )

    assert result.success
    assert result.promoted_words == ["INSTALL-APP-CONFIG"]
    file = Path.join([result.run_dir, "dictionary", "words", "INSTALL-APP-CONFIG.fs"])
    assert File.read!(file) == Extract.definition_source("INSTALL-APP-CONFIG")

    identity =
      Dictionary.load_identity(Path.join(result.run_dir, "dictionary"), "INSTALL-APP-CONFIG")

    assert identity["path_region"] == ["app/config.py"]
    assert identity["effects"] == ["read", "write"]
    assert identity["task_families"] == []

    events =
      result.run_dir
      |> Path.join("events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    promo = Enum.find(events, &(&1["kind"] == "dictionary.promoted"))
    assert promo["payload"]["word"] == "INSTALL-APP-CONFIG"
    assert promo["payload"]["path_region"] == ["app/config.py"]
    refute Enum.any?(events, &(&1["kind"] == "dictionary.overlay.admitted"))
  end

  test "LD_EXTRACT=0 skips extract-after-success" do
    ws = workspace()
    prev = System.get_env("LD_EXTRACT")
    System.put_env("LD_EXTRACT", "0")

    envelope = %{
      "language" => "forth",
      "program" => idiom_program("app/config.py"),
      "artifacts" => %{"app/config.py" => "x = 1\n"},
      "rationale" => "disabled"
    }

    planner = fn _g, _o, _f -> {:ok, envelope, %{}} end

    result =
      try do
        Run.run("config",
          workspace: ws,
          contract: config_contract(),
          planner_fn: planner,
          max_episodes: 1
        )
      after
        if prev, do: System.put_env("LD_EXTRACT", prev), else: System.delete_env("LD_EXTRACT")
      end

    assert result.success
    assert result.promoted_words == []
    refute File.exists?(Path.join([result.run_dir, "dictionary", "words", "INSTALL-APP-CONFIG.fs"]))
  end

  test "critic reject of extracted word is evidence only" do
    dir = dict_dir()
    {:ok, cand} = Extract.candidate(idiom_program("app/config.py"))

    broken = %{
      cand
      | body: "MYSTERY",
        source: ": #{cand.name} #{cand.contract} MYSTERY ;\n"
    }

    assert {:reject, errors} = Extract.admit(broken, prelude: "", allowed_globs: ["**"])
    assert Enum.any?(errors, &(&1 =~ "unknown word" or &1 =~ "MYSTERY"))
    refute File.exists?(Path.join([dir, "words", "#{cand.name}.fs"]))

    assert {:reject, reserved} =
             Extract.admit(
               %{broken | name: "WRITE-FILE", source: Extract.definition_source("WRITE-FILE")},
               prelude: ""
             )

    assert Enum.any?(reserved, &(&1 =~ "reserved"))
    refute File.exists?(Path.join([dir, "words", "WRITE-FILE.fs"]))
  end

  test "replay fixtures admit two family installers and retrieve drops the other family" do
    fixtures = Path.join([LdHost.Critic.repo_root(), "beam", "test", "fixtures", "extract"])
    out = tmp("ldextract-a")
    eval_before = eval_mtime()

    receipt = Extract.replay(fixtures, out)

    assert receipt["candidates"] == 2
    assert receipt["admitted"] == 2
    assert receipt["admit_rate"] == 1.0
    assert receipt["names"] == ["INSTALL-APP-CONFIG", "INSTALL-SRC-RECORDS"]
    assert receipt["retrieve"]["config-08"] == ["INSTALL-APP-CONFIG"]
    assert receipt["retrieve"]["parser-08"] == ["INSTALL-SRC-RECORDS"]
    assert File.exists?(Path.join([out, "dictionary", "words", "INSTALL-APP-CONFIG.fs"]))
    assert File.exists?(Path.join([out, "dictionary", "words", "INSTALL-SRC-RECORDS.fs"]))
    assert eval_mtime() == eval_before
  end

  test "word_name stays distinct across path regions and never unions onto INSTALL" do
    assert Extract.word_name(["app/config.py"]) == "INSTALL-APP-CONFIG"
    assert Extract.word_name(["src/records.py"]) == "INSTALL-SRC-RECORDS"
    assert Extract.word_name(["lib/transform.py"]) == "INSTALL-LIB-TRANSFORM"

    graph =
      Extract.word_name([
        "pipeline/ingest.py",
        "pipeline/offset.py",
        "pipeline/registry.py",
        "pipeline/scale.py"
      ])

    refute graph == "INSTALL"
    refute graph == Extract.word_name(["app/config.py"])
    assert String.starts_with?(graph, "INSTALL-")
    assert Dictionary.safe_name?(graph)
  end

  defp eval_mtime do
    root = Path.join(LdHost.Critic.repo_root(), "eval")

    Path.wildcard(Path.join(root, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&File.stat!(&1).mtime)
    |> Enum.sort()
    |> List.last()
  end
end
