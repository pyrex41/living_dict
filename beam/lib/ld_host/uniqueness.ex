defmodule LdHost.Uniqueness do
  @moduledoc """
  Five uniqueness axes. Measurement only: organs exist elsewhere;
  this module names them. Missing evidence is omitted, never zeroed.
  """

  @doc "Score a Demo/Polyglot/canned results map. Derived-only."
  def score(results) when is_map(results) do
    %{}
    |> maybe(:family_transfer, family_transfer(results))
    |> maybe(:contract_first, contract_first(results))
    |> maybe(:replay_without_model, replay_without_model(results))
    |> maybe(:wave_speedup, wave_speedup(results))
    |> maybe(:obligation_hold, obligation_hold(results))
  end

  def family_transfer(%{tasks: tasks} = results) when is_list(tasks) do
    prelude = Map.get(results, :prelude) || Map.get(results, "prelude") || []

    used_all =
      Enum.flat_map(tasks, &List.wrap(&1[:used_words] || &1["used_words"] || []))

    unused_seed =
      prelude != [] and
        MapSet.disjoint?(
          MapSet.new(Enum.map(prelude, &String.upcase/1)),
          MapSet.new(Enum.map(used_all, &String.upcase/1))
        )

    if unused_seed do
      0
    else
      {n, _} =
        Enum.reduce(tasks, {0, MapSet.new()}, fn task, {hits, promoted} ->
          used =
            MapSet.new(
              Enum.map(List.wrap(task[:used_words] || task["used_words"] || []), &String.upcase/1)
            )

          hit = if MapSet.size(MapSet.intersection(used, promoted)) > 0, do: 1, else: 0
          newly = Enum.map(List.wrap(task[:promoted] || task["promoted"] || []), &String.upcase/1)
          {hits + hit, MapSet.union(promoted, MapSet.new(newly))}
        end)

      n
    end
  end

  def family_transfer(_), do: nil

  def contract_first(%{tasks: tasks}) when is_list(tasks) do
    successes = Enum.filter(tasks, &(&1[:success] == true or &1["success"] == true))

    if successes == [] do
      nil
    else
      good =
        Enum.count(successes, fn task ->
          judge = to_string(task[:judge] || task["judge"] || "")
          judge in ["approved contract", "spec-derived"]
        end)

      good / length(successes)
    end
  end

  def contract_first(_), do: nil

  def replay_without_model(%{replay: replay}) when is_map(replay) do
    calls = replay[:model_calls] || replay["model_calls"]
    ok = replay[:success] == true or replay["success"] == true
    if is_integer(calls), do: ok and calls == 0, else: nil
  end

  def replay_without_model(_), do: nil

  def wave_speedup(%{wave: wave}) when is_map(wave) do
    actual = wave[:wall_ms_actual] || wave["wall_ms_actual"]
    serial = wave[:wall_ms_serial_estimate] || wave["wall_ms_serial_estimate"]
    parallel = wave[:nodes_parallel] || wave["nodes_parallel"]

    if is_number(actual) and is_number(serial) and is_number(parallel) do
      actual < serial and parallel >= 2
    end
  end

  def wave_speedup(_), do: nil

  def obligation_hold(%{hold: hold}) when is_map(hold) do
    double_ack = hold[:double_ack] == true or hold["double_ack"] == true
    expired = hold[:expired] == true or hold["expired"] == true
    generation = hold[:generation] || hold["generation"]
    acked = hold[:acked] == true or hold["acked"] == true

    cond do
      double_ack -> false
      is_integer(generation) -> expired and generation >= 2 and acked and not double_ack
      true -> nil
    end
  end

  def obligation_hold(_), do: nil

  defp maybe(map, _key, nil), do: map
  defp maybe(map, key, value), do: Map.put(map, key, value)
end
