defmodule LdHost.DemoTest do
  use ExUnit.Case

  alias LdHost.Verdict

  test "verdict math: the preregistered thresholds" do
    cold = [
      %{task: "t1", success: true, tokens: %{input_tokens: 1000, output_tokens: 1000}, policy_violations: 0},
      %{task: "t2", success: true, tokens: %{input_tokens: 1000, output_tokens: 1000}, policy_violations: 0}
    ]

    # warm: same correctness, 50% cheaper -> GO
    warm = [
      %{task: "t1", success: true, tokens: %{input_tokens: 500, output_tokens: 500}, policy_violations: 0},
      %{task: "t2", success: true, tokens: %{input_tokens: 500, output_tokens: 500}, policy_violations: 0}
    ]

    measures = Verdict.measures(cold, warm)
    assert measures.token_reduction_fraction == 0.5
    assert {true, []} = Verdict.warm_run_allowed(measures)

    # negative transfer: cold passed t2, warm failed it -> NO-GO
    warm_bad = List.update_at(warm, 1, &%{&1 | success: false})
    measures = Verdict.measures(cold, warm_bad)
    assert measures.negative_transfer
    {false, reasons} = Verdict.warm_run_allowed(measures)
    assert "negative transfer detected" in reasons

    # cheap but too wrong: 100 -> 0 points
    warm_wrong = Enum.map(warm, &%{&1 | success: false})
    {false, reasons} = Verdict.warm_run_allowed(Verdict.measures(cold, warm_wrong))
    assert "correctness loss exceeds threshold" in reasons
    assert "negative transfer detected" in reasons

    # not cheap enough: 10% reduction < 25% threshold
    warm_pricey = Enum.map(cold, &%{&1 | tokens: %{input_tokens: 900, output_tokens: 900}})
    {false, reasons} = Verdict.warm_run_allowed(Verdict.measures(cold, warm_pricey))
    assert reasons == ["cost reduction is below threshold"]
  end

  @tag :e2e
  test "demo end-to-end on config-01 with canned arms (no model)" do
    # The full demo needs planner credentials + grok; covered manually.
    # This test exercises task loading + hidden-verifier scoring on the
    # oracle solution instead.
    repo = LdHost.Critic.repo_root()
    task_dir = Path.join([repo, "eval", "tasks", "config-01"])
    ws = System.tmp_dir!() |> Path.join("lddemo-#{System.unique_integer([:positive])}")
    File.cp_r!(Path.join(task_dir, "repo"), ws)

    oracle = Path.join([task_dir, "protected", "oracle", "files"])

    if File.dir?(oracle) do
      File.cp_r!(oracle, ws)
    end

    verify = Path.join([task_dir, "protected", "verify.py"])

    check =
      ~s{out=$(python3 "#{verify}" "$PWD") && echo "$out" | grep -q '"checks"' && } <>
        ~s{! echo "$out" | grep -q '"passed": false'}

    result = LdHost.Cmd.sh(check, ws, 60_000)
    assert result.returncode == 0, "oracle solution must pass its own hidden verifier: #{result.output}"
  end
end
