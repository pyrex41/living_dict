defmodule LdHost.Bench.Exp0 do
  @moduledoc """
  Exp 0: same planner (`LdHost.Planner`), mixed-family warm (union of
  sequences 1–7 across eval families) then seq-8 load-all vs grant+path
  retrieved. Reads `eval/tasks` only; never writes eval/.

  Kill switch (human reviews the receipt): retrieved seq-8 is
  non-inferior to load-all **and** prelude size or unused-word load
  shrinks. Both failing equally is not a kill. Default `LD_DICT_MODE`
  stays `load-all`.
  """

  alias LdHost.{Critic, Dictionary, Retrieve}

  @warm_sequences 1..7

  def eval_root(repo \\ Critic.repo_root()), do: Path.join(repo, "eval")

  @doc "Read-only discovery of vendored eval tasks."
  def discover(eval_root \\ eval_root()) do
    tasks = list_tasks(eval_root)
    warm = Enum.filter(tasks, &(&1.sequence in @warm_sequences))
    score = Enum.filter(tasks, &(&1.sequence == 8))

    %{
      eval_root: eval_root,
      families: tasks |> Enum.map(& &1.family) |> Enum.uniq() |> Enum.sort(),
      warm: Enum.sort_by(warm, &{&1.family, &1.sequence, &1.id}),
      score: Enum.sort_by(score, &{&1.family, &1.id})
    }
  end

  def list_tasks(eval_root) do
    Path.wildcard(Path.join([eval_root, "tasks", "*", "task.toml"]))
    |> Enum.map(&load_task(Path.dirname(&1)))
    |> Enum.reject(&is_nil/1)
  end

  def load_task(dir) do
    toml_path = Path.join(dir, "task.toml")

    case File.read(toml_path) do
      {:ok, toml} ->
        id = toml_value(toml, "id") || Path.basename(dir)

        %{
          id: id,
          dir: dir,
          family: toml_value(toml, "family") || "default",
          sequence: parse_int(toml_value(toml, "sequence") || "0"),
          goal: read_goal(dir),
          allowed_effects: toml_list(toml, "allowed_effects") |> default_effects(),
          allowed_globs: toml_list(toml, "allowed_globs"),
          forbidden_globs: toml_list(toml, "forbidden_globs"),
          contract: hidden_contract(dir)
        }

      _ ->
        nil
    end
  end

  @doc """
  Snapshot prelude metrics for one grant. Used by both arms and tests;
  does not run a planner.
  """
  def prelude_metrics(dictionary_dir, mode, query, opts \\ []) do
    {prelude, words} =
      Dictionary.load_prelude(
        dictionary_dir,
        Keyword.merge(opts, dict_mode: mode, query: query)
      )

    %{
      prelude: prelude,
      prelude_words: words,
      prelude_bytes: byte_size(prelude),
      prelude_word_count: length(words)
    }
  end

  @doc """
  Seq-8 non-inferiority plus size. `load_all` / `retrieved` are metric
  maps with `:seq8_success` (or `:success` rate 0.0–1.0 or count) and
  prelude/unused totals.
  """
  def kill_switch(load_all, retrieved, opts \\ []) do
    seq8_la = seq8_success(load_all)
    seq8_rt = seq8_success(retrieved)
    non_inferior = seq8_rt >= seq8_la
    verifier_usable? = Keyword.get(opts, :verifier_usable, true)

    prelude_shrunk =
      metric(retrieved, :prelude_bytes) < metric(load_all, :prelude_bytes) or
        metric(retrieved, :prelude_word_count) < metric(load_all, :prelude_word_count)

    unused_shrunk = metric(retrieved, :unused_loaded_words) < metric(load_all, :unused_loaded_words)
    shrunk = prelude_shrunk or unused_shrunk
    proceed? = verifier_usable? and non_inferior and shrunk

    reasons =
      []
      |> maybe(not verifier_usable?, "verifier slot missing or unusable")
      |> maybe(not non_inferior, "retrieved seq-8 is worse than load-all")
      |> maybe(verifier_usable? and non_inferior and not shrunk, "seq-8 non-inferior but prelude/unused did not shrink")

    %{
      proceed: proceed?,
      seq8_non_inferior: non_inferior,
      shrunk: shrunk,
      verifier_usable: verifier_usable?,
      load_all_seq8_success: seq8_la,
      retrieved_seq8_success: seq8_rt,
      reasons: reasons,
      note: "human reviews this receipt; default LD_DICT_MODE remains load-all"
    }
  end

  @doc "Absolute path to `protected/verify.py`, or nil."
  def verifier_path(%{dir: dir}), do: verifier_path(dir)

  def verifier_path(dir) when is_binary(dir) do
    path = Path.join([dir, "protected", "verify.py"])
    if File.regular?(path), do: path
  end

  @doc """
  Probe the hidden eval verifier without writing eval/. Copies `repo/`
  (and `protected/oracle/files` when present) to a temp workspace and
  requires `python3` plus JSON `checks` on stdout. Missing interpreter,
  missing script, or a protocol crash is unusable — the kill switch must
  not treat that as equal seq-8 failure.
  """
  def probe_verifier(task) do
    dir = if is_map(task), do: task.dir, else: task
    verify = verifier_path(dir)
    python = System.find_executable("python3")
    repo = Path.join(dir, "repo")
    oracle = Path.join([dir, "protected", "oracle", "files"])

    cond do
      is_nil(python) ->
        {:error, "python3 not on PATH"}

      is_nil(verify) ->
        {:error, "verify.py missing"}

      not File.dir?(repo) ->
        {:error, "task repo missing"}

      true ->
        ws =
          System.tmp_dir!()
          |> Path.join("ld-exp0-probe-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}")

        try do
          File.cp_r!(repo, ws)
          if File.dir?(oracle), do: File.cp_r!(oracle, ws)
          {output, status} = System.cmd(python, [verify, ws], stderr_to_stdout: true)

          case JSON.decode(String.trim(output)) do
            {:ok, %{"checks" => checks}} when is_list(checks) and checks != [] ->
              {:ok, %{exit: status, checks: length(checks)}}

            _ ->
              {:error, "verify.py did not print checks JSON (exit #{inspect(status)})"}
          end
        after
          File.rm_rf(ws)
        end
    end
  end

  @doc """
  Warm mixed-family dict (seq 1–7, load-all persist), then score every
  `*-08` under load-all and retrieved. Same `planner_fn` (default
  `LdHost.Planner`). Writes the compare receipt under `:out`, never
  under eval/.
  """
  def run(opts \\ []) do
    eval_root = Keyword.get(opts, :eval_root, eval_root())
    discovered = discover(eval_root)
    warm_tasks = Keyword.get(opts, :warm_tasks, discovered.warm)
    score_tasks = Keyword.get(opts, :score_tasks, discovered.score)
    out = Keyword.get(opts, :out) || default_out()
    planner_fn = Keyword.get(opts, :planner_fn, &default_planner/3)
    max_episodes = Keyword.get(opts, :max_episodes, 6)
    reps = Keyword.get(opts, :reps, 1)

    File.mkdir_p!(out)

    probes =
      if Keyword.get(opts, :probe_verifiers, true) do
        Enum.map(score_tasks, fn task -> {task.id, probe_verifier(task)} end)
      else
        Enum.map(score_tasks, &{&1.id, {:ok, %{skipped: true}}})
      end

    unusable =
      for {id, {:error, reason}} <- probes do
        %{"task" => id, "reason" => reason}
      end

    verifier_usable? = unusable == [] and score_tasks != []

    {warm_results, score} =
      if verifier_usable? do
        warm_dict = Path.join(out, "warm-dict")
        File.mkdir_p!(Path.join(warm_dict, "words"))

        warm_rows =
          Enum.flat_map(1..reps, fn rep ->
            Enum.map(warm_tasks, fn task ->
              run_task(task, planner_fn, warm_dict, :load_all, out, "warm-#{rep}", max_episodes)
            end)
          end)

        scored =
          Map.new([:load_all, :retrieved], fn arm ->
            dict = Path.join(out, "score-#{arm}")
            copy_dict!(warm_dict, dict)

            rows =
              Enum.flat_map(1..reps, fn rep ->
                Enum.map(score_tasks, fn task ->
                  run_score(task, planner_fn, dict, arm, out, "score-#{arm}-#{rep}", max_episodes)
                end)
              end)

            {arm, aggregate(rows)}
          end)

        {warm_rows, scored}
      else
        {[], %{load_all: empty_arm(), retrieved: empty_arm()}}
      end

    verdict =
      kill_switch(score[:load_all], score[:retrieved], verifier_usable: verifier_usable?)

    receipt = %{
      experiment: "exp0",
      eval_root: eval_root,
      families: discovered.families,
      warm_ids: Enum.map(warm_tasks, & &1.id),
      score_ids: Enum.map(score_tasks, & &1.id),
      reps: reps,
      verifier: %{usable: verifier_usable?, errors: unusable},
      warm: warm_results,
      arms: score,
      kill_switch: verdict,
      planner: "LdHost.Planner"
    }

    File.write!(Path.join(out, "receipt.json"), JSON.encode!(receipt) <> "\n")
    Map.put(receipt, :out, out)
  end

  def main(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          eval_root: :string,
          out: :string,
          max_episodes: :integer,
          reps: :integer,
          discover: :boolean
        ]
      )

    eval_root = opts[:eval_root] || eval_root()

    if opts[:discover] do
      found = discover(eval_root)

      score_verifiers =
        Map.new(found.score, fn task ->
          case probe_verifier(task) do
            {:ok, meta} -> {task.id, Map.put(meta, :usable, true)}
            {:error, reason} -> {task.id, %{usable: false, reason: reason}}
          end
        end)

      IO.puts(
        JSON.encode!(%{
          eval_root: found.eval_root,
          families: found.families,
          warm_ids: Enum.map(found.warm, & &1.id),
          score_ids: Enum.map(found.score, & &1.id),
          verifiers: score_verifiers
        })
      )
    else
      receipt =
        run(
          eval_root: eval_root,
          out: opts[:out],
          max_episodes: opts[:max_episodes] || 6,
          reps: opts[:reps] || 1
        )

      IO.puts(JSON.encode!(receipt.kill_switch))
      IO.puts("receipt: #{Path.join(receipt.out, "receipt.json")}")
    end
  end

  defp run_score(task, planner_fn, dictionary_dir, arm, out, label, max_episodes) do
    query =
      Retrieve.host_query(task.allowed_effects, task.allowed_globs, task.forbidden_globs)

    before = prelude_metrics(dictionary_dir, arm, query)
    row = run_task(task, planner_fn, dictionary_dir, arm, out, label, max_episodes)

    used = row[:used_prelude_words] || []
    unused = length(before.prelude_words -- used)

    Map.merge(row, %{
      prelude_bytes: before.prelude_bytes,
      prelude_word_count: before.prelude_word_count,
      prelude_words: before.prelude_words,
      unused_loaded_words: unused
    })
  end

  defp run_task(task, planner_fn, dictionary_dir, arm, out, label, max_episodes) do
    ws = seed_workspace(out, label, task)
    started = System.monotonic_time(:millisecond)

    result =
      LdHost.Run.run(task.goal,
        workspace: ws,
        dictionary_dir: dictionary_dir,
        contract: task.contract,
        planner_fn: planner_fn,
        max_episodes: max_episodes,
        dict_mode: arm,
        allowed_effects: task.allowed_effects,
        allowed_globs: task.allowed_globs ++ ["claims.json", ".sb/*"],
        forbidden_globs: task.forbidden_globs ++ [".livingdict-run/*", ".git/*", "node_modules/*", "dist/*"]
      )

    %{
      arm: to_string(arm),
      task: task.id,
      family: task.family,
      sequence: task.sequence,
      success: result.success,
      tokens: result.tokens,
      model_calls: result.model_calls,
      wall_ms: System.monotonic_time(:millisecond) - started,
      used_prelude_words: result.used_prelude_words,
      run_dir: result.run_dir
    }
  end

  defp aggregate(rows) do
    n = max(length(rows), 1)

    %{
      rows: rows,
      seq8_success: Enum.count(rows, & &1.success) / n,
      prelude_bytes: avg(rows, :prelude_bytes),
      prelude_word_count: avg(rows, :prelude_word_count),
      unused_loaded_words: avg(rows, :unused_loaded_words),
      input_tokens: Enum.reduce(rows, 0, &(&2 + &1.tokens.input_tokens)),
      output_tokens: Enum.reduce(rows, 0, &(&2 + &1.tokens.output_tokens)),
      model_calls: Enum.reduce(rows, 0, &(&2 + &1.model_calls))
    }
  end

  defp empty_arm do
    %{
      rows: [],
      seq8_success: 0,
      prelude_bytes: 0,
      prelude_word_count: 0,
      unused_loaded_words: 0,
      input_tokens: 0,
      output_tokens: 0,
      model_calls: 0
    }
  end

  defp avg([], _key), do: 0

  defp avg(rows, key) do
    Enum.reduce(rows, 0, &(&2 + (&1[key] || 0))) / length(rows)
  end

  defp seq8_success(metrics) do
    cond do
      is_number(Map.get(metrics, :seq8_success)) -> metrics.seq8_success
      is_number(Map.get(metrics, "seq8_success")) -> metrics["seq8_success"]
      is_number(Map.get(metrics, :success)) -> metrics.success
      true -> 0
    end
  end

  defp metric(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || 0
  end

  defp maybe(reasons, true, reason), do: reasons ++ [reason]
  defp maybe(reasons, false, _reason), do: reasons

  defp copy_dict!(from, to) do
    File.rm_rf!(to)
    File.mkdir_p!(Path.dirname(to))
    File.cp_r!(from, to)
  end

  defp seed_workspace(out, label, task) do
    ws = Path.join([out, label, task.id, "ws"])
    File.mkdir_p!(Path.dirname(ws))

    repo = Path.join(task.dir, "repo")

    if File.dir?(repo) do
      File.cp_r!(repo, ws)
    else
      File.mkdir_p!(ws)
    end

    File.write!(Path.join(ws, "TASK.md"), task.goal)
    ws
  end

  defp hidden_contract(dir) do
    verify = Path.join([dir, "protected", "verify.py"])

    if File.exists?(verify) do
      check =
        ~s{out=$(python3 "#{verify}" "$PWD" 2>/dev/null) && echo "$out" | grep -q '"checks"' && } <>
          ~s{! echo "$out" | grep -q '"passed": false'}

      %{claims: [%{"id" => "hidden-verifier", "kind" => "check", "command" => check, "timeout_seconds" => 120}]}
    else
      nil
    end
  end

  defp read_goal(dir) do
    case File.read(Path.join(dir, "prompt.md")) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp toml_value(toml, key) do
    case Regex.run(~r/^#{key}\s*=\s*"?([^"\n]+)"?\s*$/m, toml) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp toml_list(toml, key) do
    case Regex.run(~r/^#{key}\s*=\s*\[(.*)\]\s*$/m, toml) do
      [_, inner] ->
        inner
        |> String.split(",")
        |> Enum.map(&String.trim(String.trim(&1), "\""))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp parse_int(text) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp default_effects([]), do: ["read", "write", "exec"]
  defp default_effects(list), do: list

  defp default_planner(goal, observation, feedback) do
    observation = if feedback == "", do: observation, else: observation <> "\nFEEDBACK:\n" <> feedback
    LdHost.Planner.plan(goal, observation)
  end

  defp default_out do
    Path.join([Critic.repo_root(), "beam", "runs", "exp0-" <> stamp()])
  end

  defp stamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
