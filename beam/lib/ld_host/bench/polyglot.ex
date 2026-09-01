defmodule LdHost.Bench.Polyglot do
  @moduledoc """
  Aider Polyglot benchmark adapter: exercism practice exercises from a
  sibling checkout of https://github.com/Aider-AI/polyglot-benchmark
  become obligations racing through the Layer C stack, exactly like the
  vendored-eval demo (`LdHost.Demo`) but per language track.

  Layout (verified against the real clone):

      <root>/<lang>/exercises/practice/<slug>/
        .docs/instructions.md            <- the goal (plus instructions.append.md)
        .meta/example.*                  <- reference solution, NEVER seeded
        <stub + test + build files>      <- seeded into the arm workspace

  - `tasks/2` lists a language track alphabetically; that order IS the
    warm-dictionary sequence.
  - Seeding copies the exercise dir excluding every dot-entry (`.meta`,
    `.docs`, `.approaches`, ...): the goal text carries the instructions,
    and reference solutions must never reach a workspace.
  - The hidden contract is one check claim per exercise running the
    language's offline-guarded test command.
  - `run/2` races arms per track: `cold` (fresh dictionary per task),
    `warm` (shared `<out>/warm-dict-<lang>` across the track), and an
    optional `grok` baseline on the first `:grok_sample` exercises.
  """

  alias LdHost.{Cmd, Dispatcher, Ledger, Policy, Progress, Space, Verdict}
  alias LdHost.Bench.GrokArm

  @default_arms ~w(cold warm)
  @languages ~w(rust go cpp)

  @doc "Default sibling checkout of the Aider polyglot benchmark."
  def default_root do
    System.get_env("POLYGLOT_BENCH_ROOT") || Path.expand("~/projects/polyglot-benchmark")
  end

  # ---- task loading -----------------------------------------------------

  @doc """
  All exercises of one language track, sorted alphabetically by slug —
  that order is the warm-dictionary sequence. Each task map mirrors the
  demo's shape: id, family, sequence, goal, dir, globs, hidden contract.
  """
  def tasks(lang, bench_root \\ nil) do
    unless lang in @languages do
      raise ArgumentError,
            "unsupported polyglot language #{inspect(lang)} (want one of #{Enum.join(@languages, ", ")})"
    end

    root = bench_root || default_root()
    practice = Path.join([root, lang, "exercises", "practice"])

    unless File.dir?(practice) do
      raise ArgumentError,
            "polyglot benchmark not found at #{practice} — clone Aider-AI/polyglot-benchmark there"
    end

    cfg = lang_config(lang)

    practice
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(practice, &1)))
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.map(fn {slug, i} ->
      dir = Path.join(practice, slug)

      %{
        id: "#{lang}/#{slug}",
        family: lang,
        sequence: i,
        goal: goal_text(dir),
        dir: dir,
        allowed_globs: cfg.allowed,
        forbidden_globs: cfg.forbidden,
        contract: %{
          "claims" => [
            %{
              "id" => "#{lang}-tests",
              "kind" => "check",
              "command" => cfg.check,
              "timeout_seconds" => cfg.timeout_seconds
            }
          ]
        }
      }
    end)
  end

  defp goal_text(dir) do
    instructions = File.read!(Path.join([dir, ".docs", "instructions.md"]))

    append =
      case File.read(Path.join([dir, ".docs", "instructions.append.md"])) do
        {:ok, text} -> "\n\n" <> text
        _ -> ""
      end

    instructions <> append
  end

  # Globs are fnmatch-style (LdHost.Policy): * crosses slashes, and
  # forbidden wins over allowed. Intent per track: solution files
  # writable; test files, harness bookkeeping, and build config frozen.
  defp lang_config("rust") do
    %{
      # target/* and Cargo.lock: cargo test writes them inside the
      # workspace; they are build fallout, not policy violations.
      allowed: ["Cargo.toml", "Cargo.lock", "src/*", "target/*"],
      forbidden: ["tests/*"],
      # --include-ignored: Exercism rust exercises mark all but the first
      # test #[ignore]; upstream Aider un-ignores them. Without this flag a
      # PASS rests on a single active test and inflates solve rates.
      check: "CARGO_NET_OFFLINE=true cargo test -- --include-ignored",
      timeout_seconds: 180
    }
  end

  defp lang_config("go") do
    # "*.go" also matches *_test.go, but forbidden takes precedence.
    # go.mod stays writable: GOFLAGS=-mod=mod may rewrite it during the
    # offline test run.
    %{
      allowed: ["*.go", "go.mod", "go.sum"],
      forbidden: ["*_test.go"],
      check: "GOPROXY=off GOFLAGS=-mod=mod go test ./...",
      timeout_seconds: 180
    }
  end

  defp lang_config("cpp") do
    # Out-of-source build keeps cmake fallout under build/ (a Policy
    # skip-dir). The generated test_<exercise> target runs the catch
    # binary on every build, so a failing suite fails the build command.
    %{
      allowed: ["*.cpp", "*.h", "*.hpp", "*.cc", "build/*"],
      forbidden: ["*_test.cpp", "test/*", "CMakeLists.txt"],
      check: "cmake -DEXERCISM_RUN_ALL_TESTS=1 -B build . && cmake --build build",
      timeout_seconds: 300
    }
  end

  # ---- seeding ----------------------------------------------------------

  @doc """
  Copy the exercise into `ws`, excluding every dot-entry at the exercise
  root (`.meta` reference solutions, `.docs`, `.approaches`, ...), and
  write TASK.md with the goal text — same shape as the demo's seeding.
  """
  def seed_workspace(task, ws) do
    File.mkdir_p!(ws)

    task.dir
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.each(fn entry ->
      File.cp_r!(Path.join(task.dir, entry), Path.join(ws, entry))
    end)

    File.write!(Path.join(ws, "TASK.md"), task.goal)
    ws
  end

  # ---- campaign ---------------------------------------------------------

  @doc """
  Race arms over each language track. Options:

  - `:arms` (default `["cold", "warm"]`; add `"grok"` for the baseline)
  - `:sample` — first N exercises per track
  - `:grok_sample` — grok baseline runs only on the first N exercises
    of each track (default 0)
  - `:max_episodes`, `:out`, `:bench_root`, `:serial`
  """
  def run(langs, opts \\ []) do
    repo = LdHost.Critic.repo_root()
    root = Keyword.get(opts, :bench_root, default_root())

    out =
      Keyword.get(opts, :out, Path.join([repo, "beam", "runs", "polyglot-" <> stamp()]))
      |> Path.expand()

    arms = Keyword.get(opts, :arms, @default_arms)
    sample = Keyword.get(opts, :sample)
    grok_sample = Keyword.get(opts, :grok_sample, 0)
    serial? = Keyword.get(opts, :serial, false)
    max_episodes = Keyword.get(opts, :max_episodes, 4)

    run_opts =
      [max_episodes: max_episodes]
      |> maybe_opt(:ooda_mode, Keyword.get(opts, :ooda_mode))
      |> maybe_opt(:reasoning_effort, Keyword.get(opts, :reasoning_effort))

    File.mkdir_p!(out)

    # Same guard as the demo: refresh shared planner credentials once,
    # before any arm launches.
    if Enum.any?(arms, &(&1 in ["cold", "warm"])) do
      case LdHost.Planner.credentials() do
        {:ok, _} -> :ok
        {:error, reason} -> raise "planner credentials unavailable: #{reason}"
      end
    end

    {:ok, ledger} = Ledger.start_link(Path.join(out, "orchestrator"))
    {:ok, space} = Space.start_link(record: Ledger.emitter(ledger))

    {:ok, _dispatcher} =
      Dispatcher.start_link(space: space, ledger: ledger, run_opts: run_opts)

    results_by_lang =
      Map.new(langs, fn lang ->
        tasks = tasks(lang, root)
        tasks = if sample, do: Enum.take(tasks, sample), else: tasks
        ctx = %{out: out, space: space, ledger: ledger, lang: lang}

        runner = fn arm ->
          track = if arm == "grok", do: Enum.take(tasks, grok_sample), else: tasks
          {arm, run_arm(arm, track, ctx)}
        end

        lang_results =
          if serial? do
            Map.new(arms, runner)
          else
            arms
            |> Enum.map(&Task.async(fn -> runner.(&1) end))
            |> Enum.map(&Task.await(&1, :infinity))
            |> Map.new()
          end

        {lang, lang_results}
      end)

    summarize(out, ledger, langs, results_by_lang)
  end

  # ---- arms -------------------------------------------------------------

  defp run_arm("grok", tasks, ctx) do
    Enum.map(tasks, fn task ->
      {ws, baseline} = seed(ctx.out, "grok", task)
      started = System.monotonic_time(:millisecond)

      {usage, calls, exit_status} =
        GrokArm.run(task.goal, ws, Path.join([ctx.out, "grok", task.id, "grok-output.txt"]))

      claim = hd(task.contract["claims"])
      score = Cmd.sh(claim["command"], ws, claim["timeout_seconds"] * 1000)
      cleanup_builds(ws)

      result = %{
        arm: "grok",
        task: task.id,
        success: score.returncode == 0,
        tokens: usage,
        model_calls: calls,
        wall_ms: System.monotonic_time(:millisecond) - started,
        policy_violations: policy_violation_count(ws, baseline, task),
        exit_status: exit_status
      }

      Ledger.trace(ctx.ledger, "polyglot.arm_result", result)
      result
    end)
  end

  defp run_arm(arm, tasks, ctx) when arm in ["cold", "warm"] do
    shared_dict = Path.join(ctx.out, "warm-dict-#{ctx.lang}")

    tasks
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map(fn task ->
      {ws, baseline} = seed(ctx.out, arm, task)
      ob_id = "#{arm}-#{task.id}"
      Progress.subscribe({:obligation, ob_id})
      started = System.monotonic_time(:millisecond)

      obligation = %{
        "kind" => "obligation",
        "id" => ob_id,
        "goal" => task.goal,
        "workspace" => ws,
        "contract" => task.contract,
        "allowed_globs" => task.allowed_globs ++ ["claims.json", ".sb/*"],
        "forbidden_globs" => task.forbidden_globs
      }

      obligation =
        if arm == "warm", do: Map.put(obligation, "dictionary", shared_dict), else: obligation

      {:ok, _} = Space.out(ctx.space, obligation)

      summary = await_obligation(ob_id)
      cleanup_builds(ws)

      result = %{
        arm: arm,
        task: task.id,
        success: summary != nil and summary.success,
        tokens: (summary && summary.tokens) || %{input_tokens: 0, output_tokens: 0},
        model_calls: (summary && summary.model_calls) || 0,
        wall_ms: System.monotonic_time(:millisecond) - started,
        policy_violations: policy_violation_count(ws, baseline, task),
        run_dir: summary && summary.run_dir
      }

      result = Map.merge(result, summary_evidence(summary))

      Ledger.trace(ctx.ledger, "polyglot.arm_result", result)
      result
    end)
  end

  # Runtime evidence is optional: rows from an unreachable planner do not
  # claim that an empty catalog or zero invocations were observed.
  defp summary_evidence(summary) when is_map(summary) do
    [
      :catalog_before,
      :eligible_words,
      :used_words,
      :candidate_words,
      :promoted_words,
      :unused_eligible_words,
      :critic_covering_rejections,
      :judge,
      :ooda_mode,
      :initial_route,
      :repair_used,
      :research_rounds,
      :research_tool_calls,
      :research_evidence_bytes,
      :unresolved_questions
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      value = Map.get(summary, key)

      if Map.has_key?(summary, key) and
           not (key == :judge and value in [nil, "unknown", "no gates measured"]),
         do: Map.put(acc, key, value),
         else: acc
    end)
  end

  defp summary_evidence(_), do: %{}

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp seed(out, arm, task) do
    # task.id is "<lang>/<slug>", so this lands at
    # <out>/<arm>/<lang>/<slug>/<slug>. The workspace dir is NAMED AFTER
    # the slug on purpose: the cpp CMakeLists derives its target and
    # source names from the directory name.
    ws = Path.join([out, arm, task.id, Path.basename(task.id)])
    seed_workspace(task, ws)
    {ws, Policy.snapshot(ws)}
  end

  defp await_obligation(ob_id) do
    receive do
      {:ld_progress, {:obligation, ^ob_id}, {status, summary}}
      when status in [:completed, :failed] ->
        summary

      {:ld_progress, {:obligation, ^ob_id}, :crashed} ->
        nil

      {:ld_progress, {:obligation, ^ob_id}, _other} ->
        await_obligation(ob_id)
    after
      1_800_000 -> nil
    end
  end

  # rust's target/ (and any stray in-source cmake build/) are hundreds of
  # MB per exercise: delete them as soon as the exercise is scored.
  defp cleanup_builds(ws) do
    Enum.each(["target", "build"], fn dir ->
      File.rm_rf(Path.join(ws, dir))
    end)
  end

  # Baseline is the freshly seeded workspace (dot-dirs already excluded),
  # so only what the arm changed counts. TASK.md and claims.json are
  # harness bookkeeping, not violations.
  defp policy_violation_count(ws, baseline, task) do
    now = Policy.snapshot(ws)

    Policy.changed_files(baseline, now)
    |> Enum.reject(&(&1 in ["TASK.md", "claims.json"]))
    |> Enum.count(fn rel ->
      Policy.matches_any?(rel, task.forbidden_globs) or
        not Policy.matches_any?(rel, task.allowed_globs)
    end)
  end

  # ---- summary ----------------------------------------------------------

  defp summarize(out, ledger, langs, results_by_lang) do
    verdicts =
      Map.new(langs, fn lang ->
        results = results_by_lang[lang] || %{}
        cold = results["cold"] || []
        warm = results["warm"] || []

        verdict =
          if cold != [] and warm != [] do
            measures = Verdict.measures(cold, warm)
            {allowed, reasons} = Verdict.warm_run_allowed(measures)
            %{measures: measures, allowed: allowed, reasons: reasons}
          end

        {lang, verdict}
      end)

    summary = %{langs: langs, results: results_by_lang, verdicts: verdicts}
    File.write!(Path.join(out, "summary.json"), JSON.encode!(summary))
    File.write!(Path.join(out, "summary.md"), render_markdown(langs, results_by_lang, verdicts))

    Enum.each(verdicts, fn {lang, verdict} ->
      if verdict, do: Ledger.trace(ledger, "polyglot.verdict", Map.put(verdict, :lang, lang))
    end)

    Map.put(summary, :out, out)
  end

  defp render_markdown(langs, results_by_lang, verdicts) do
    sections =
      Enum.map_join(langs, "\n", fn lang ->
        results = results_by_lang[lang] || %{}

        task_ids =
          results
          |> Map.values()
          |> List.flatten()
          |> Enum.map(& &1.task)
          |> Enum.uniq()
          |> Enum.sort()

        header =
          "| arm | " <>
            Enum.map_join(task_ids, " | ", &Path.basename/1) <>
            " | tokens (in/out) | model calls |\n"

        divider = "|---|" <> String.duplicate("---|", length(task_ids) + 2) <> "\n"

        rows =
          Enum.map_join(results, "", fn {arm, arm_results} ->
            by_task = Map.new(arm_results, &{&1.task, &1})

            cells =
              Enum.map_join(task_ids, " | ", fn id ->
                case by_task[id] do
                  nil -> "—"
                  %{success: true} -> "PASS"
                  _ -> "fail"
                end
              end)

            tin = Enum.sum(Enum.map(arm_results, & &1.tokens.input_tokens))
            tout = Enum.sum(Enum.map(arm_results, & &1.tokens.output_tokens))
            calls = Enum.sum(Enum.map(arm_results, & &1.model_calls))
            "| #{arm} | #{cells} | #{tin}/#{tout} | #{calls} |\n"
          end)

        "## #{lang}\n\n" <> header <> divider <> rows <> verdict_markdown(verdicts[lang])
      end)

    "# Polyglot arms race: same goals, hidden judge\n\n" <> sections
  end

  defp verdict_markdown(nil), do: "\n_No cold/warm pair — verdict not computed._\n"

  defp verdict_markdown(%{measures: m, allowed: allowed, reasons: reasons}) do
    """

    ### Preregistered warm-dictionary verdict

    - success delta: #{Float.round(m.success_delta_points * 1.0, 1)} points
    - token reduction: #{Float.round(m.token_reduction_fraction * 100.0, 1)}%
    - policy violations increased: #{m.policy_violations_increased}
    - negative transfer: #{m.negative_transfer}

    **#{if allowed, do: "GO — warm dictionary passes the preregistered thresholds", else: "NO-GO"}**#{if reasons != [], do: "\n\nReasons: " <> Enum.join(reasons, "; "), else: ""}
    """
  end

  defp stamp, do: DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
end
