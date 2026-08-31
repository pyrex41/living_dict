defmodule LdHost.Dictionary do
  @moduledoc """
  Warm dictionary: colon words that persist across runs, contracts
  in-band. Port of `harness/src/livingdict/dictionary.py` with the
  typed-promotion upgrades:

  - saved words carry their `( ins -- outs | effects )` group after the
    name; contractless words are never persisted (the caller quarantines)
  - identity sidecar records `effects` (from that contract), `path_region`
    (glob-union of literal WRITE-FILE paths, else the episode grant), and
    empty `task_families` on live jobs
  - the prelude is ordered by call-graph topological sort
    (definition-before-use — the contract-checking critic walks bodies in
    a single pass), alphabetical among independents; legacy cycles are
    skipped with a warning
  - `LD_DICT_MODE=retrieved` subsets that prelude by grant+path (Exp 0);
    default remains load-all
  """

  alias LdHost.{Contracts, Forth, Policy, Store}

  @safe_name ~r/^[A-Z][A-Z0-9-]{0,62}$/
  @reserved ~w(: ; IF ELSE THEN DUP DROP SWAP OVER + - *
               READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES
               RECEIPT USE-ARTIFACT)

  def reserved_names, do: @reserved

  @doc "True when `name` may be persisted as `words/NAME.fs`."
  def safe_name?(name) when is_binary(name) do
    Regex.match?(@safe_name, name) and name not in @reserved
  end

  def safe_name?(_), do: false

  def words_dir(dictionary_dir), do: Path.join(dictionary_dir, "words")

  @doc """
  Composed prelude source (topologically ordered) and its word names.

  `opts[:dict_mode]` / `LD_DICT_MODE` is `load-all` (default, every `*.fs`)
  or `retrieved` (grant+path subset). Retrieved names come from facts +
  identity (`:word/effects`, `:word/region` only), then `topo_order`.
  """
  def load_prelude(dictionary_dir, opts \\ []) do
    sources = load_sources(dictionary_dir)
    selected = select_sources(sources, dictionary_dir, opts)
    ordered = topo_order(selected)
    {ordered |> Enum.map(&Map.fetch!(selected, &1)) |> Enum.join("\n"), ordered}
  end

  defp load_sources(dictionary_dir) do
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

  defp select_sources(sources, dictionary_dir, opts) do
    case LdHost.Retrieve.mode(opts) do
      :load_all ->
        sources

      :retrieved ->
        query = Keyword.get(opts, :query) || default_query(opts)
        index = Keyword.get(opts, :index) || retrieve_index(dictionary_dir, opts)
        Map.take(sources, LdHost.Retrieve.candidates(index, query))
    end
  end

  defp retrieve_index(dictionary_dir, opts) do
    LdHost.Retrieve.index(
      dictionary_dir: dictionary_dir,
      facts: Keyword.get(opts, :facts) || [],
      identity: Keyword.get(opts, :identity) || %{}
    )
  end

  defp default_query(opts) do
    LdHost.Retrieve.host_query(
      Keyword.get(opts, :allowed_effects, ["read", "write", "exec"]),
      Keyword.get(opts, :allowed_globs, ["**"]),
      Keyword.get(opts, :forbidden_globs, [])
    )
  end

  @doc """
  Prelude names mentioned as words in `program` (first-seen order).
  Used for `dictionary.reuse` / unused-loaded-word metrics.
  """
  def used_names(program, names) do
    wanted = MapSet.new(Enum.map(List.wrap(names), &String.upcase(to_string(&1))))

    if MapSet.size(wanted) == 0 do
      []
    else
      {used, _} =
        Enum.reduce(tokens_or_empty(program), {[], MapSet.new()}, fn tok, {acc, seen} ->
          if tok.kind == :word do
            name = String.upcase(tok.value)

            if MapSet.member?(wanted, name) and not MapSet.member?(seen, name) do
              {acc ++ [name], MapSet.put(seen, name)}
            else
              {acc, seen}
            end
          else
            {acc, seen}
          end
        end)

      used
    end
  end

  @doc """
  Order word names so definitions precede uses.

  Dependencies are other saved word names mentioned in a body. Cycles
  cannot be produced by checked promotion; a re-entrant visit is skipped
  (callers may warn via a returned order that omits a name).
  """
  def topo_order(sources) when is_map(sources) do
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
  Identity fields retrieval needs: effects from the in-band contract;
  path_region is the sorted glob-union of literal WRITE-FILE paths in
  `body`, or `allowed_globs` when the body has none. Live jobs persist
  empty family scope.
  """
  def persist_identity(body, contract, allowed_globs \\ ["**"]) do
    %{
      "effects" => LdHost.Contracts.effects(contract),
      "path_region" => path_region(body, allowed_globs),
      "task_families" => []
    }
  end

  @doc """
  Glob-union of literal `WRITE-FILE` paths in a colon body. Immediate
  predecessor must be a string (same rule as Shen `literal-before`).
  No literals → episode `allowed_globs`.
  """
  def path_region(body, allowed_globs \\ ["**"]) do
    case write_file_literals(body) do
      [] -> allowed_globs |> List.wrap() |> Enum.uniq() |> Enum.sort()
      paths -> paths |> Enum.uniq() |> Enum.sort()
    end
  end

  @doc "Identity sidecar written next to `words/NAME.fs`, or nil."
  def load_identity(dictionary_dir, name) do
    path = Path.join(words_dir(dictionary_dir), "#{name}.identity.json")

    case File.read(path) do
      {:ok, bin} -> JSON.decode!(bin)
      _ -> nil
    end
  end

  @doc """
  Persist promoted words. Each entry: `{name, body_source, contract}` with
  contract the canonical `( ... )` string. Returns `[{name, sha256}]` for
  words actually written (byte-identical files are skipped, like the
  reference). Identity sidecars are refreshed even when the `.fs` is
  unchanged. `opts` may include `:allowed_globs` (episode grant).
  """
  def save_words(dictionary_dir, entries, opts \\ []) do
    dir = words_dir(dictionary_dir)
    File.mkdir_p!(dir)
    allowed_globs = Keyword.get(opts, :allowed_globs, ["**"])

    entries
    |> Enum.filter(fn {name, _body, contract} ->
      Regex.match?(@safe_name, name) and name not in @reserved and contract != nil
    end)
    |> Enum.flat_map(fn {name, body, contract} ->
      source = ": #{name} #{contract} #{body} ;\n"
      path = Path.join(dir, "#{name}.fs")
      identity = persist_identity(body, contract, allowed_globs)
      write_identity!(dir, name, identity)

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

  defp write_identity!(dir, name, identity) do
    File.write!(Path.join(dir, "#{name}.identity.json"), JSON.encode!(identity) <> "\n")
  end

  defp write_file_literals(body) when is_binary(body) do
    write_file_literals(tokens_or_empty(body), nil, [])
  end

  defp write_file_literals([], _prev, acc), do: Enum.reverse(acc)

  defp write_file_literals([tok | rest], prev, acc) do
    acc =
      if tok.kind == :word and String.upcase(tok.value) == "WRITE-FILE" and
           match?(%{kind: :string}, prev) do
        [prev.value | acc]
      else
        acc
      end

    write_file_literals(rest, tok, acc)
  end

  @doc "64-char lowercase hex, no `sha256:` prefix. `nil` and empty stay `nil`."
  def digest_hex(nil), do: nil
  def digest_hex(""), do: nil
  def digest_hex("sha256:" <> rest), do: digest_hex(rest)

  def digest_hex(hex) when is_binary(hex) do
    String.downcase(hex)
  end

  def digest_hex(_), do: nil

  @doc "Display form `sha256:<hex>`."
  def hash_display(hex) when is_binary(hex), do: "sha256:" <> digest_hex(hex)

  @doc """
  Word tokens used by a colon body, excluding `:`/`;` and `self`. Sorted unique.
  """
  def callees(body, self \\ nil) do
    body
    |> tokens_or_empty()
    |> Enum.filter(&(&1.kind == :word))
    |> Enum.map(&String.upcase(&1.value))
    |> Enum.reject(&(&1 in [":", ";"] or (self != nil and &1 == self)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Identity-only dictionary object. Evidence (`episode`, `gates`, `cost`,
  `latency_ms`, `tokens`, `replay_ok`, `counterexamples`, `task_families`)
  is never included.
  """
  def identity(parent, primitive_contract, words) when is_map(words) do
    %{
      "parent" => digest_hex(parent),
      "primitive_contract" => digest_hex(primitive_contract),
      "words" =>
        Map.new(words, fn {name, entry} ->
          {to_string(name), word_identity(entry)}
        end)
    }
  end

  @doc "Canonical bytes, 64-hex, and `sha256:<hex>` display form."
  def hash_identity(parent, primitive_contract, words) do
    bytes = identity(parent, primitive_contract, words) |> Store.canonical_json()
    hex = Policy.sha256_hex(bytes)
    {bytes, hex, hash_display(hex)}
  end

  @doc "Intern `D_identity` as a Layer A blob. Same admitted source → same `D*`."
  def intern_identity(store, parent, primitive_contract, words) do
    {bytes, hex, display} = hash_identity(parent, primitive_contract, words)
    stored = Store.intern(store, bytes)
    {stored, display, hex}
  end

  @doc """
  Intern the on-disk prelude as `D_identity`. Words without a contract or
  identity sidecar are omitted (legacy quarantine). `opts[:parent]` is
  the previous `hash(D)` hex or nil.
  """
  def intern_from_dir(store, dictionary_dir, opts \\ []) do
    parent = Keyword.get(opts, :parent)
    primitive = Keyword.get(opts, :primitive_contract, Forth.primitive_contract())
    words = words_identity(store, dictionary_dir, primitive)
    intern_identity(store, parent, primitive, words)
  end

  @doc "NAME → identity word entries for the current prelude (interns `.fs` bytes)."
  def words_identity(store, dictionary_dir, primitive \\ Forth.primitive_contract()) do
    dir = words_dir(dictionary_dir)

    case File.ls(dir) do
      {:error, _} ->
        %{}

      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".fs"))
        |> Enum.filter(&Regex.match?(@safe_name, Path.basename(&1, ".fs")))
        |> Enum.reduce(%{}, fn file, acc ->
          name = Path.basename(file, ".fs")
          path = Path.join(dir, file)

          case File.read(path) do
            {:ok, bin} when is_binary(bin) ->
              if String.valid?(bin) do
                sidecar = load_identity(dictionary_dir, name)
                contract = Contracts.canonical((Contracts.extract(bin) || %{})[name])

                if contract && sidecar do
                  Map.put(acc, name, %{
                    "source" => Store.intern(store, bin),
                    "contract" => contract,
                    "effects" => sidecar["effects"] || [],
                    "callees" => callees(colon_body(bin), name),
                    "path_region" => sidecar["path_region"] || [],
                    "primitive_contract" => primitive
                  })
                else
                  acc
                end
              else
                acc
              end

            _ ->
              acc
          end
        end)
    end
  end

  defp word_identity(entry) when is_map(entry) do
    entry = stringify_keys(entry)

    %{
      "source" => digest_hex(entry["source"]),
      "contract" => entry["contract"] || "",
      "effects" => sort_uniq(entry["effects"] || []),
      "callees" => sort_uniq(entry["callees"] || []),
      "path_region" => sort_uniq(entry["path_region"] || []),
      "primitive_contract" => digest_hex(entry["primitive_contract"]) || Forth.primitive_contract()
    }
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp sort_uniq(list) when is_list(list) do
    list |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()
  end

  defp sort_uniq(_), do: []

  defp colon_body(source) do
    case Forth.tokenize(source) do
      [%{kind: :word, value: colon} | rest] ->
        if colon == ":" do
          rest |> drop_name() |> drop_trailing_semi() |> body_source()
        else
          body_source([%{kind: :word, value: colon} | rest])
        end

      toks ->
        body_source(toks)
    end
  rescue
    _ -> source
  end

  defp drop_name([%{kind: :word} | rest]), do: rest
  defp drop_name(rest), do: rest

  defp drop_trailing_semi(tokens) do
    case Enum.reverse(tokens) do
      [%{kind: :word, value: ";"} | mid] -> Enum.reverse(mid)
      _ -> tokens
    end
  end
end
