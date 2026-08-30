defmodule LdHost.Retrieve do
  @moduledoc """
  Exp 0 grant+path retrieval. Host query only: effects ⊆ grant, path_region
  intersects grant globs, path_region does not intersect forbidden globs.

  No family attribute, no phantom ins/outs, no counterexamples. Index is
  `:word/effects` + `:word/region` from ledger facts plus the identity
  blob / on-disk sidecars — never `task_families`.
  """

  alias LdHost.{Dictionary, Policy, Store}

  @doc """
  Loader mode. Default `load-all` (today's prelude). `retrieved` subsets
  by `host_query/3`. `frozen-hash` is not an Exp 0 arm and falls back.
  """
  def mode(opts \\ []) do
    raw = Keyword.get(opts, :dict_mode) || System.get_env("LD_DICT_MODE") || "load-all"

    case raw |> to_string() |> String.downcase() |> String.trim() do
      "retrieved" -> :retrieved
      _ -> :load_all
    end
  end

  @doc """
  Host query object. `path_region` on the query is the grant write globs.
  Live jobs do not attach a family scope.
  """
  def host_query(effects, grant_globs, forbidden_globs) do
    globs = grant_globs |> List.wrap() |> Enum.map(&to_string/1)

    %{
      "grant_effects" => effects |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort(),
      "grant_globs" => globs,
      "forbidden_globs" => forbidden_globs |> List.wrap() |> Enum.map(&to_string/1),
      "path_region" => globs
    }
  end

  @doc "Load-all arm sentinel for `dictionary.retrieve` (Python `query: \"*\"`)."
  def load_all_query, do: "*"

  @doc """
  Merge index sources. Later maps win per name. Facts, then dir sidecars,
  then interned identity blob.
  """
  def index(opts \\ []) when is_list(opts) do
    from_facts = index_from_facts(Keyword.get(opts, :facts) || [])
    from_dir = index_from_dir(Keyword.get(opts, :dictionary_dir))
    from_blob = index_from_identity(Keyword.get(opts, :identity) || %{})
    merge([from_facts, from_dir, from_blob])
  end

  def index_from_facts(facts) when is_list(facts) do
    Enum.reduce(facts, %{}, fn row, acc ->
      case row do
        {e, a, v, _tx} -> put_fact(acc, e, a, v)
        _ -> acc
      end
    end)
  end

  def index_from_facts(_), do: %{}

  @doc "Index `:word/effects` and `:word/region` from interned `D_identity`."
  def index_from_identity(blob) when is_map(blob) do
    words =
      cond do
        is_map(blob["words"]) -> blob["words"]
        is_map(Map.get(blob, :words)) -> Map.get(blob, :words)
        true -> blob
      end

    Enum.reduce(words, %{}, fn {name, entry}, acc ->
      if word_entry?(entry) do
        Map.put(acc, to_string(name), entry_index(entry))
      else
        acc
      end
    end)
  end

  def index_from_identity(blob) when is_binary(blob) do
    case JSON.decode(blob) do
      {:ok, map} -> index_from_identity(map)
      _ -> %{}
    end
  end

  def index_from_identity(_), do: %{}

  @doc "Sidecar identity on disk (`effects`, `path_region`). Not family."
  def index_from_dir(nil), do: %{}

  def index_from_dir(dictionary_dir) do
    dir = Dictionary.words_dir(dictionary_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".identity.json"))
        |> Enum.reduce(%{}, fn file, acc ->
          name = String.replace_suffix(file, ".identity.json", "")

          case Dictionary.load_identity(dictionary_dir, name) do
            %{} = identity -> Map.put(acc, name, entry_index(identity))
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  def merge(maps) when is_list(maps) do
    Enum.reduce(maps, %{}, &Map.merge(&2, &1))
  end

  @doc "Sorted names whose identity matches the host query."
  def candidates(index, query) when is_map(index) do
    index
    |> Enum.filter(fn {_name, entry} -> eligible?(entry, query) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  def candidates(_, _), do: []

  @doc false
  def eligible?(_entry, "*"), do: true

  def eligible?(entry, query) when is_map(entry) and is_map(query) do
    effects = list_field(entry, "effects")
    region = list_field(entry, "path_region")
    grant_effects = list_field(query, "grant_effects")
    grant_globs = list_field(query, "grant_globs")
    grant = if grant_globs == [], do: list_field(query, "path_region"), else: grant_globs
    forbidden = list_field(query, "forbidden_globs")

    effects_subset?(effects, grant_effects) and
      glob_lists_overlap?(region, grant) and
      not glob_lists_overlap?(region, forbidden)
  end

  def eligible?(_, _), do: false

  defp put_fact(acc, "word/" <> name, ":word/effects", v) when name != "" do
    update_entry(acc, name, "effects", split_csv(v))
  end

  defp put_fact(acc, "word/" <> name, ":word/region", v) when name != "" do
    update_entry(acc, name, "path_region", split_csv(v))
  end

  defp put_fact(acc, _, _, _), do: acc

  defp update_entry(acc, name, key, value) do
    current = Map.get(acc, name, %{"effects" => [], "path_region" => []})
    Map.put(acc, name, Map.put(current, key, value))
  end

  defp word_entry?(entry) when is_map(entry) do
    Map.has_key?(entry, "effects") or Map.has_key?(entry, "path_region") or
      Map.has_key?(entry, "source") or Map.has_key?(entry, :effects) or
      Map.has_key?(entry, :path_region) or Map.has_key?(entry, :source)
  end

  defp word_entry?(_), do: false

  defp entry_index(entry) when is_map(entry) do
    %{
      "effects" => list_field(entry, "effects"),
      "path_region" => list_field(entry, "path_region")
    }
  end

  defp list_field(map, key) when is_map(map) and is_binary(key) do
    value =
      case Map.fetch(map, key) do
        {:ok, v} ->
          v

        :error ->
          atom =
            try do
              String.to_existing_atom(key)
            rescue
              ArgumentError -> nil
            end

          if atom, do: Map.get(map, atom, []), else: []
      end

    cond do
      is_list(value) -> Enum.map(value, &to_string/1)
      is_binary(value) -> split_csv(value)
      true -> []
    end
  end

  defp split_csv(nil), do: []
  defp split_csv(""), do: []

  defp split_csv(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_csv(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp split_csv(other), do: [to_string(other)]

  defp effects_subset?(effects, grant) do
    grant_set = MapSet.new(grant)
    Enum.all?(effects, &MapSet.member?(grant_set, &1))
  end

  defp glob_lists_overlap?([], _), do: false
  defp glob_lists_overlap?(_, []), do: false

  defp glob_lists_overlap?(left, right) do
    Enum.any?(left, fn a -> Enum.any?(right, &glob_overlap?(a, &1)) end)
  end

  defp glob_overlap?(a, b), do: Policy.glob_match?(a, b) or Policy.glob_match?(b, a)

  @doc "Facts rows from a run's `events.jsonl`, if present."
  def facts_from_dir(run_dir) when is_binary(run_dir) do
    path = Path.join(run_dir, "events.jsonl")

    events =
      case File.read(path) do
        {:ok, bin} ->
          bin
          |> String.split("\n", trim: true)
          |> Enum.map(&JSON.decode!/1)

        _ ->
          []
      end

    Store.facts(events)
  end

  def facts_from_dir(_), do: []
end
