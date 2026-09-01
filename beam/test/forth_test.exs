defmodule LdHost.ForthTest do
  use ExUnit.Case, async: true

  alias LdHost.Forth
  alias LdHost.Forth.{VM, Error}

  defmodule FakeHost do
    @behaviour LdHost.Capability
    defstruct calls: []

    @impl true
    def call(host, "READ-FILE", [path]), do: {:ok, "content-of-#{path}", log(host, {:read, path})}

    def call(host, "WRITE-FILE", [content, path]),
      do: {:ok, %{path: path, bytes: byte_size(content)}, log(host, {:write, path})}

    def call(host, "RUN-GATES", []), do: {:ok, %{ok: true}, log(host, :gates)}
    def call(host, "RUN-TESTS", []), do: {:ok, %{ok: true}, log(host, :tests)}
    def call(host, "RECEIPT", []), do: {:ok, %{success: true}, log(host, :receipt)}
    def call(host, "LIST-DIR", [path]), do: {:ok, [path <> "/a"], log(host, {:ls, path})}
    def call(host, "SEARCH", [q]), do: {:ok, [], log(host, {:search, q})}
    def call(_host, "TRAP-ME", _), do: {:trap, "policy", "denied"}

    defp log(host, entry), do: %{host | calls: [entry | host.calls]}
  end

  defp vm(artifacts \\ %{}), do: %VM{host: %FakeHost{}, artifacts: artifacts}

  test "tokenize matches the reference: comments stripped, strings, numbers" do
    tokens = Forth.tokenize(~s{\\ comment line\n( a note ) S" hello world" -42 WRITE-FILE})

    assert [
             %{kind: :string, value: "hello world"},
             %{kind: :number, value: -42},
             %{kind: :word, value: "WRITE-FILE"}
           ] =
             tokens

    assert Enum.map(tokens, & &1.index) == [0, 1, 2]
  end

  test "paren opens a comment only before whitespace" do
    assert [%{kind: :word, value: "(paren-word"}] = Forth.tokenize("(paren-word")
  end

  test "unterminated string raises syntax" do
    assert_raise Error, ~r/unterminated S" string/, fn -> Forth.tokenize(~s{S" oops}) end
  end

  test "stack words and arithmetic" do
    result = Forth.interpret(vm(), "2 3 + 4 * DUP SWAP DROP")
    assert result.stack == [20]
  end

  test "colon definition and call" do
    result = Forth.interpret(vm(), ": TWICE ( n -- n n ) DUP ; 5 TWICE")
    assert result.stack == [5, 5]
    assert Forth.defined_names(result) == ["TWICE"]
  end

  test "IF ELSE THEN with truthiness: 0 is false" do
    assert Forth.interpret(vm(), "1 IF 10 ELSE 20 THEN").stack == [10]
    assert Forth.interpret(vm(), "0 IF 10 ELSE 20 THEN").stack == [20]
  end

  test "host word dispatch and artifact lookup" do
    result =
      Forth.interpret(vm(%{"k" => "body"}), ~s{S" k" USE-ARTIFACT S" out.txt" WRITE-FILE DROP})

    assert result.stack == []
    assert {:write, "out.txt"} in result.host.calls
  end

  test "missing artifact traps with reference message" do
    assert_raise Error, ~r/no artifact: nope/, fn ->
      Forth.interpret(vm(), ~s{S" nope" USE-ARTIFACT})
    end
  end

  test "underflow, unknown word, orphan THEN" do
    assert_raise Error, ~r/stack underflow at DROP/, fn -> Forth.interpret(vm(), "DROP") end
    assert_raise Error, ~r/unknown word MYSTERY/, fn -> Forth.interpret(vm(), "MYSTERY") end
    assert_raise Error, ~r/THEN without matching opener/, fn -> Forth.interpret(vm(), "THEN") end
  end

  test "type errors match reference wording" do
    assert_raise Error, ~r/\+ expected integer, got str/, fn ->
      Forth.interpret(vm(), ~s{S" a" 1 +})
    end
  end

  test "nested colon definitions rejected" do
    assert_raise Error, ~r/nested colon definitions are not supported/, fn ->
      Forth.interpret(vm(), ": A : B ; ;")
    end
  end

  test "bind_vocab installs existing colon bodies, not stubs" do
    tokens = Forth.tokenize("DUP")
    row = {"TWICE", tokens, {["n"], ["n", "n"], []}, ": TWICE ( n -- n n ) DUP ;"}
    result = Forth.interpret(Forth.bind_vocab(vm(), [row]), "5 TWICE")
    assert result.stack == [5, 5]
    assert Forth.defined_names(result) == ["TWICE"]
  end

  test "records actual persisted-word invocations, including nested calls" do
    tokens = Forth.tokenize("DUP")
    row = {"TWICE", tokens, {["n"], ["n", "n"], []}, ": TWICE ( n -- n n ) DUP ;"}
    vm = Forth.bind_vocab(vm(), [row])

    result = Forth.interpret(vm, "5 TWICE TWICE")

    assert result.used_words == ["TWICE"]
    assert result.catalog_words == MapSet.new(["TWICE"])
  end

  test "does not count planner-local definitions as catalog use" do
    result = Forth.interpret(vm(), ": LOCAL DUP ; 5 LOCAL")
    assert result.used_words == []
  end

  test "a local definition shadows a persisted name for usage accounting" do
    row = {"LOCAL", Forth.tokenize("DUP"), {["n"], ["n"], []}, ": LOCAL ( n -- n ) DUP ;"}
    result = Forth.interpret(Forth.bind_vocab(vm(), [row]), ": LOCAL DROP ; 5 LOCAL")
    assert result.used_words == []
  end
end
