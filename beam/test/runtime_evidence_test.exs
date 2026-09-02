defmodule LdHost.RuntimeEvidenceTest do
  use ExUnit.Case, async: true

  alias LdHost.RuntimeEvidence

  @fixtures Path.expand("fixtures/runtime", __DIR__)

  defp fixture(name), do: Path.join(@fixtures, name)

  defp receipt(name),
    do: fixture(name) |> Path.join("receipt.json") |> File.read!() |> JSON.decode!()

  defp copy(name) do
    tmp =
      System.tmp_dir!()
      |> Path.join("ldev-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.cp_r!(fixture(name), tmp)
    tmp
  end

  test "every property the executor claims is re-derived from the files" do
    for name <- ~w(kv order order-resumed) do
      receipt = receipt(name)

      assert {:ok, %{properties: props, summary: summary}} =
               RuntimeEvidence.verify(fixture(name), receipt)

      assert MapSet.subset?(MapSet.new(receipt["properties"]), props), name
      assert summary.entries > 20
      assert "recovered" in summary.routes
    end
  end

  test "the resumed fixture establishes crash recovery and exactly-once across the kill" do
    receipt = receipt("order-resumed")
    assert receipt["recovery"]["resumed"] == true
    assert receipt["recovery"]["kill_point"] == "after-provider-before-commit"

    assert {:ok, %{properties: props, summary: summary}} =
             RuntimeEvidence.verify(fixture("order-resumed"), receipt)

    assert MapSet.member?(props, "crash-recovered")
    assert MapSet.member?(props, "effects-exactly-once")
    assert summary.resumed
    assert summary.provider_executed == 4
  end

  test "a flipped byte in the oplog breaks the chain" do
    dir = copy("kv")
    path = Path.join(dir, "oplog.jsonl")
    [l1, l2 | rest] = File.read!(path) |> String.split("\n", trim: true)
    l2 = String.replace(l2, ~s("route":"parent"), ~s("route":"pareNt"))
    File.write!(path, Enum.join([l1, l2 | rest], "\n") <> "\n")
    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt("kv"))
    assert reason =~ "chain broken"
  end

  test "a receipt cannot claim more than the evidence establishes" do
    receipt = update_in(receipt("kv"), ["properties"], &["crash-recovered" | &1])
    assert {:error, reason} = RuntimeEvidence.verify(fixture("kv"), receipt)
    assert reason =~ "does not establish: crash-recovered"
  end

  test "exactly-once needs the provider's own log, not the executor's word" do
    dir = copy("order")
    File.rm!(Path.join(dir, "provider-calls.jsonl"))
    receipt = update_in(receipt("order"), ["evidence"], &Map.delete(&1, "provider_calls"))
    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt)
    assert reason =~ "effects-exactly-once"
  end

  test "a provider log that disagrees with the journal fails exactly-once" do
    dir = copy("order")
    path = Path.join(dir, "provider-calls.jsonl")
    # Re-sign a tampered provider log so only the semantic check can catch it.
    entries = File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    zero = String.duplicate("0", 64)

    {lines, _} =
      Enum.map_reduce(entries, zero, fn e, prev ->
        e = e |> Map.delete("entry_hash") |> Map.put("previous_hash", prev)
        e = if e["status"] == "executed", do: Map.put(e, "result_hash", zero), else: e
        h = LdHost.JCS.hash!(e)
        {LdHost.JCS.encode!(Map.put(e, "entry_hash", h)), h}
      end)

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt("order"))
    assert reason =~ "effects-exactly-once"
  end

  test "engine attestation must be allowlisted" do
    receipt = put_in(receipt("kv"), ["engine", "config_hash"], String.duplicate("f", 64))

    assert {:error, "engine configuration is not allowlisted"} =
             RuntimeEvidence.verify(fixture("kv"), receipt)

    receipt = put_in(receipt("kv"), ["engine", "world_hash"], String.duplicate("f", 64))

    assert {:error, "component world is not allowlisted"} =
             RuntimeEvidence.verify(fixture("kv"), receipt)
  end

  test "the receipt must agree with the parent route and the oplog" do
    assert {:error, reason} =
             RuntimeEvidence.verify(fixture("kv"), Map.put(receipt("kv"), "replay_count", 2))

    assert reason =~ "replay count"

    assert {:error, reason} =
             RuntimeEvidence.verify(
               fixture("kv"),
               Map.put(receipt("kv"), "final_state_hash", String.duplicate("a", 64))
             )

    assert reason =~ "final state"

    assert {:error, reason} =
             RuntimeEvidence.verify(
               fixture("kv"),
               Map.put(receipt("kv"), "run_id", String.duplicate("a", 64))
             )

    assert reason =~ "run identity"
  end

  test "a checkpoint whose host state was edited is rejected" do
    dir = copy("order")
    path = Path.join(dir, "checkpoint.json")
    cp = File.read!(path) |> JSON.decode!()
    File.write!(path, LdHost.JCS.encode!(put_in(cp, ["host", "time"], 0)))
    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt("order"))
    assert reason =~ "checkpoint"
  end
end
