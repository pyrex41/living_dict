defmodule LdHost.DictionaryTest do
  use ExUnit.Case, async: true

  alias LdHost.{Contracts, Dictionary, Forth}

  defp dict_dir do
    tmp =
      System.tmp_dir!()
      |> Path.join("lddict-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "words"))
    tmp
  end

  test "contract extraction finds the group after the name only" do
    source =
      ~s{( plain note ) : INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; : BARE DUP ;}

    contracts = Contracts.extract(source)
    assert contracts == %{"INSTALL" => " key -- | read, write "}
  end

  test "canonical rendering sorts effects and normalizes spacing" do
    assert Contracts.canonical(" key -- | write, read ") == "( key -- | read, write )"
    assert Contracts.canonical("a b -- c") == "( a b -- c )"
    assert Contracts.canonical(" -- ") == "( -- )"
    assert Contracts.canonical("no dashes") == nil
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

    assert File.read!(file) ==
             ": INSTALL ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"

    # byte-identical resave is a no-op
    assert Dictionary.save_words(dir, [
             {"INSTALL", "DUP USE-ARTIFACT SWAP WRITE-FILE DROP", "( key -- | read, write )"}
           ]) == []
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
    assert Dictionary.load_prelude(
             System.tmp_dir!()
             |> Path.join("nope-#{System.unique_integer()}")
           ) == {"", []}
  end

  test "prelude skips AppleDouble sidecars and invalid UTF-8 word files" do
    dir = dict_dir()
    File.write!(Path.join([dir, "words", "CAT.fs"]), ": CAT ( -- ) ;\n")
    # macOS copyfile sidecar: File.ls includes `._CAT.fs`; basename fails @safe_name.
    File.write!(Path.join([dir, "words", "._CAT.fs"]), <<0xA3, 0, 0, 0, "ATTR">>)
    File.write!(Path.join([dir, "words", "JUNK.fs"]), <<0xA3, 0, 0, 0, "ATTR">>)

    {prelude, words} = Dictionary.load_prelude(dir)
    assert words == ["CAT"]
    assert prelude =~ ": CAT"
    refute prelude =~ <<0xA3>>

    assert [{"CAT", tokens, {[], [], []}, source}] = Dictionary.load_vocab(dir)
    assert tokens == []
    assert source =~ ": CAT"
  end

  test "load_vocab returns colon bodies and contract tuples in topo order" do
    dir = dict_dir()

    File.write!(
      Path.join([dir, "words", "INSTALL.fs"]),
      ": INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ;\n"
    )

    File.write!(Path.join([dir, "words", "AAA.fs"]), ": AAA ( n -- n n n ) ZZZ DUP ;\n")
    File.write!(Path.join([dir, "words", "ZZZ.fs"]), ": ZZZ ( n -- n n ) DUP ;\n")

    names = Enum.map(Dictionary.load_vocab(dir), &elem(&1, 0))
    assert names == ["ZZZ", "AAA", "INSTALL"]

    {_, install_tokens, install_sig, _} =
      Dictionary.load_vocab(dir) |> Enum.find(fn {name, _, _, _} -> name == "INSTALL" end)

    assert install_sig == {["key", "path"], [], ["read", "write"]}

    assert Enum.map(install_tokens, & &1.value) == [
             "SWAP",
             "USE-ARTIFACT",
             "SWAP",
             "WRITE-FILE",
             "DROP"
           ]
  end

  test "load skips files whose colon name does not match the filename stem" do
    dir = dict_dir()
    File.write!(Path.join([dir, "words", "FOO.fs"]), ": BAR ( n -- n ) DUP ;\n")
    File.write!(Path.join([dir, "words", "CAT.fs"]), ": CAT ( -- ) ;\n")

    {prelude, words} = Dictionary.load_prelude(dir)
    assert words == ["CAT"]
    refute prelude =~ "BAR"

    names = Enum.map(Dictionary.load_vocab(dir), &elem(&1, 0))
    assert names == ["CAT"]
  end

  test "used_names is first-seen catalog tokens, empty on tokenize failure" do
    assert Dictionary.used_names(~s{S" a" PATCH RECEIPT}, ["PATCH"]) == ["PATCH"]
    assert Dictionary.used_names("INSTALL DUP INSTALL", ["install", "MISSING"]) == ["INSTALL"]
    assert Dictionary.used_names("RECEIPT", ["PATCH"]) == []
    assert Dictionary.used_names("PATCH", []) == []
    assert Dictionary.used_names(~s{S" unterminated}, ["PATCH"]) == []
  end

  test "mark_promoted records reuse-proven names without rewriting bodies" do
    dir = dict_dir()

    Dictionary.save_words(dir, [
      {"INSTALL", "DUP USE-ARTIFACT SWAP WRITE-FILE DROP", "( key -- | read, write )"}
    ])

    assert Dictionary.load_promoted(dir) == []
    assert [{"INSTALL", sha}] = Dictionary.mark_promoted(dir, ["INSTALL"])
    assert is_binary(sha)
    assert Dictionary.load_promoted(dir) == ["INSTALL"]
    assert Dictionary.mark_promoted(dir, ["INSTALL"]) == []
    assert File.read!(Path.join(dir, "promoted.txt")) == "INSTALL\n"
  end

  test "tautology? is stack sugar plus exactly one host primitive" do
    cat = Forth.tokenize("READ-FILE DROP")
    ls = Forth.tokenize("LIST-DIR")
    install = Forth.tokenize("SWAP USE-ARTIFACT SWAP WRITE-FILE DROP")
    sugar_only = Forth.tokenize("DUP SWAP")

    assert Dictionary.tautology?(cat)
    assert Dictionary.tautology?(ls)
    refute Dictionary.tautology?(install)
    refute Dictionary.tautology?(sugar_only)
    refute Dictionary.tautology?([])
  end
end
