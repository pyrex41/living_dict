defmodule LdHost.JCSTest do
  use ExUnit.Case, async: true

  alias LdHost.JCS

  test "sorts keys, strips whitespace, escapes only what RFC 8785 escapes" do
    assert JCS.encode!(%{"b" => 1, "a" => "x\né\"\\"}) ==
             ~s({"a":"x\\n\\u0001é\\"\\\\","b":1})
  end

  test "nested containers, null, booleans, and big integers survive exactly" do
    value = %{"z" => [nil, true, false, %{"k" => 11_400_714_819_323_198_485}], "a" => []}
    assert JCS.encode!(value) == ~s({"a":[],"z":[null,true,false,{"k":11400714819323198485}]})
  end

  test "atom keys and values encode as strings" do
    assert JCS.encode!(%{kind: :exit}) == ~s({"kind":"exit"})
  end

  test "floats are refused" do
    assert_raise ArgumentError, fn -> JCS.encode!(%{"x" => 1.5}) end
  end

  test "matches the executor's serde_jcs hashes on real oplog entries" do
    for fixture <- ~w(kv order order-resumed) do
      path = Path.expand("fixtures/runtime/#{fixture}/oplog.jsonl", __DIR__)

      for line <- File.read!(path) |> String.split("\n", trim: true) |> Enum.take(40) do
        entry = JSON.decode!(line)
        assert JCS.hash!(Map.delete(entry, "entry_hash")) == entry["entry_hash"]
      end
    end
  end
end
