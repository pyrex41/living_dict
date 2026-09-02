defmodule LdHost.ElaborateTest do
  use ExUnit.Case, async: true

  alias LdHost.{Elaborate, SystemManifest}

  @manifest Path.expand("../../examples/orders/ld-system.json", __DIR__)

  defp manifest, do: @manifest |> File.read!() |> JSON.decode!()

  test "the orders manifest is accepted with a deterministic derivation and named obligations" do
    assert {:ok, d1} = Elaborate.derive_file(@manifest)
    assert {:ok, d2} = Elaborate.derive(manifest())
    assert d1 == d2
    assert d1["verdict"] == "accepted"
    assert d1["failed"] == []
    assert d1["manifest_hash"] =~ ~r/\A[0-9a-f]{64}\z/
    assert d1["derivation_hash"] =~ ~r/\A[0-9a-f]{64}\z/

    ids = Enum.map(d1["obligations"], & &1["id"])
    assert "runtime:effects-exactly-once:charge-card" in ids
    assert "netkat:isolated:api->card-provider" in ids
    assert "tla:delivery-at-least-once:order-commands" in ids
    assert "tla:liveness:accepted-orders-settle" in ids
    assert "runtime:checkpoint-recovered:worker" in ids
    assert "exploration:crash-after-effect:orders" in ids
    assert d1["unresolved"] == ids
  end

  test "moving the payment broker to the experimental profile is rejected on the dimension that fails" do
    m =
      put_in(
        manifest(),
        ["components", "payment", "substrate"],
        "unikraft-confined-transducer-experimental"
      )

    assert {:ok, d} = Elaborate.derive(m)
    assert d["verdict"] == "rejected"
    assert "substrate-satisfies:payment.external_effects" in d["failed"]
    assert "effect-owner:charge-card" in d["failed"]
    assert "substrate-admissible:payment" in d["failed"]
    assert d["obligations"] == []

    step = Enum.find(d["steps"], &(&1["subject"] == "payment.external_effects"))
    assert step["detail"] =~ "durable-intent-commit"
    assert step["detail"] =~ "ambient"
  end

  test "a channel whose port types do not compose is rejected" do
    m =
      put_in(
        manifest(),
        ["components", "worker", "ports", "commands", "type"],
        "something-else/v1"
      )

    assert {:ok, d} = Elaborate.derive(m)
    assert d["verdict"] == "rejected"
    assert d["failed"] == ["channel-endpoints:order-commands"]
  end

  test "an invariant naming an undeclared thing is rejected" do
    m =
      update_in(
        manifest(),
        ["invariants"],
        &[%{"id" => "ghost", "kind" => "safety", "about" => ["nobody"]} | &1]
      )

    assert {:ok, d} = Elaborate.derive(m)
    assert "invariant-scope:ghost" in d["failed"]
  end

  test "structural problems are refused before judgment" do
    m = Map.put(manifest(), "deployment", %{"target" => "fargate"})
    assert {:error, reason} = SystemManifest.validate(m)
    assert reason =~ "deployment is reserved"

    m =
      manifest()
      |> Map.put("failure_model", ["meteor"])
      |> put_in(["channels", "charge-requests", "capacity"], 0)

    assert {:error, reason} = SystemManifest.validate(m)
    assert reason =~ "meteor"
    assert reason =~ "charge-requests: capacity"
  end

  test "the manifest hash is its canonical content address" do
    assert {:ok, m} = SystemManifest.load(@manifest)
    assert SystemManifest.hash(m) == LdHost.JCS.hash!(m)
  end
end
