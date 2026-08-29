defmodule LdHost.GatesTest do
  use ExUnit.Case, async: true

  alias LdHost.{Gates, Host}

  defp workspace do
    tmp = System.tmp_dir!() |> Path.join("ldgates-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmp
  end

  defp host(ws, opts \\ []), do: Host.new(ws, Keyword.merge([emit: fn _, _ -> :ok end], opts))

  test "approved contract executes check claims; exit 0 passes" do
    ws = workspace()
    File.write!(Path.join(ws, "hello.txt"), "hi")

    contract = %{claims: [%{"id" => "greets", "kind" => "check", "command" => "grep -q hi hello.txt", "timeout_seconds" => 5}], source: "hidden"}
    report = Gates.run(host(ws, contract: %{claims: Enum.map(contract.claims, &Gates.atomize_claim/1)}), persist?: false)

    assert report.ok == true
    assert report.judge == "approved contract"
    assert [%{id: "greets", passed: true, returncode: 0}] = report.claims
  end

  test "failing check reports id, returncode, and output tail" do
    ws = workspace()

    contract = %{claims: [Gates.atomize_claim(%{"id" => "boom", "kind" => "check", "command" => "echo nope >&2; exit 3"})]}
    report = Gates.run(host(ws, contract: contract), persist?: false)

    refute report.ok
    assert report.reason == "failed boom"
    assert [%{returncode: 3, output: output}] = report.claims
    assert output =~ "nope"
  end

  test "check timeout fails and marks timed_out" do
    ws = workspace()
    contract = %{claims: [Gates.atomize_claim(%{"id" => "slow", "kind" => "check", "command" => "sleep 5", "timeout_seconds" => 1})]}
    report = Gates.run(host(ws, contract: contract), persist?: false)

    refute report.ok
    assert [%{timed_out: true}] = report.claims
    assert report.timed_out
  end

  test "depends_on blocks downstream checks" do
    ws = workspace()

    contract = %{
      claims: [
        Gates.atomize_claim(%{"id" => "build", "kind" => "check", "command" => "exit 1"}),
        Gates.atomize_claim(%{"id" => "serve", "kind" => "check", "command" => "exit 0", "depends_on" => ["build"]})
      ]
    }

    report = Gates.run(host(ws, contract: contract), persist?: false)
    assert [_, %{id: "serve", blocked_by: ["build"], reason: "blocked by failed prerequisite"}] = report.claims
  end

  test "model-authored claims: checks refused, judge labeled" do
    ws = workspace()

    File.write!(
      Path.join(ws, "claims.json"),
      JSON.encode!(%{claims: [%{id: "t", kind: "check", command: "exit 0"}]})
    )

    report = Gates.run(host(ws), persist?: false)
    assert report.judge == "model-authored claims"
    refute report.ok
    assert [%{reason: "check claims execute only under an approved or hidden contract"}] = report.claims
  end

  test "advisory mode: model-authored checks execute and carry advisory: true" do
    ws = workspace()
    File.write!(Path.join(ws, "hello.txt"), "hi")

    File.write!(
      Path.join(ws, "claims.json"),
      JSON.encode!(%{claims: [%{id: "t", kind: "check", command: "grep -q hi hello.txt", timeout_seconds: 5}]})
    )

    report = Gates.run(host(ws, allow_model_checks: true), persist?: false)

    assert report.judge == "model-authored claims"
    assert report.ok == true
    assert [%{id: "t", passed: true, returncode: 0, advisory: true}] = report.claims
  end

  test "advisory mode: failing check counts against report.ok" do
    ws = workspace()

    File.write!(
      Path.join(ws, "claims.json"),
      JSON.encode!(%{claims: [%{id: "boom", kind: "check", command: "exit 7", timeout_seconds: 5}]})
    )

    report = Gates.run(host(ws, allow_model_checks: true), persist?: false)

    assert report.judge == "model-authored claims"
    refute report.ok
    assert report.reason == "failed boom"
    assert [%{id: "boom", passed: false, returncode: 7, advisory: true}] = report.claims
  end

  test "advisory mode: approved contract still wins, no advisory flag" do
    ws = workspace()
    File.write!(Path.join(ws, "hello.txt"), "hi")

    contract = %{claims: [Gates.atomize_claim(%{"id" => "greets", "kind" => "check", "command" => "grep -q hi hello.txt"})]}
    report = Gates.run(host(ws, contract: contract, allow_model_checks: true), persist?: false)

    assert report.judge == "approved contract"
    assert report.ok == true
    assert [claim] = report.claims
    refute Map.has_key?(claim, :advisory)
  end

  test "unknown contract source does not execute checks" do
    ws = workspace()

    contract = %{
      claims: [Gates.atomize_claim(%{"id" => "t", "kind" => "check", "command" => "exit 0"})],
      source: "spec_derived"
    }

    report = Gates.run(host(ws, contract: contract), persist?: false)
    assert report.judge == "unsigned spec"
    refute report.ok
    assert [%{reason: "check claims execute only under an approved or hidden contract"}] = report.claims
  end

  test "no claims at all fails with reference reason" do
    report = Gates.run(host(workspace()), persist?: false)
    assert report.reason =~ "no claims.json"
  end

  test "source, file, and absent claims" do
    ws = workspace()
    File.write!(Path.join(ws, "app.py"), String.duplicate("x = 1 # marker\n", 20))

    contract = %{
      claims: [
        Gates.atomize_claim(%{"id" => "src", "kind" => "source", "path" => "app.py", "any" => ["marker"]}),
        Gates.atomize_claim(%{"id" => "exists", "kind" => "file", "path" => "app.py"}),
        Gates.atomize_claim(%{"id" => "gone", "kind" => "absent", "path" => "nope.py"})
      ]
    }

    report = Gates.run(host(ws, contract: contract), persist?: false)
    assert report.ok == true
  end

  test "persist writes .sb/discharge_report.json" do
    ws = workspace()
    contract = %{claims: [Gates.atomize_claim(%{"id" => "ok", "kind" => "check", "command" => "true"})]}
    Gates.run(host(ws, contract: contract))
    assert File.exists?(Path.join(ws, ".sb/discharge_report.json"))
  end
end
