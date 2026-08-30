defmodule LdHost.Extract do
  @moduledoc """
  Host-synthesized installer words after a successful episode that
  introduced no planner colon definitions. Fallback only: planner-authored
  contracted words keep `promote/5` and win in the same episode.

  v1 body is the generic installer from the planner prompt:

      : NAME ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;
  """

  alias LdHost.{Critic, Dictionary, Forth, Policy, Retrieve, Store}

  @contract "( key -- | read, write )"
  @body "DUP USE-ARTIFACT SWAP WRITE-FILE DROP"
  @excluded_exact MapSet.new(["claims.json"])
  @excluded_prefixes [".sb/", ".livingdict-run/", ".git/"]

  def generic_contract, do: @contract
  def generic_body, do: @body

  @doc """
  Extract-after-success flag. Default on (`LD_EXTRACT=1`); `0`/`false`
  disables for A/B. `opts[:extract]` wins over the environment.
  """
  def enabled?(opts \\ []) do
    raw =
      case Keyword.fetch(opts, :extract) do
        {:ok, value} -> value
        :error -> System.get_env("LD_EXTRACT") || "1"
      end

    cond do
      raw in [false, :false, 0, "0"] -> false
      is_binary(raw) and String.downcase(String.trim(raw)) in ["0", "false"] -> false
      true -> true
    end
  end

  @doc "Product `WRITE-FILE` paths from program literals and host mutations."
  def product_writes(program, mutation_paths \\ []) do
    (write_file_literals(program) ++ List.wrap(mutation_paths))
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == "" or excluded?(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Synthesize one generic installer for this episode, or `:none`.

  Requires at least one product write and the install idiom
  `S\" key\" USE-ARTIFACT S\" path\" WRITE-FILE` with `key == path` on a
  product path. Reserved names return `{:refuse, candidate, reasons}`.
  """
  def candidate(program, opts \\ []) do
    mutations = Keyword.get(opts, :mutations, [])
    paths = product_writes(program, mutations)

    cond do
      paths == [] ->
        :none

      not idiom?(program, paths) ->
        :none

      true ->
        build_candidate(Keyword.get(opts, :name) || word_name(paths), paths)
    end
  end

  defp build_candidate(name, paths) do
    cand = %{
      name: name,
      contract: @contract,
      body: @body,
      path_region: paths,
      effects: ["read", "write"],
      task_families: [],
      source: definition_source(name)
    }

    if Dictionary.safe_name?(name) do
      {:ok, cand}
    else
      {:refuse, cand, ["reserved or unsafe name"]}
    end
  end

  def definition_source(name) do
    ": #{name} #{@contract} #{@body} ;\n"
  end

  @doc "INSTALL-<SAFE_NAME> slug of the sorted unique path region."
  def word_name(paths) do
    tokens =
      paths
      |> Enum.sort()
      |> Enum.flat_map(&path_tokens/1)
      |> uniq_order()

    base =
      case tokens do
        [] -> "INSTALL-" <> String.upcase(short_hash(paths))
        _ -> "INSTALL-" <> Enum.join(tokens, "-")
      end

    fit_name(base, paths)
  end

  @doc "True when `words/NAME.fs` already holds this source."
  def identical_source?(dictionary_dir, %{name: name, source: source}) do
    path = Path.join(Dictionary.words_dir(dictionary_dir), "#{name}.fs")

    case File.read(path) do
      {:ok, existing} -> existing == source
      _ -> false
    end
  end

  @doc """
  Shen-admit `prelude ⊕ definition` under the episode grant.
  Reject does not write a `.fs` file.
  """
  def admit(candidate, opts) do
    if Dictionary.safe_name?(candidate.name) do
      prelude = Keyword.get(opts, :prelude, "")
      program = compose(prelude, String.trim(candidate.source))

      case Critic.validate(
             program,
             Keyword.get(opts, :allowed_effects, ["read", "write", "exec"]),
             Keyword.get(opts, :allowed_globs, candidate.path_region),
             Keyword.get(opts, :forbidden_globs, [".livingdict-run/*", ".git/*"]),
             Keyword.get(opts, :artifact_keys, candidate.path_region)
           ) do
        {:accept, depth, effects} -> {:accept, depth, effects}
        {:reject, errors, _depth, _effects} -> {:reject, errors}
        {:error, reason} -> {:reject, [to_string(reason)]}
      end
    else
      {:reject, ["reserved or unsafe name"]}
    end
  end

  @doc "Persist via existing `save_words`; path_region is product writes only."
  def persist(dictionary_dir, candidate) do
    Dictionary.save_words(
      dictionary_dir,
      [{candidate.name, candidate.body, candidate.contract}],
      allowed_globs: candidate.path_region
    )
  end

  def compose("", program), do: program
  def compose(prelude, program), do: prelude <> "\n" <> program

  @doc "WRITE-FILE / mutation.applied paths from a trace or events list."
  def mutation_paths(events) when is_list(events) do
    events
    |> Enum.flat_map(&event_write_path/1)
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
  end

  def mutation_paths(_), do: []

  @doc "Reconstruct the v1 install idiom from product mutation paths (no VM)."
  def program_from_mutations(paths) do
    ""
    |> product_writes(paths)
    |> Enum.map(fn path -> ~s[S" #{path}" USE-ARTIFACT S" #{path}" WRITE-FILE DROP] end)
    |> Enum.join(" ")
  end

  @doc """
  Offline Exp A: extract from successful warm traces, admit without a
  planner, write a synthetic dictionary and receipt under `out_dir`.
  """
  def replay(in_dir, out_dir, opts \\ []) do
    in_dir = Path.expand(in_dir)
    out_dir = Path.expand(out_dir)
    File.mkdir_p!(out_dir)
    dict_dir = Keyword.get(opts, :dictionary_dir, Path.join(out_dir, "dictionary"))
    File.mkdir_p!(Dictionary.words_dir(dict_dir))
    store = Store.new(Path.join(out_dir, "objects"))

    episodes = warm_success_episodes(in_dir)
    prelude = ""

    {stats, _prelude} =
      Enum.reduce(episodes, {empty_replay_stats(), prelude}, fn episode, {stats, prelude} ->
        replay_episode(episode, dict_dir, prelude, stats, opts)
      end)

    Dictionary.intern_from_dir(store, dict_dir)

    index = Retrieve.index(dictionary_dir: dict_dir)
    {config_globs, config_forbidden} = grant_for("config-08", ["app/config.py"])
    {parser_globs, parser_forbidden} = grant_for("parser-08", ["src/records.py"])

    config_q = Retrieve.host_query(["read", "write", "exec"], config_globs, config_forbidden)
    parser_q = Retrieve.host_query(["read", "write", "exec"], parser_globs, parser_forbidden)

    names = stats.names |> Enum.uniq() |> Enum.sort()
    candidate_n = stats.candidates
    admitted_n = stats.accepted

    receipt = %{
      "experiment" => "extract-a",
      "in" => in_dir,
      "out" => out_dir,
      "episodes" => length(episodes),
      "candidates" => candidate_n,
      "admitted" => admitted_n,
      "rejected" => stats.rejected,
      "identical_skips" => stats.skips,
      "admit_rate" =>
        if(candidate_n == 0, do: 0.0, else: admitted_n / candidate_n),
      "names" => names,
      "path_regions" => stats.regions,
      "retrieve" => %{
        "config-08" => Retrieve.candidates(index, config_q),
        "parser-08" => Retrieve.candidates(index, parser_q)
      }
    }

    File.write!(Path.join(out_dir, "receipt.json"), JSON.encode!(receipt) <> "\n")
    receipt
  end

  defp empty_replay_stats do
    %{candidates: 0, accepted: 0, rejected: 0, skips: 0, names: [], regions: %{}}
  end

  defp replay_episode(episode, dict_dir, prelude, stats, opts) do
    program = program_from_mutations(episode.mutations)

    case candidate(program, mutations: episode.mutations) do
      :none ->
        {stats, prelude}

      {:refuse, cand, reasons} ->
        stats = %{
          stats
          | candidates: stats.candidates + 1,
            rejected: stats.rejected + 1,
            names: stats.names ++ [cand.name],
            regions: Map.put(stats.regions, cand.name, cand.path_region)
        }

        _ = reasons
        {stats, prelude}

      {:ok, cand} ->
        stats = %{
          stats
          | candidates: stats.candidates + 1,
            names: stats.names ++ [cand.name],
            regions: Map.put(stats.regions, cand.name, cand.path_region)
        }

        cond do
          identical_source?(dict_dir, cand) ->
            {%{stats | accepted: stats.accepted + 1, skips: stats.skips + 1}, prelude}

          true ->
            grant = replay_grant(cand, episode, opts)

            case admit(cand, grant ++ [prelude: prelude]) do
              {:accept, _depth, _effects} ->
                _ = persist(dict_dir, cand)
                {prelude, _} = Dictionary.load_prelude(dict_dir)
                {%{stats | accepted: stats.accepted + 1}, prelude}

              {:reject, _errors} ->
                {%{stats | rejected: stats.rejected + 1}, prelude}
            end
        end
    end
  end

  defp replay_grant(cand, episode, opts) do
    [
      allowed_effects: Keyword.get(opts, :allowed_effects, ["read", "write", "exec"]),
      allowed_globs:
        Keyword.get(opts, :allowed_globs, cand.path_region ++ ["claims.json", ".sb/*"]),
      forbidden_globs:
        Keyword.get(
          opts,
          :forbidden_globs,
          episode.forbidden_globs || [".livingdict-run/*", ".git/*", "tests/**", "TASK.md"]
        ),
      artifact_keys: cand.path_region
    ]
  end

  defp grant_for(task_id, fallback_globs) do
    path = Path.join([Critic.repo_root(), "eval", "tasks", task_id, "task.toml"])

    case File.read(path) do
      {:ok, toml} ->
        globs = toml_list(toml, "allowed_globs")
        forbidden = toml_list(toml, "forbidden_globs")
        {if(globs == [], do: fallback_globs, else: globs), forbidden}

      _ ->
        {fallback_globs, ["tests/**", "TASK.md"]}
    end
  end

  defp toml_list(toml, key) do
    case Regex.run(~r/^#{Regex.escape(key)}\s*=\s*\[([^\]]*)\]/m, toml) do
      [_, inner] ->
        inner
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, "\""))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp warm_success_episodes(in_dir) do
    receipt = Path.join(in_dir, "receipt.json")

    from_receipt =
      case File.read(receipt) do
        {:ok, bin} ->
          case JSON.decode(bin) do
            {:ok, %{"warm" => warm}} when is_list(warm) ->
              warm
              |> Enum.filter(&(&1["success"] == true and is_binary(&1["run_dir"])))
              |> Enum.map(&episode_from_run_dir(&1["run_dir"], &1["task"]))

            _ ->
              []
          end

        _ ->
          []
      end

    episodes =
      if from_receipt != [] do
        from_receipt
      else
        in_dir
        |> Path.join("**/events.jsonl")
        |> Path.wildcard()
        |> Enum.filter(&warm_path?/1)
        |> Enum.map(fn events_path ->
          episode_from_run_dir(Path.dirname(events_path), nil)
        end)
      end

    episodes
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(& &1.ok)
  end

  defp warm_path?(events_path) do
    rel = events_path
    String.contains?(rel, "warm-") or String.contains?(rel, "/warm/") or
      not String.contains?(rel, "score-")
  end

  defp episode_from_run_dir(run_dir, task) do
    events = load_jsonl(Path.join(run_dir, "events.jsonl"))
    trace = load_jsonl(Path.join(run_dir, "trace.jsonl"))
    ok? = Enum.any?(events, &gates_ok?/1)

    %{
      run_dir: run_dir,
      task: task,
      ok: ok?,
      mutations: mutation_paths(trace ++ events),
      forbidden_globs: [".livingdict-run/*", ".git/*", "tests/**", "TASK.md"]
    }
  end

  defp gates_ok?(event) do
    kind = event["kind"] || event[:kind]
    payload = event["payload"] || event[:payload] || %{}
    kind == "gates.measured" and (payload["ok"] == true or payload[:ok] == true)
  end

  defp load_jsonl(path) do
    case File.read(path) do
      {:ok, bin} ->
        bin
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case JSON.decode(line) do
            {:ok, map} -> [map]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp event_write_path(event) when is_map(event) do
    type = event["type"] || event["kind"] || event[:type] || event[:kind]
    data = event["data"] || event["payload"] || event[:data] || event[:payload] || %{}
    path = data["path"] || data[:path]
    tool = data["tool"] || data[:tool]

    cond do
      type in ["mutation.applied", :mutation_applied] and is_binary(path) -> [path]
      type in ["tool.call", :tool_call] and tool == "WRITE-FILE" and is_binary(path) -> [path]
      true -> []
    end
  end

  defp event_write_path(_), do: []

  defp idiom?(program, product_paths) do
    wanted = MapSet.new(product_paths)

    program
    |> idiom_pairs()
    |> Enum.any?(fn {key, path} -> key == path and MapSet.member?(wanted, path) end)
  end

  defp idiom_pairs(program) do
    program
    |> tokens_or_empty()
    |> collect_idiom([])
    |> Enum.reverse()
  end

  defp collect_idiom([a, b, c, d | rest], acc) do
    if string?(a) and word?(b, "USE-ARTIFACT") and string?(c) and word?(d, "WRITE-FILE") do
      collect_idiom(rest, [{a.value, c.value} | acc])
    else
      collect_idiom([b, c, d | rest], acc)
    end
  end

  defp collect_idiom(_short, acc), do: acc

  defp string?(%{kind: :string}), do: true
  defp string?(_), do: false

  defp word?(%{kind: :word, value: value}, name), do: String.upcase(value) == name
  defp word?(_, _), do: false

  defp write_file_literals(program) do
    write_file_literals(tokens_or_empty(program), nil, [])
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

  defp tokens_or_empty(source) do
    Forth.tokenize(source || "")
  rescue
    _ -> []
  end

  defp excluded?(path) do
    path = normalize_path(path)
    MapSet.member?(@excluded_exact, path) or Enum.any?(@excluded_prefixes, &String.starts_with?(path, &1))
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim()
    |> String.trim_leading("./")
  end

  defp normalize_path(other), do: other |> to_string() |> normalize_path()

  defp path_tokens(path) do
    path
    |> normalize_path()
    |> Path.split()
    |> Enum.flat_map(fn part ->
      part
      |> Path.rootname()
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]+/, "-")
      |> String.split("-", trim: true)
    end)
  end

  defp uniq_order(list) do
    {out, _} =
      Enum.reduce(list, {[], MapSet.new()}, fn item, {acc, seen} ->
        if MapSet.member?(seen, item) do
          {acc, seen}
        else
          {acc ++ [item], MapSet.put(seen, item)}
        end
      end)

    out
  end

  defp fit_name(base, paths) do
    base = String.trim_trailing(base, "-")

    cond do
      Dictionary.safe_name?(base) ->
        base

      true ->
        hash = String.upcase(short_hash(paths))
        prefix = base |> String.slice(0, 54) |> String.trim_trailing("-")
        candidate = prefix <> "-" <> hash

        if Dictionary.safe_name?(candidate) do
          candidate
        else
          "INSTALL-" <> hash
        end
    end
  end

  defp short_hash(paths) do
    paths
    |> Enum.sort()
    |> Enum.join("\n")
    |> Policy.sha256_hex()
    |> String.slice(0, 8)
  end
end
