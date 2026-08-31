defmodule LdHost.EnvelopeTest do
  use ExUnit.Case, async: true

  alias LdHost.{Envelope, Policy, Store}

  defp stub_cartridge(defs) do
    %{
      "parent" => nil,
      "memory_view" => "workspace-head",
      "action_topology" => "sequential",
      "capabilities" => ["write", "read"],
      "budget" => %{"writes" => 8, "execs" => 2},
      "definitions" => defs,
      "entrypoint" => "UNKNOWN-WORD"
    }
  end

  defp envelope(defs) do
    %{
      "language" => "forth",
      "program" => ~s{S" greet.txt" USE-ARTIFACT S" greet.txt" WRITE-FILE DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello\n"},
      "rationale" => "stub",
      "cartridge" => stub_cartridge(defs)
    }
  end

  test "parse without cartridge keeps today's fields and nil cartridge" do
    {:ok, env} =
      Envelope.parse(%{
        "program" => "RECEIPT",
        "artifacts" => %{},
        "rationale" => "n"
      })

    assert env.cartridge == nil
    assert env.program == "RECEIPT"
  end

  test "parse rejects unknown and missing cartridge keys" do
    extra = envelope(%{"A" => ": A ( -- ) ;"})
    extra = put_in(extra["cartridge"]["surprise"], 1)

    assert {:error, msg} = Envelope.parse(extra)
    assert msg =~ "unknown keys"
    assert msg =~ "surprise"

    missing = envelope(%{"A" => ": A ( -- ) ;"})
    missing = update_in(missing["cartridge"], &Map.delete(&1, "entrypoint"))
    assert {:error, miss} = Envelope.parse(missing)
    assert miss =~ "missing keys"
    assert miss =~ "entrypoint"
  end

  test "fingerprint is unchanged when cartridge is absent" do
    raw = %{
      "program" => ~s{S" x" USE-ARTIFACT S" x" WRITE-FILE},
      "artifacts" => %{"x" => "y"}
    }

    {:ok, env} = Envelope.parse(raw)
    tokens =
      env.program
      |> LdHost.Forth.tokenize()
      |> Enum.map(fn t -> "#{t.kind}:#{t.value}" end)
      |> Enum.join(<<0>>)

    artifacts =
      env.artifacts
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> "#{k}:#{Policy.sha256_hex(v)}" end)
      |> Enum.join(<<0>>)

    assert Envelope.fingerprint(env) == Policy.sha256_hex(tokens <> <<1>> <> artifacts)
  end

  test "stub cartridge fingerprint includes interned overlay; definition repair is a new plan" do
    {:ok, a} = Envelope.parse(envelope(%{"INSTALL-CONFIG" => ": INSTALL-CONFIG ( -- ) DUP ;"}))
    {:ok, a_prime} = Envelope.parse(envelope(%{"INSTALL-CONFIG" => ": INSTALL-CONFIG ( -- ) DROP ;"}))
    {:ok, again} = Envelope.parse(envelope(%{"INSTALL-CONFIG" => ": INSTALL-CONFIG ( -- ) DUP ;"}))

    assert Envelope.fingerprint(a) == Envelope.fingerprint(again)
    refute Envelope.fingerprint(a) == Envelope.fingerprint(a_prime)

    ident = Envelope.overlay_identity(a.cartridge)
    hex = Policy.sha256_hex(": INSTALL-CONFIG ( -- ) DUP ;")
    assert ident["definitions"]["INSTALL-CONFIG"] == hex
    assert String.length(hex) == 64
    refute String.starts_with?(hex, "sha256:")
    refute String.contains?(Envelope.overlay_bytes(a.cartridge), "sha256:")
    assert ident["capabilities"] == ["read", "write"]
    assert ident["parent"] == nil

    bytes = Envelope.overlay_bytes(a.cartridge)
    assert bytes == Store.canonical_json(ident)
    refute bytes == Envelope.overlay_bytes(a_prime.cartridge)
  end
end
