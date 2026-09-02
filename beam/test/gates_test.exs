defmodule LdHost.GatesTest do
  use ExUnit.Case, async: true

  alias LdHost.{Gates, Host}

  defp workspace do
    tmp =
      System.tmp_dir!()
      |> Path.join("ldgates-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    tmp
  end

  defp host(ws, opts \\ []), do: Host.new(ws, Keyword.merge([emit: fn _, _ -> :ok end], opts))

  test "runtime claims require approved authority and profiles are literal" do
    ws = workspace()

    File.write!(
      Path.join(ws, "claims.json"),
      JSON.encode!(%{
        claims: [
          %{
            id: "durable",
            kind: "runtime",
            profile: "wasm-durable-v1",
            config: "machine.toml",
            must: ["replay-stable"]
          }
        ]
      })
    )

    report = Gates.run(host(ws), persist?: false)
    assert [%{kind: "runtime", passed: false, reason: reason}] = report.claims
    assert reason =~ "approved or hidden"

    claim =
      Gates.atomize_claim(%{
        id: "bad",
        kind: "runtime",
        profile: "../../evil",
        config: "machine.toml"
      })

    approved = Gates.run(host(ws, contract: %{claims: [claim]}), persist?: false)
    assert [%{passed: false, reason: "unknown runtime profile: ../../evil"}] = approved.claims
  end

  test "runtime claims are matched against the substrate's capability vector before dispatch" do
    ws = workspace()

    unmet =
      Gates.atomize_claim(%{
        id: "needs-global",
        kind: "runtime",
        profile: "wasm-durable-v1",
        config: "machine.toml",
        requires: %{"global_checkpoint" => "supported", "clock" => "logical"}
      })

    report = Gates.run(host(ws, contract: %{claims: [unmet]}), persist?: false)
    assert [%{passed: false, reason: reason}] = report.claims
    assert reason =~ "does not satisfy requires"
    assert reason =~ "global_checkpoint"
    refute reason =~ "clock needs"

    experimental =
      Gates.atomize_claim(%{
        id: "uk",
        kind: "runtime",
        profile: "unikraft-confined-transducer-experimental",
        config: "machine.toml"
      })

    report = Gates.run(host(ws, contract: %{claims: [experimental]}), persist?: false)
    assert [%{passed: false, reason: reason}] = report.claims
    assert reason =~ "experimental and cannot back a claim"
  end

  @wasm Path.expand("../../spike/wasm", __DIR__)

  # Requires `make -C spike/wasm build` (cargo + cargo-component). Run with
  # `mix test --include durable` or `make beam-durable-e2e`.
  @tag :durable
  test "an approved wasm-durable-v1 claim runs the executor and passes only on independently verified evidence" do
    assert File.regular?(Path.join(@wasm, "target/release/ld-wasm")), "build spike/wasm first"

    claim =
      Gates.atomize_claim(%{
        id: "durable-order",
        kind: "runtime",
        profile: "wasm-durable-v1",
        config: "order.machine.toml",
        timeout_seconds: 120,
        requires: %{"snapshot" => "whole-machine", "external_effects" => "durable-intent-commit"},
        must:
          ~w(replay-stable checkpoint-recovered fork-diverged effects-exactly-once guest-hash-discriminates)
      })

    report = Gates.run(host(@wasm, contract: %{claims: [claim]}), persist?: false)
    assert report.judge == "approved contract"
    assert [%{id: "durable-order", kind: "runtime", passed: true} = entry] = report.claims
    assert "effects-exactly-once" in entry.verified

    assert entry.receipt["engine"]["config_hash"] in LdHost.RuntimeEvidence.engine_allowlist()[
             "wasm-durable-v1"
           ].config

    assert File.regular?(Path.join(entry.evidence_dir, "provider-calls.jsonl"))

    # Same evidence, revalidated from files alone.
    assert {:ok, props} =
             LdHost.RuntimeProfiles.verify_receipt(
               @wasm,
               "order.machine.toml",
               entry.evidence_dir,
               entry.receipt
             )

    assert MapSet.member?(props, "checkpoint-recovered")

    # A claim demanding a property the evidence cannot establish fails even
    # though the executor reported success.
    greedy = %{claim | id: "durable-greedy", must: ["crash-recovered"]}
    report = Gates.run(host(@wasm, contract: %{claims: [greedy]}), persist?: false)
    assert [%{passed: false, reason: reason}] = report.claims
    assert reason =~ "not independently verified: crash-recovered"
  end

  test "approved contract executes check claims; exit 0 passes" do
    ws = workspace()
    File.write!(Path.join(ws, "hello.txt"), "hi")

    contract = %{
      claims: [
        %{
          "id" => "greets",
          "kind" => "check",
          "command" => "grep -q hi hello.txt",
          "timeout_seconds" => 5
        }
      ],
      source: "hidden"
    }

    report =
      Gates.run(host(ws, contract: %{claims: Enum.map(contract.claims, &Gates.atomize_claim/1)}),
        persist?: false
      )

    assert report.ok == true
    assert report.judge == "approved contract"
    assert [%{id: "greets", passed: true, returncode: 0}] = report.claims
  end

  test "failing check reports id, returncode, and output tail" do
    ws = workspace()

    contract = %{
      claims: [
        Gates.atomize_claim(%{
          "id" => "boom",
          "kind" => "check",
          "command" => "echo nope >&2; exit 3"
        })
      ]
    }

    report = Gates.run(host(ws, contract: contract), persist?: false)

    refute report.ok
    assert report.reason == "failed boom"
    assert [%{returncode: 3, output: output}] = report.claims
    assert output =~ "nope"
  end

  test "check timeout fails and marks timed_out" do
    ws = workspace()

    contract = %{
      claims: [
        Gates.atomize_claim(%{
          "id" => "slow",
          "kind" => "check",
          "command" => "sleep 5",
          "timeout_seconds" => 1
        })
      ]
    }

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
        Gates.atomize_claim(%{
          "id" => "serve",
          "kind" => "check",
          "command" => "exit 0",
          "depends_on" => ["build"]
        })
      ]
    }

    report = Gates.run(host(ws, contract: contract), persist?: false)

    assert [_, %{id: "serve", blocked_by: ["build"], reason: "blocked by failed prerequisite"}] =
             report.claims
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

    assert [%{reason: "check claims execute only under an approved or hidden contract"}] =
             report.claims
  end

  test "advisory mode: model-authored checks execute and carry advisory: true" do
    ws = workspace()
    File.write!(Path.join(ws, "hello.txt"), "hi")

    File.write!(
      Path.join(ws, "claims.json"),
      JSON.encode!(%{
        claims: [%{id: "t", kind: "check", command: "grep -q hi hello.txt", timeout_seconds: 5}]
      })
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
      JSON.encode!(%{
        claims: [%{id: "boom", kind: "check", command: "exit 7", timeout_seconds: 5}]
      })
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

    contract = %{
      claims: [
        Gates.atomize_claim(%{
          "id" => "greets",
          "kind" => "check",
          "command" => "grep -q hi hello.txt"
        })
      ]
    }

    report = Gates.run(host(ws, contract: contract, allow_model_checks: true), persist?: false)

    assert report.judge == "approved contract"
    assert report.ok == true
    assert [claim] = report.claims
    refute Map.has_key?(claim, :advisory)
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
        Gates.atomize_claim(%{
          "id" => "src",
          "kind" => "source",
          "path" => "app.py",
          "any" => ["marker"]
        }),
        Gates.atomize_claim(%{"id" => "exists", "kind" => "file", "path" => "app.py"}),
        Gates.atomize_claim(%{"id" => "gone", "kind" => "absent", "path" => "nope.py"})
      ]
    }

    report = Gates.run(host(ws, contract: contract), persist?: false)
    assert report.ok == true
  end

  test "persist writes .sb/discharge_report.json" do
    ws = workspace()

    contract = %{
      claims: [Gates.atomize_claim(%{"id" => "ok", "kind" => "check", "command" => "true"})]
    }

    Gates.run(host(ws, contract: contract))
    assert File.exists?(Path.join(ws, ".sb/discharge_report.json"))
  end
end
