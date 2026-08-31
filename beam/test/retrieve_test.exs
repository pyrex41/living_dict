defmodule LdHost.RetrieveTest do
  use ExUnit.Case, async: false

  alias LdHost.{Dictionary, Retrieve, Store}

  defp dict_dir do
    tmp =
      System.tmp_dir!()
      |> Path.join("ldret-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "words"))
    tmp
  end

  defp seed_mixed(dir) do
    Dictionary.save_words(
      dir,
      [
        {"CONFIG", ~s{S" x" S" app/config.py" WRITE-FILE DROP}, "( -- | write )"},
        {"PARSER", ~s{S" x" S" src/records.py" WRITE-FILE DROP}, "( -- | write )"},
        {"GRAPH", ~s{S" x" S" pipeline/foo.py" WRITE-FILE DROP}, "( -- | write )"},
        {"EXECY", "DUP", "( n -- n n | exec )"}
      ],
      allowed_globs: ["**"]
    )
  end

  test "default dict mode is load-all" do
    prev = System.get_env("LD_DICT_MODE")
    System.delete_env("LD_DICT_MODE")

    try do
      assert Retrieve.mode([]) == :load_all
      assert Retrieve.mode(dict_mode: "frozen-hash") == :load_all
      assert Retrieve.mode(dict_mode: :retrieved) == :retrieved
      assert Retrieve.mode(dict_mode: "retrieved") == :retrieved
      System.put_env("LD_DICT_MODE", "retrieved")
      assert Retrieve.mode([]) == :retrieved
      assert Retrieve.mode(dict_mode: :load_all) == :load_all
    after
      if prev, do: System.put_env("LD_DICT_MODE", prev), else: System.delete_env("LD_DICT_MODE")
    end
  end

  test "host query is grant+path only — no family, no ins/outs" do
    query = Retrieve.host_query(["write", "read"], ["app/config.py"], ["tests/**", "TASK.md"])
    assert query["grant_effects"] == ["read", "write"]
    assert query["grant_globs"] == ["app/config.py"]
    assert query["path_region"] == ["app/config.py"]
    assert query["forbidden_globs"] == ["tests/**", "TASK.md"]
    refute Map.has_key?(query, "family")
    refute Map.has_key?(query, "task_families")
    refute Map.has_key?(query, "ins")
    refute Map.has_key?(query, "outs")
    refute Map.has_key?(query, "counterexamples")
  end

  test "match requires effects subset, region∩grant, not forbidden" do
    query = Retrieve.host_query(["read", "write", "exec"], ["app/config.py"], ["tests/**"])

    assert Retrieve.eligible?(%{"effects" => ["write"], "path_region" => ["app/config.py"]}, query)
    refute Retrieve.eligible?(%{"effects" => ["write"], "path_region" => ["src/records.py"]}, query)
    refute Retrieve.eligible?(%{"effects" => ["net"], "path_region" => ["app/config.py"]}, query)
    refute Retrieve.eligible?(%{"effects" => ["write"], "path_region" => ["tests/test_public.py"]}, query)
    refute Retrieve.eligible?(%{"effects" => ["write"], "path_region" => ["**"]}, query)
    refute Retrieve.eligible?(%{"effects" => ["write"], "path_region" => []}, query)
  end

  test "index from facts uses :word/effects and :word/region, not family" do
    sha = String.duplicate("a", 64)

    events = [
      %{
        "kind" => "dictionary.promoted",
        "payload" => %{
          "word" => "CONFIG",
          "sha256" => sha,
          "effects" => ["write"],
          "path_region" => ["app/config.py"],
          "task_families" => ["config_migration"]
        },
        "sequence" => 1
      },
      %{
        "kind" => "dictionary.promoted",
        "payload" => %{
          "word" => "PARSER",
          "sha256" => sha,
          "effects" => ["write"],
          "path_region" => ["src/records.py"]
        },
        "sequence" => 2
      }
    ]

    facts = Store.facts(events)
    attrs = for {e, a, _v, _} <- facts, do: {e, a}
    assert {"word/CONFIG", ":word/effects"} in attrs
    assert {"word/CONFIG", ":word/region"} in attrs
    refute Enum.any?(attrs, fn {_e, a} -> a in [":word/family", ":word/task_families"] end)

    index = Retrieve.index_from_facts(facts)
    refute Map.has_key?(index["CONFIG"], "task_families")

    query = Retrieve.host_query(["write"], ["app/config.py"], ["tests/**"])
    assert Retrieve.candidates(index, query) == ["CONFIG"]
  end

  test "index from identity blob plus dir sidecars" do
    dir = dict_dir()
    seed_mixed(dir)
    store = Store.new(Path.join(dir, "objects"))
    {_hex, _display, _} = Dictionary.intern_from_dir(store, dir)
    words = Dictionary.words_identity(store, dir)
    blob = Dictionary.identity(nil, LdHost.Forth.primitive_contract(), words)

    from_blob = Retrieve.index_from_identity(blob)
    from_dir = Retrieve.index_from_dir(dir)
    assert Map.keys(from_blob) |> Enum.sort() == ["CONFIG", "EXECY", "GRAPH", "PARSER"]
    assert from_dir["CONFIG"]["path_region"] == ["app/config.py"]
    assert from_blob["PARSER"]["effects"] == ["write"]

    query = Retrieve.host_query(["read", "write", "exec"], ["src/records.py"], ["tests/**"])
    merged = Retrieve.index(dictionary_dir: dir, identity: blob, facts: [])
    assert Retrieve.candidates(merged, query) == ["PARSER"]
  end

  test "load_prelude retrieved subsets; load-all keeps mixed-family warm" do
    dir = dict_dir()
    seed_mixed(dir)

    {_all, all_names} = Dictionary.load_prelude(dir)
    assert all_names == ["CONFIG", "EXECY", "GRAPH", "PARSER"]

    query = Retrieve.host_query(["read", "write", "exec"], ["app/config.py"], ["tests/**", "TASK.md"])
    {_pre, names} = Dictionary.load_prelude(dir, dict_mode: :retrieved, query: query)
    assert names == ["CONFIG"]

    pipe = Retrieve.host_query(["read", "write", "exec"], ["pipeline/*.py"], ["task_graph.json"])
    {_pre, names} = Dictionary.load_prelude(dir, dict_mode: :retrieved, query: pipe)
    assert names == ["GRAPH"]
  end

  test "used_names is first-seen loaded words mentioned in the program" do
    assert Dictionary.used_names("PARSER CONFIG PARSER", ["CONFIG", "PARSER", "GRAPH"]) ==
             ["PARSER", "CONFIG"]

    assert Dictionary.used_names("DUP DROP", ["CONFIG"]) == []
  end

  test "EXEC-only word is dropped when grant has no exec" do
    dir = dict_dir()
    seed_mixed(dir)
    query = Retrieve.host_query(["read", "write"], ["**"], [])
    {_pre, names} = Dictionary.load_prelude(dir, dict_mode: :retrieved, query: query)
    refute "EXECY" in names
    assert "CONFIG" in names
  end
end
