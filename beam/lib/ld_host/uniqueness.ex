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
    prelude = names(Map.get(results, :prelude) || Map.get(results, "prelude"))
    used_all = Enum.flat_map(tasks, &names(get(&1, :used_words)))
    promoted_all = Enum.flat_map(tasks, &promoted_names/1)

    unused_seed =
      prelude != [] and MapSet.disjoint?(MapSet.new(prelude), MapSet.new(used_all))

    cond do
      unused_seed ->
        0

      prelude == [] and used_all == [] and promoted_all == [] ->
        nil

      true ->
        {n, _} =
          Enum.reduce(tasks, {0, MapSet.new()}, fn task, {hits, promoted} ->
            used = MapSet.new(names(get(task, :used_words)))
            hit = if MapSet.size(MapSet.intersection(used, promoted)) > 0, do: 1, else: 0
            {hits + hit, MapSet.union(promoted, MapSet.new(promoted_names(task)))}
          end)

        n
    end
  end

  def family_transfer(_), do: nil

  def contract_first(%{tasks: tasks}) when is_list(tasks) do
    judged =
      tasks
      |> Enum.filter(&(&1[:success] == true or &1["success"] == true))
      |> Enum.filter(fn task ->
        case get(task, :judge) do
          judge when is_binary(judge) and judge != "" -> true
          _ -> false
        end
      end)

    if judged == [] do
      nil
    else
      good =
        Enum.count(judged, fn task ->
          get(task, :judge) in ["approved contract", "spec-derived"]
        end)

      good / length(judged)
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

  defp promoted_names(task), do: names(get(task, :promoted) || get(task, :promoted_words))

  defp names(nil), do: []
  defp names(list) when is_list(list), do: Enum.map(list, &(&1 |> to_string() |> String.upcase()))
  defp names(_), do: []

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
