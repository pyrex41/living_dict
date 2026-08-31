defmodule LdHost.DictionaryTest do
  use ExUnit.Case, async: true

  alias LdHost.{Contracts, Dictionary}

  defp dict_dir do
    tmp = System.tmp_dir!() |> Path.join("lddict-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "words"))
    tmp
  end

  test "contract extraction finds the group after the name only" do
    source = ~s{( plain note ) : INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; : BARE DUP ;}
    contracts = Contracts.extract(source)
    assert contracts == %{"INSTALL" => " key -- | read, write "}
  end

  test "canonical rendering sorts effects and normalizes spacing" do
    assert Contracts.canonical(" key -- | write, read ") == "( key -- | read, write )"
    assert Contracts.canonical("a b -- c") == "( a b -- c )"
    assert Contracts.canonical(" -- ") == "( -- )"
    assert Contracts.canonical("no dashes") == nil
  end

  test "effects come from the in-band contract, sorted unique" do
    assert Contracts.effects(" key -- | write, read ") == ["read", "write"]
    assert Contracts.effects("( key -- | read, write )") == ["read", "write"]
    assert Contracts.effects(" n -- n n ") == []
    assert Contracts.effects(nil) == []
  end

  test "path_region is glob-union of literal WRITE-FILE paths else allowed_globs" do
    literals = ~s{S" hello" S" app/a.py" WRITE-FILE DROP S" x" S" app/b.py" WRITE-FILE DROP}
    assert Dictionary.path_region(literals, ["**"]) == ["app/a.py", "app/b.py"]

    computed = "SWAP USE-ARTIFACT SWAP WRITE-FILE DROP"
    assert Dictionary.path_region(computed, ["src/**", "app/**"]) == ["app/**", "src/**"]
    assert Dictionary.path_region("DUP", ["**"]) == ["**"]
  end

  test "topo_order is public and puts definitions before uses" do
    sources = %{
      "AAA" => ": AAA ( n -- n n n ) ZZZ DUP ;",
      "ZZZ" => ": ZZZ ( n -- n n ) DUP ;"
    }

    assert Dictionary.topo_order(sources) == ["ZZZ", "AAA"]
  end

  test "save_words persists contract in-band, skips contractless, idempotent" do
    dir = dict_dir()

    written =
      Dictionary.save_words(dir, [
        {"INSTALL", "DUP USE-ARTIFACT SWAP WRITE-FILE DROP", "( key -- | read, write )"},
        {"NOCONTRACT", "DUP", nil},
        {"lower-bad-name", "DUP", "( a -- a a )"}
      ])

    assert [{"INSTALL", sha}] = written
    assert is_binary(sha)

    file = Path.join([dir, "words", "INSTALL.fs"])
    assert File.read!(file) == ": INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"

    assert Dictionary.load_identity(dir, "INSTALL") == %{
             "effects" => ["read", "write"],
             "path_region" => ["**"],
             "task_families" => []
           }

    # byte-identical resave is a no-op for the .fs; sidecar still refreshes
    assert Dictionary.save_words(dir, [
             {"INSTALL", "DUP USE-ARTIFACT SWAP WRITE-FILE DROP", "( key -- | read, write )"}
           ]) == []

    assert Dictionary.load_identity(dir, "INSTALL")["task_families"] == []
  end

  test "save_words records literal WRITE-FILE path_region and empty family" do
    dir = dict_dir()

    Dictionary.save_words(
      dir,
      [{"GREET", ~s{S" hi" S" greet.txt" WRITE-FILE DROP}, "( -- | write )"}],
      allowed_globs: ["app/**"]
    )

    assert Dictionary.load_identity(dir, "GREET") == %{
             "effects" => ["write"],
             "path_region" => ["greet.txt"],
             "task_families" => []
           }
  end

  test "prelude loads in def-before-use order (topo sort)" do
    dir = dict_dir()
    # AAA calls ZZZ: alphabetical order would break def-before-use.
    File.write!(Path.join([dir, "words", "AAA.fs"]), ": AAA ( n -- n n n ) ZZZ DUP ;\n")
    File.write!(Path.join([dir, "words", "ZZZ.fs"]), ": ZZZ ( n -- n n ) DUP ;\n")

    {prelude, words} = Dictionary.load_prelude(dir)
    assert words == ["ZZZ", "AAA"]
    assert prelude =~ ~r/ZZZ.*AAA/s
  end

  test "empty dictionary loads empty prelude" do
    assert Dictionary.load_prelude(System.tmp_dir!() |> Path.join("nope-#{System.unique_integer()}")) == {"", []}
  end

  test "retrieved load_prelude is a topo-ordered grant+path subset" do
    dir = dict_dir()

    Dictionary.save_words(dir, [
      {"AAA", "ZZZ DUP", "( n -- n n n | write )"},
      {"ZZZ", ~s{S" x" S" app/config.py" WRITE-FILE DROP}, "( n -- n n | write )"},
      {"BBB", ~s{S" x" S" src/records.py" WRITE-FILE DROP}, "( -- | write )"}
    ])

    query =
      LdHost.Retrieve.host_query(["read", "write", "exec"], ["app/config.py"], ["tests/**"])

    {prelude, words} = Dictionary.load_prelude(dir, dict_mode: :retrieved, query: query)
    assert words == ["ZZZ"]
    assert prelude =~ ": ZZZ"
    refute prelude =~ ": BBB"
    refute prelude =~ ": AAA"
  end

  test "prelude skips AppleDouble sidecars and invalid UTF-8 word files" do
    dir = dict_dir()
    File.write!(Path.join([dir, "words", "CAT.fs"]), ": CAT ( -- ) ;\n")
    # macOS copyfile sidecar: glob `*.fs` matches `._CAT.fs`; content is binary.
    File.write!(Path.join([dir, "words", "._CAT.fs"]), <<0xA3, 0, 0, 0, "ATTR">>)
    File.write!(Path.join([dir, "words", "JUNK.fs"]), <<0xA3, 0, 0, 0, "ATTR">>)

    {prelude, words} = Dictionary.load_prelude(dir)
    assert words == ["CAT"]
    assert prelude =~ ": CAT"
    refute prelude =~ <<0xA3>>
  end
end
