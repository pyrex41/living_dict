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
    assert Dictionary.load_prelude(System.tmp_dir!() |> Path.join("nope-#{System.unique_integer()}")) == {"", []}
  end
end
