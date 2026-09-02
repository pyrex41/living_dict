defmodule LdHost.ElaborateShenTest do
  @moduledoc """
  Conformance: the Elixir elaborator and the typed Shen elaborator
  (`shen/critic/elaborate.shen`, shaken to `browser/dist/elaborate/app.js` by
  `make elaborate-js-nix`) must agree on verdict, every step, every failed
  judgment, and every obligation id. Run with `mix test --include shen`.
  """
  use ExUnit.Case, async: true

  alias LdHost.Elaborate

  @manifest Path.expand("../../examples/orders/ld-system.json", __DIR__)
  @artifact Path.expand("../../browser/dist/elaborate/app.js", __DIR__)
  @server Path.expand("../priv/elaborate_server.mjs", __DIR__)

  defp manifest, do: @manifest |> File.read!() |> JSON.decode!()

  defp shen(m) do
    {:ok, validated} = LdHost.SystemManifest.validate(m)
    request = JSON.encode!(Elaborate.shen_request(validated))
    tmp = Path.join(System.tmp_dir!(), "ld-elab-#{System.unique_integer([:positive])}.json")
    File.write!(tmp, request)
    {out, 0} = System.cmd("sh", ["-c", "node #{@server} #{@artifact} < #{tmp}"])
    File.rm(tmp)
    JSON.decode!(out)
  end

  defp elixir(m) do
    {:ok, d} = Elaborate.derive(m)

    %{
      "verdict" => d["verdict"],
      "steps" => Enum.map(d["steps"], &[&1["rule"], &1["subject"], &1["ok"], &1["detail"]]),
      "failed" => d["failed"],
      "obligations" => Enum.map(d["obligations"], & &1["id"])
    }
  end

  @tag :shen
  test "Elixir and Shen elaborators agree step for step" do
    assert File.regular?(@artifact), "run make elaborate-js-nix first"

    cases = [
      {"orders accepted", manifest()},
      {"payment on experimental",
       put_in(
         manifest(),
         ["components", "payment", "substrate"],
         "unikraft-confined-transducer-experimental"
       )},
      {"channel type mismatch",
       put_in(
         manifest(),
         ["components", "worker", "ports", "commands", "type"],
         "something-else/v1"
       )},
      {"unknown invariant name",
       update_in(
         manifest(),
         ["invariants"],
         &[%{"id" => "ghost", "kind" => "safety", "about" => ["nobody"]} | &1]
       )},
      {"unknown substrate and unmet dimensions",
       manifest()
       |> put_in(["components", "api", "substrate"], "nowhere-v9")
       |> put_in(["components", "worker", "requires"], %{
         "global_checkpoint" => "supported",
         "made_up" => "x",
         "fault_controls" => ["crash", "drop"]
       })}
    ]

    for {label, m} <- cases do
      assert elixir(m) == shen(m), label
    end
  end
end
