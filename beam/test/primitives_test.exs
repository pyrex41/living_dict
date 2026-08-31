defmodule LdHost.PrimitivesTest do
  @moduledoc """
  Primitive-contract spec vs BEAM Forth tables and shaken Shen (LdHost.Critic).
  Semantic equality is Accept/Reject class plus error substrings, not
  byte-identical HOST_DICTIONARY on Python/Lua/JS (documented drift).
  """
  use ExUnit.Case

  alias LdHost.Forth

  defp repo_root, do: LdHost.Critic.repo_root()

  defp spec_path, do: Path.join(repo_root(), "spec/primitives.v1.json")

  defp spec do
    spec_path() |> File.read!() |> JSON.decode!()
  end

  defp spec_digest do
    :crypto.hash(:sha256, File.read!(spec_path())) |> Base.encode16(case: :lower)
  end

  defp names_of(class) when is_binary(class) do
    for {name, word} <- spec()["words"], word["class"] == class, do: name
  end

  defp names_of(classes) when is_list(classes) do
    for {name, word} <- spec()["words"], word["class"] in classes, do: name
  end

  defp joined_errors(errors) when is_list(errors), do: Enum.join(errors, " ")

  test "generator tables match spec; --check is clean" do
    {out, 0} =
      System.cmd("python3", ["tools/gen_primitives.py", "spec/primitives.v1.json", "--check"],
        cd: repo_root(),
        stderr_to_stdout: true
      )

    assert out =~ spec_digest()
    assert Forth.primitive_contract() == spec_digest()
    assert String.length(Forth.primitive_contract()) == 64
    refute String.starts_with?(Forth.primitive_contract(), "sha256:")

    assert MapSet.new(Forth.host_words()) == MapSet.new(names_of(["host", "ir"]))
    assert MapSet.new(Forth.stack_words()) == MapSet.new(names_of("stack"))

    assert Forth.host_words() == [
             "READ-FILE",
             "LIST-DIR",
             "SEARCH",
             "WRITE-FILE",
             "RUN-TESTS",
             "RUN-GATES",
             "RECEIPT",
             "USE-ARTIFACT"
           ]

    assert Forth.stack_words() == ["DUP", "DROP", "SWAP", "OVER", "+", "-", "*"]

    words = spec()["words"]
    assert words["RUN-GATES"]["eval_abi"] == true
    assert words["RUN-TESTS"]["eval_abi"] == true
    assert words["USE-ARTIFACT"]["class"] == "ir"
    assert words["IF"]["join"] == "shape"
    refute Map.has_key?(words, ":")
    refute Map.has_key?(words, ";")
  end

  test "shaken Shen + LdHost.Critic: Accept/Reject class and error substrings" do
    engine = LdHost.Critic.engine()
    assert engine != :none, "LdHost.Critic required for primitive semantic equality, got #{inspect(engine)}"

    {:accept, _depth, effects} =
      LdHost.Critic.validate(
        ~s{S" src/records.py" USE-ARTIFACT S" src/records.py" WRITE-FILE RUN-TESTS RECEIPT},
        ["read", "write", "exec"],
        ["src/records.py"],
        [],
        ["src/records.py"]
      )

    assert MapSet.new(effects) == MapSet.new(["read", "write", "exec"])

    {:reject, errors, _depth, _eff} =
      LdHost.Critic.validate(
        ~s{DROP MYSTERY S" tests/test_public.py" WRITE-FILE},
        ["read", "write", "exec"],
        ["app/config.py"],
        ["tests/**"],
        []
      )

    joined = joined_errors(errors)
    assert joined =~ "underflow"
    assert joined =~ "unknown word"
    assert joined =~ "forbidden"

    {:reject, errors, _, _} =
      LdHost.Critic.validate(
        ~s{S" app/config.py" USE-ARTIFACT},
        ["read", "write", "exec"],
        ["**"],
        [],
        []
      )

    assert joined_errors(errors) =~ "no artifact"

    {:reject, errors, _, _} =
      LdHost.Critic.validate(
        ": INSTALL ( a b -- | write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;",
        ["read", "write", "exec"],
        ["**"],
        [],
        ["app/config.py"]
      )

    joined = joined_errors(errors)
    assert joined =~ "contract mismatch"
    assert joined =~ "INSTALL"

    {:reject, errors, _, _} =
      LdHost.Critic.validate(
        ": LOOPY ( -- ) LOOPY ;",
        ["read", "write", "exec"],
        ["**"],
        [],
        []
      )

    assert joined_errors(errors) =~ "recursive"
  end
end
