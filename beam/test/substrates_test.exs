defmodule LdHost.SubstratesTest do
  use ExUnit.Case, async: true

  alias LdHost.Substrates

  test "wasm-durable-v1 satisfies a strict requirement vector" do
    assert :ok =
             Substrates.satisfies(
               %{
                 "clock" => "logical",
                 "entropy" => "seeded-replayable",
                 "snapshot" => "whole-machine",
                 "external-effects" => "durable-intent-commit",
                 "replay" => "cross-process",
                 "fault_controls" => ["crash"]
               },
               "wasm-durable-v1"
             )
  end

  test "weaker requirements are satisfied by stronger guarantees" do
    assert :ok =
             Substrates.satisfies(
               %{snapshot: "component", replay: "in-process"},
               "wasm-durable-v1"
             )
  end

  test "the experimental Unikraft profile fails the durable-effects dimension by name" do
    assert {:error, [{:external_effects, "durable-intent-commit", "ambient"}]} =
             Substrates.satisfies(
               %{"external_effects" => "durable-intent-commit"},
               "unikraft-confined-transducer-experimental"
             )
  end

  test "every unmet dimension is reported, not just the first" do
    assert {:error, unmet} =
             Substrates.satisfies(
               %{global_checkpoint: "supported", snapshot: "whole-machine", clock: "logical"},
               "unikraft-confined-transducer-experimental"
             )

    assert Enum.map(unmet, &elem(&1, 0)) |> Enum.sort() == [:clock, :global_checkpoint, :snapshot]
  end

  test "unknown dimensions and unknown values are unmet, never ignored" do
    assert {:error, [{:unknown, "x", nil}]} =
             Substrates.satisfies(%{"made_up" => "x"}, "wasm-durable-v1")

    assert {:error, [{:clock, "atomic", "logical"}]} =
             Substrates.satisfies(%{clock: "atomic"}, "wasm-durable-v1")
  end

  test "fault controls require a superset" do
    assert {:error, [{:fault_controls, ["crash", "drop"], ["crash"]}]} =
             Substrates.satisfies(%{fault_controls: ["crash", "drop"]}, "wasm-durable-v1")
  end

  test "only claim-capable profiles have an executor" do
    assert {:ok, "spike/wasm/target/release/ld-wasm"} = Substrates.executor("wasm-durable-v1")
    assert {:error, reason} = Substrates.executor("unikraft-confined-transducer-experimental")
    assert reason =~ "experimental"
    assert {:error, "unknown runtime profile: nope"} = Substrates.executor("nope")
  end
end
