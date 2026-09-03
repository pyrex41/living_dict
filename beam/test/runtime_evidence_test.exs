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

  # Re-sign a whole oplog after editing entries, so only semantic checks can
  # catch the edit (the chain itself stays valid).
  defp resign_oplog!(dir, edit) do
    path = Path.join(dir, "oplog.jsonl")
    entries = File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    zero = String.duplicate("0", 64)

    {lines, _} =
      entries
      |> Enum.flat_map(fn entry ->
        case edit.(entry) do
          nil -> []
          edited -> [edited]
        end
      end)
      |> Enum.with_index()
      |> Enum.map_reduce(zero, fn {e, sequence}, prev ->
        e =
          e
          |> Map.delete("entry_hash")
          |> Map.put("sequence", sequence)
          |> Map.put("previous_entry_hash", prev)

        h = LdHost.JCS.hash!(e)
        {LdHost.JCS.encode!(Map.put(e, "entry_hash", h)), h}
      end)

    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  test "every property the executor claims is re-derived from the files" do
    for name <- ~w(kv order order-resumed order-sigkill order-sigkill-provider) do
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

  test "a SIGKILLed run recovers without any fault-injection marker" do
    for name <- ~w(order-sigkill order-sigkill-provider) do
      oplog = File.read!(Path.join(fixture(name), "oplog.jsonl"))
      refute oplog =~ ~s("kind":"fault-injection"), name
      receipt = receipt(name)
      assert receipt["recovery"]["kill_mode"] == "sigkill"

      assert {:ok, %{properties: props, summary: summary}} =
               RuntimeEvidence.verify(fixture(name), receipt)

      assert MapSet.member?(props, "crash-recovered"), name
      assert MapSet.member?(props, "effects-exactly-once"), name
      assert summary.interrupted_segments == 1
    end

    provider = File.read!(Path.join(fixture("order-sigkill-provider"), "provider-calls.jsonl"))
    assert provider =~ ~s("kind":"restart")
    assert receipt("order-sigkill-provider")["recovery"]["kill_provider"] == true
  end

  test "the branch manifest must name the parent route's own final entry" do
    dir = copy("order")
    path = Path.join(dir, "branches/fork/manifest.json")
    m = File.read!(path) |> JSON.decode!()
    # Substitute another valid oplog hash: the fork route's exit entry.
    fork_exit =
      File.read!(Path.join(dir, "oplog.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(&(&1["route"] == "fork" and &1["kind"] == "exit"))

    refute m["parent_final_oplog_hash"] == fork_exit["entry_hash"]

    File.write!(
      path,
      LdHost.JCS.encode!(Map.put(m, "parent_final_oplog_hash", fork_exit["entry_hash"]))
    )

    receipt = put_in(receipt("order"), ["evidence", "branch", "sha256"], sha(File.read!(path)))
    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt)
    assert reason =~ "parent route's final entry"
  end

  test "a reissue whose request differs from the journaled intent is rejected" do
    dir = copy("order-resumed")

    resign_oplog!(dir, fn
      %{"kind" => "effect-reissue"} = e ->
        put_in(e, ["input", "request_hash"], String.duplicate("e", 64))

      e ->
        e
    end)

    receipt =
      put_in(
        receipt("order-resumed"),
        ["evidence", "oplog", "sha256"],
        sha(File.read!(Path.join(dir, "oplog.jsonl")))
      )

    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt)
    assert reason =~ "reissue differs from the journaled intent"
  end

  test "a delivered result that differs from its commit is rejected" do
    dir = copy("order")

    resign_oplog!(dir, fn
      %{"kind" => "capability-result", "input" => %{"source" => "provider"}} = e ->
        put_in(e, ["result", "result_hash"], String.duplicate("d", 64))

      e ->
        e
    end)

    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt("order"))
    assert reason =~ "delivered result differs"
  end

  test "exactly-once requires every committed result to be delivered" do
    dir = copy("order")

    resign_oplog!(dir, fn
      %{"kind" => "capability-result", "input" => %{"source" => "provider"}} = e ->
        _ = e
        nil

      e ->
        e
    end)

    parent_exit =
      Path.join(dir, "oplog.jsonl")
      |> File.stream!()
      |> Stream.map(&JSON.decode!/1)
      |> Enum.find(&(&1["route"] == "parent" and &1["kind"] == "exit"))

    branch_path = Path.join(dir, "branches/fork/manifest.json")

    branch =
      branch_path
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("parent_final_oplog_hash", parent_exit["entry_hash"])
      |> LdHost.JCS.encode!()

    File.write!(branch_path, branch)

    receipt =
      receipt("order")
      |> put_in(
        ["evidence", "oplog", "sha256"],
        sha(File.read!(Path.join(dir, "oplog.jsonl")))
      )
      |> put_in(["evidence", "branch", "sha256"], sha(branch))

    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt)
    assert reason =~ "effects-exactly-once"
  end

  test "replay stability requires snapshot roundtrip witnesses" do
    dir = copy("kv")

    resign_oplog!(dir, fn
      %{"kind" => "snapshot-roundtrip", "route" => "replay-1"} -> nil
      e -> e
    end)

    receipt =
      put_in(
        receipt("kv"),
        ["evidence", "oplog", "sha256"],
        sha(File.read!(Path.join(dir, "oplog.jsonl")))
      )

    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt)
    assert reason =~ "replay-stable"
  end

  test "the scenario bytes are bound into the receipt" do
    dir = copy("order")
    path = Path.join(dir, "scenario.json")

    File.write!(
      path,
      String.replace(File.read!(path), ~s("advance_ms":250), ~s("advance_ms":251))
    )

    assert {:error, "scenario hash mismatch"} = RuntimeEvidence.verify(dir, receipt("order"))
  end

  test "exactly-once is never vacuous and needs its witnesses" do
    refute "effects-exactly-once" in receipt("kv")["properties"]
    dir = copy("order")
    path = Path.join(dir, "scenario.json")
    s = File.read!(path) |> JSON.decode!() |> put_in(["expected_effects", "payment.charge"], 2)
    bytes = JSON.encode!(s)
    File.write!(path, bytes)
    receipt = receipt("order") |> Map.put("scenario_hash", sha(bytes))
    # run_id no longer derives (it includes the scenario hash) so fix it up too.
    receipt =
      Map.put(
        receipt,
        "run_id",
        LdHost.JCS.hash!(%{
          "config_hash" => receipt["machine_config_hash"],
          "scenario_hash" => receipt["scenario_hash"],
          "scenario_id" => receipt["scenario_id"],
          "seed" => receipt["seed"]
        })
      )

    assert {:error, reason} = RuntimeEvidence.verify(dir, receipt)

    # Keys no longer derive from the changed run id: the evidence is bound to the original scenario.
    assert reason =~ "effect key is not host-derived" or reason =~ "checkpoint"
  end

  test "the engine attestation is recomputed, not trusted" do
    receipt = put_in(receipt("kv"), ["engine", "settings", "wasm_threads"], true)

    assert {:error, "engine config_hash does not match its settings"} =
             RuntimeEvidence.verify(fixture("kv"), receipt)

    receipt = put_in(receipt("kv"), ["engine", "target_triple"], "wasm32-wasip1")

    assert {:error, "target triple is not allowlisted"} =
             RuntimeEvidence.verify(fixture("kv"), receipt)

    receipt = put_in(receipt("kv"), ["engine", "toolchain_hash"], String.duplicate("1", 64))
    assert {:error, reason} = RuntimeEvidence.verify(fixture("kv"), receipt)
    assert reason =~ "toolchain hash"
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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

    assert {:error, "engine config_hash does not match its settings"} =
             RuntimeEvidence.verify(fixture("kv"), receipt)

    # Consistent but not allowlisted: settings changed and hash recomputed.
    settings =
      Map.put(receipt("kv")["engine"]["settings"], "cranelift_nan_canonicalization", false)

    receipt =
      receipt("kv")
      |> put_in(["engine", "settings"], settings)
      |> put_in(["engine", "config_hash"], LdHost.JCS.hash!(settings))

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
