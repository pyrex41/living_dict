defmodule LdHost.Dictionary do
  @moduledoc """
  Warm dictionary: colon words that persist across runs, contracts
  in-band. Port of `harness/src/livingdict/dictionary.py` with the
  typed-promotion upgrades:

  - saved words carry their `( ins -- outs | effects )` group after the
    name; contractless words are never persisted (the caller quarantines)
  - the prelude is ordered by call-graph topological sort
    (definition-before-use — the contract-checking critic walks bodies in
    a single pass), alphabetical among independents; legacy cycles are
    skipped with a warning
  """

  alias LdHost.{Contracts, Forth}

  @safe_name ~r/^[A-Z][A-Z0-9-]{0,62}$/
  @reserved ~w(: ; IF ELSE THEN DUP DROP SWAP OVER + - *
               READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES
               RECEIPT USE-ARTIFACT)

  def words_dir(dictionary_dir), do: Path.join(dictionary_dir, "words")

  @doc "Composed prelude source (topologically ordered) and its word names."
  def load_prelude(dictionary_dir) do
    sources = load_aligned_sources(dictionary_dir)
    ordered = topo_order(sources)
    {ordered |> Enum.map(&Map.fetch!(sources, &1)) |> Enum.join("\n"), ordered}
  end

  @doc """
  Persisted colon rows `{name, tokens, {ins, outs, effects}, source}` in
  def-before-use order. Bodies are the file's tokens, never invented stubs.
  """
  def load_vocab(dictionary_dir) do
    sources = load_aligned_sources(dictionary_dir)

    sources
    |> topo_order()
    |> Enum.flat_map(fn name ->
      source = Map.fetch!(sources, name)

      case colon_body(source, name) do
        {:ok, tokens} ->
          [{name, tokens, contract_sig(source, name), source}]

        :error ->
          []
      end
    end)
  end

  @install_covering_error "catalog has INSTALL; use it instead of WRITE-FILE"

  @doc """
  Reject WRITE-FILE / the USE-ARTIFACT+WRITE-FILE zipper when INSTALL is
  already in the catalog. Tokenizes envelope.program only so a carried
  INSTALL.fs body cannot false-trigger itself.
  """
  def catalog_pressure(prelude_words, envelope) when is_list(prelude_words) do
    names = MapSet.new(Enum.map(prelude_words, &String.upcase/1))

    if not MapSet.member?(names, "INSTALL") do
      :ok
    else
      artifacts = envelope_artifacts(envelope)
      words = program_words(envelope)

      cond do
        # Read-only empty-artifact episodes have nothing INSTALL could cover.
        artifacts == %{} and "WRITE-FILE" not in words ->
          :ok

        "INSTALL" in words ->
          :ok

        "WRITE-FILE" in words or zipper?(words) ->
          {:error, @install_covering_error}

        true ->
          :ok
      end
    end
  end

  defp envelope_artifacts(%{artifacts: arts}) when is_map(arts), do: arts
  defp envelope_artifacts(_), do: %{}

  defp program_words(%{program: source}) when is_binary(source) do
    source
    |> Forth.tokenize()
    |> skip_colon_bodies()
    |> Enum.filter(&(&1.kind == :word))
    |> Enum.map(&String.upcase(&1.value))
  rescue
    _ -> []
  end

  defp program_words(_), do: []

  defp zipper?(words), do: "USE-ARTIFACT" in words and "WRITE-FILE" in words

  # Covering judges calls, not tokens inside a definition the program is introducing.
  defp skip_colon_bodies(tokens) do
    {kept, _} =
      Enum.reduce(tokens, {[], :top}, fn token, {acc, mode} ->
        case {mode, token} do
          {:top, %{kind: :word, value: value}} ->
            if String.upcase(value) == ":" do
              {acc, :colon}
            else
              {[token | acc], :top}
            end

          {:colon, %{kind: :word, value: value}} ->
            if String.upcase(value) == ";" do
              {acc, :top}
            else
              {acc, :colon}
            end

          {:colon, _} ->
            {acc, :colon}

          {:top, token} ->
            {[token | acc], :top}
        end
      end)

    Enum.reverse(kept)
  end

  @doc "True when the colon body is stack sugar plus exactly one host primitive."
  def tautology?(tokens) when is_list(tokens) do
    if Enum.any?(tokens, &(&1.kind != :word)) do
      false
    else
      sugar = ~w(DUP DROP SWAP OVER)
      hosts = MapSet.new(Forth.host_words())

      words = Enum.map(tokens, &String.upcase(&1.value))
      {host_hits, rest} = Enum.split_with(words, &MapSet.member?(hosts, &1))

      length(host_hits) == 1 and Enum.all?(rest, &(&1 in sugar))
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

  defp load_word_sources(dictionary_dir) do
    dir = words_dir(dictionary_dir)

    case File.ls(dir) do
      {:error, _} ->
        %{}

      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".fs"))
        |> Enum.filter(fn file ->
          Regex.match?(@safe_name, Path.basename(file, ".fs"))
        end)
        |> Enum.sort()
        |> Enum.reduce(%{}, fn file, acc ->
          path = Path.join(dir, file)
          name = Path.basename(file, ".fs")

          case File.read(path) do
            {:ok, bin} when is_binary(bin) ->
              if String.valid?(bin) do
                Map.put(acc, name, String.trim(bin))
              else
                acc
              end

            _ ->
              acc
          end
        end)
    end
  end

  # Filename stem and colon name must be the same identity or the critic
  # (prelude source) and Forth (vocab bind) would define different words.
  defp load_aligned_sources(dictionary_dir) do
    Enum.reduce(load_word_sources(dictionary_dir), %{}, fn {name, source}, acc ->
      case colon_body(source, name) do
        {:ok, _} -> Map.put(acc, name, source)
        :error -> acc
      end
    end)
  end

  defp colon_body(source, expected_name) do
    tokens = Forth.tokenize(source)

    case tokens do
      [%{kind: :word, value: colon}, %{kind: :word, value: name} | rest] ->
        if String.upcase(colon) == ":" and String.upcase(name) == expected_name do
          take_colon_body(rest, [])
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp take_colon_body([], _acc), do: :error

  defp take_colon_body([%{kind: :word, value: value} = token | rest], acc) do
    case String.upcase(value) do
      ";" -> {:ok, Enum.reverse(acc)}
      ":" -> :error
      _ -> take_colon_body(rest, [token | acc])
    end
  end

  defp take_colon_body([token | rest], acc), do: take_colon_body(rest, [token | acc])

  defp contract_sig(source, name) do
    case Map.get(Contracts.extract(source), name) do
      nil ->
        {[], [], []}

      inner ->
        words =
          inner
          |> String.replace(",", " ")
          |> String.split(~r/\s+/, trim: true)

        case Enum.split_while(words, &(&1 != "--")) do
          {ins, ["--" | rest]} ->
            {outs, effects} =
              case Enum.split_while(rest, &(&1 != "|")) do
                {outs, ["|" | effects]} -> {outs, effects}
                {outs, []} -> {outs, []}
              end

            {ins, outs, effects}

          _ ->
            {[], [], []}
        end
    end
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
