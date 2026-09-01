defmodule LdHost.Verdict do
  @moduledoc """
  The preregistered warm-dictionary go/no-go — a direct port of
  `harness/src/livingdict/promotion.py::warm_run_allowed` (frozen
  reference). The thresholds were registered before any arm ran:
  ≤5 points correctness loss, ≥25% token cost reduction, no new policy
  violations, no negative transfer.
  """

  @max_correctness_loss_points 5.0
  @min_cost_reduction_fraction 0.25

  def warm_run_allowed(measures) do
    reasons =
      []
      |> maybe(
        measures.success_delta_points < -@max_correctness_loss_points,
        "correctness loss exceeds threshold"
      )
      |> maybe(
        measures.token_reduction_fraction < @min_cost_reduction_fraction,
        "cost reduction is below threshold"
      )
      |> maybe(measures.policy_violations_increased, "policy violations increased")
      |> maybe(measures.negative_transfer, "negative transfer detected")

    {reasons == [], reasons}
  end

  defp maybe(reasons, true, reason), do: reasons ++ [reason]
  defp maybe(reasons, false, _reason), do: reasons

  @doc "Compute the four measures from per-task cold/warm results."
  def measures(cold_results, warm_results) do
    cold_by_task = Map.new(cold_results, &{&1.task, &1})
    warm_by_task = Map.new(warm_results, &{&1.task, &1})

    points = fn results ->
      if results == [], do: 0.0, else: 100.0 * Enum.count(results, & &1.success) / length(results)
    end

    tokens = fn results ->
      Enum.reduce(results, 0, fn r, acc ->
        acc + Map.get(r.tokens, :total_tokens, r.tokens.input_tokens + r.tokens.output_tokens)
      end)
    end

    cold_tokens = tokens.(cold_results)
    warm_tokens = tokens.(warm_results)

    %{
      success_delta_points: points.(warm_results) - points.(cold_results),
      token_reduction_fraction:
        if(cold_tokens > 0, do: 1.0 - warm_tokens / cold_tokens, else: 0.0),
      policy_violations_increased:
        Enum.sum(Enum.map(warm_results, & &1.policy_violations)) >
          Enum.sum(Enum.map(cold_results, & &1.policy_violations)),
      negative_transfer:
        Enum.any?(Map.keys(cold_by_task), fn task ->
          cold = cold_by_task[task]
          warm = warm_by_task[task]
          cold.success and warm != nil and not warm.success
        end)
    }
  end
end
