defmodule LdHost.KillMatrixTest do
  @moduledoc """
  Every evidence directory the kill matrix produced (`make durable-gate`
  leaves them under `spike/wasm/.livingdict-run/kill-matrix`) must verify
  independently: chain, journal, provider log, checkpoint, lineage, and
  every property the resumed receipt claims, including crash recovery and
  exactly-once. Static fixtures cannot drift from the executor if the
  freshly generated evidence is checked too.
  """
  use ExUnit.Case, async: true

  @wasm Path.expand("../../spike/wasm", __DIR__)
  @matrix Path.join(@wasm, ".livingdict-run/kill-matrix")

  @tag :durable
  test "freshly generated kill-matrix evidence verifies independently in every mode" do
    assert File.dir?(@matrix), "run make durable-gate first"
    dirs = @matrix |> File.ls!() |> Enum.sort() |> Enum.map(&Path.join(@matrix, &1))
    assert length(dirs) == 18, "expected 3 modes x 6 kill points"

    for dir <- dirs do
      name = Path.basename(dir)
      receipt = dir |> Path.join("receipt.json") |> File.read!() |> JSON.decode!()

      assert {:ok, props} =
               LdHost.RuntimeProfiles.verify_receipt(@wasm, "order.machine.toml", dir, receipt),
             name

      for p <-
            ~w(crash-recovered effects-exactly-once checkpoint-recovered replay-stable fork-diverged) do
        assert MapSet.member?(props, p), "#{name} lacks #{p}"
      end

      oplog = File.read!(Path.join(dir, "oplog.jsonl"))
      marker? = String.contains?(oplog, ~s("kind":"fault-injection"))

      assert marker? == String.starts_with?(name, "abort-"),
             "#{name}: marker presence must follow the mode"

      if String.starts_with?(name, "sigkill-provider-") do
        assert File.read!(Path.join(dir, "provider-calls.jsonl")) =~ ~s("kind":"restart"), name
      end
    end
  end
end
