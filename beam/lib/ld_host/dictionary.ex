defmodule LdHost.Dictionary do
  @moduledoc """
  Warm dictionary: colon words that persist across runs, contracts
  in-band. Port of `harness/src/livingdict/dictionary.py` with the
  typed-promotion upgrades. Load is load-all. Grant-scoped retrieval
  is not a load path and is not authorization.

  - saved words carry their `( ins -- outs | effects )` group after the
    name; contractless words are never persisted (the caller quarantines)
  - the prelude is ordered by call-graph topological sort
    (definition-before-use — the contract-checking critic walks bodies in
    a single pass), alphabetical among independents; legacy cycles are
    skipped with a warning
  """

  alias LdHost.Forth

  @safe_name ~r/^[A-Z][A-Z0-9-]{0,62}$/
  @reserved ~w(: ; IF ELSE THEN DUP DROP SWAP OVER + - *
               READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES
               RECEIPT USE-ARTIFACT)

  def words_dir(dictionary_dir), do: Path.join(dictionary_dir, "words")

  @doc "Composed prelude source (topologically ordered) and its word names."
  def load_prelude(dictionary_dir) do
    dir = words_dir(dictionary_dir)

    case File.ls(dir) do
      {:error, _} ->
        {"", []}

      {:ok, names} ->
        files = names |> Enum.filter(&String.ends_with?(&1, ".fs")) |> Enum.sort()

        sources =
          Map.new(files, fn file ->
            {Path.basename(file, ".fs"), String.trim(File.read!(Path.join(dir, file)))}
          end)

        ordered = topo_order(sources)
        {ordered |> Enum.map(&Map.fetch!(sources, &1)) |> Enum.join("\n"), ordered}
    end
  end

  # Order words so definitions precede uses. Dependencies = body words
  # that are other saved word names. Cycles cannot be produced by checked
  # promotion; legacy cycles drop out (callers may warn via the returned
  # order missing names).
  defp topo_order(sources) do
    names = Map.keys(sources) |> MapSet.new()

    deps =
      Map.new(sources, fn {name, source} ->
        refs =
          source
          |> tokens_or_empty()
          |> Enum.filter(&(&1.kind == :word))
          |> Enum.map(&String.upcase(&1.value))
          |> Enum.filter(&(&1 != name and MapSet.member?(names, &1)))
          |> Enum.uniq()

        {name, refs}
      end)

    visit_all(Enum.sort(Map.keys(deps)), deps, MapSet.new(), MapSet.new(), [])
    |> Enum.reverse()
  end

  defp visit_all([], _deps, _done, _path, acc), do: acc

  defp visit_all([name | rest], deps, done, path, acc) do
    {done, acc} = visit(name, deps, done, path, acc)
    visit_all(rest, deps, done, path, acc)
  end

  defp visit(name, deps, done, path, acc) do
    cond do
      MapSet.member?(done, name) -> {done, acc}
      MapSet.member?(path, name) -> {done, acc}
      true ->
        {done, acc} =
          Enum.reduce(Enum.sort(deps[name] || []), {done, acc}, fn dep, {d, a} ->
            visit(dep, deps, d, MapSet.put(path, name), a)
          end)

        {MapSet.put(done, name), [name | acc]}
    end
  end

  defp tokens_or_empty(source) do
    Forth.tokenize(source)
  rescue
    _ -> []
  end

  @doc """
  Persist promoted words. Each entry: `{name, body_source, contract}` with
  contract the canonical `( ... )` string. Returns `[{name, sha256}]` for
  words actually written (byte-identical files are skipped, like the
  reference).
  """
  def save_words(dictionary_dir, entries) do
    dir = words_dir(dictionary_dir)
    File.mkdir_p!(dir)

    entries
    |> Enum.filter(fn {name, _body, contract} ->
      Regex.match?(@safe_name, name) and name not in @reserved and contract != nil
    end)
    |> Enum.flat_map(fn {name, body, contract} ->
      source = ": #{name} #{contract} #{body} ;\n"
      path = Path.join(dir, "#{name}.fs")

      case File.read(path) do
        {:ok, existing} when existing == source ->
          []

        _ ->
          File.write!(path, source)
          [{name, LdHost.Policy.sha256_hex(source)}]
      end
    end)
  end

  @doc "Render a colon body's tokens back to source (for persistence)."
  def body_source(tokens) do
    tokens
    |> Enum.map(fn
      %{kind: :string, value: v} -> ~s(S" #{v}")
      %{kind: :number, value: v} -> Integer.to_string(v)
      %{kind: :word, value: v} -> v
    end)
    |> Enum.join(" ")
  end
end
