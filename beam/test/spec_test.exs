defmodule LdHost.SpecTest do
  use ExUnit.Case

  alias LdHost.{Critic, Dispatcher, Gates, Ledger, Run, Space, Spec}

  @fixture_claim %{
    "id" => "greets",
    "kind" => "check",
    "command" => "grep -q hello greet.txt",
    "path" => ""
  }

  defp workspace do
    tmp =
      System.tmp_dir!()
      |> Path.join("ldspec-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    tmp
  end

  defp greet_planner do
    envelope = %{
      "language" => "forth",
      "program" =>
        ~s{: INSTALL ( key path -- | read, write ) SWAP USE-ARTIFACT SWAP WRITE-FILE DROP ; } <>
          ~s{S" greet.txt" S" greet.txt" INSTALL RUN-GATES DROP RECEIPT DROP},
      "artifacts" => %{"greet.txt" => "hello from the spec\n"},
      "rationale" => "install greeting"
    }

    fn _goal, _obs, _feedback -> {:ok, envelope, %{input_tokens: 1, output_tokens: 1}} end
  end

  test "yggdrasil-checked product spec compiles to claims whose atomize_claim/1 matches a fixture" do
    yggdrasil_check!()
    compiled = Spec.compile(:fixture)

    assert Enum.map(compiled.claims, &Gates.atomize_claim/1) == [Gates.atomize_claim(@fixture_claim)]
    assert compiled.globs == ["greet.txt"]
    assert compiled.effects == ["read", "write", "exec"]
    assert compiled.obligation_kinds == ["obligation"]
    assert compiled.source == "unsigned"

    round_trip =
      Spec.compile(%{
        claims: compiled.claims,
        globs: compiled.globs,
        effects: compiled.effects,
        obligation_kinds: compiled.obligation_kinds
      })

    assert Enum.map(round_trip.claims, &Gates.atomize_claim/1) == [Gates.atomize_claim(@fixture_claim)]
  end

  test "Run without Spec.sign still refuses check claims" do
    compiled = Spec.compile(:fixture)
    ws = workspace()

    File.write!(
      Path.join(ws, "claims.json"),
      JSON.encode!(%{claims: compiled.claims})
    )

    planner = fn _g, _o, _f ->
      {:ok,
       %{
         "language" => "forth",
         "program" => "RUN-GATES DROP RECEIPT DROP",
         "artifacts" => %{},
         "rationale" => "measure unsigned claims"
       }, %{}}
    end

    result = Run.run("goal", workspace: ws, planner_fn: planner, max_episodes: 1)

    assert [%{reason: "check claims execute only under an approved or hidden contract"}] = result.report.claims

    unsigned = Run.run("goal", workspace: workspace(), contract: compiled, planner_fn: greet_planner(), max_episodes: 1)

    assert [%{reason: "check claims execute only under an approved or hidden contract"}] = unsigned.report.claims
    refute unsigned.success
  end

  test "after sign, judge is spec-derived and critic rejects writes outside compiled globs" do
    compiled = Spec.compile(:fixture)
    ws = workspace()
    {:ok, ledger} = Ledger.start_link(Path.join(ws, "sign-ledger"))
    contract = Spec.sign(compiled, ledger)

    events =
      ws
      |> Path.join("sign-ledger/events.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(events, &(&1["kind"] == "contract.approved" and &1["payload"]["source"] == "spec-derived"))

    result =
      Run.run("write a greeting file",
        workspace: ws,
        contract: contract,
        planner_fn: greet_planner(),
        max_episodes: 2
      )

    assert result.success
    assert result.judge == "spec-derived"

    program = ~s{S" secret.txt" USE-ARTIFACT S" secret.txt" WRITE-FILE DROP RECEIPT DROP}

    assert {:reject, errors, _depth, _effects} =
             Critic.validate(program, compiled.effects, compiled.globs, [], ["secret.txt"])

    assert Enum.any?(errors, &(&1 =~ "path outside allowed change set: secret.txt"))
  end

  test "Space.out of a kind not in compiled obligation_kinds errors unknown tuple kind" do
    compiled = Spec.compile(:fixture)
    {:ok, space} = Space.start_link(allowed_kinds: compiled.obligation_kinds)

    assert {:ok, _} = Space.out(space, %{"kind" => "obligation", "id" => "ob-1"})
    assert {:error, reason} = Space.out(space, %{"kind" => "node.ready", "node" => "a"})
    assert reason =~ "unknown tuple kind"

    ob = %{"kind" => "node.ready", "goal" => "g", "workspace" => workspace()}
    assert Dispatcher.deny_reason(ob, compiled.obligation_kinds) =~ "unknown tuple kind"
    assert Dispatcher.deny_reason(%{"kind" => "obligation", "goal" => "g", "workspace" => workspace()}) == nil
  end

  test "compile_file reads claims JSON (same dialect as load_contract) and sign is required" do
    compiled = Spec.compile(:fixture)
    path = Path.join(workspace(), "spec.json")

    File.write!(
      path,
      JSON.encode!(%{
        claims: compiled.claims,
        globs: compiled.globs,
        effects: compiled.effects,
        obligation_kinds: compiled.obligation_kinds
      })
    )

    from_file = Spec.compile_file(path)
    assert Enum.map(from_file.claims, &Gates.atomize_claim/1) == Enum.map(compiled.claims, &Gates.atomize_claim/1)
    assert from_file.source == "unsigned"
    assert Spec.sign(from_file, nil).source == "spec-derived"
  end

  defp yggdrasil_check! do
    ygg = System.find_executable("yggdrasil") || Path.expand("~/go/bin/yggdrasil")
    assert File.regular?(ygg), "yggdrasil not found"

    host = shen_host()
    args = ["check", Spec.source_file()] ++ if(host, do: ["--host", host], else: [])
    {output, status} = System.cmd(ygg, args, stderr_to_stdout: true)
    assert status == 0, output
  end

  defp shen_host do
    script = Path.join([Spec.repo_root(), "..", "ShenScript", "bin", "shen.js"])
    if File.regular?(script), do: "node #{script}"
  end
end
