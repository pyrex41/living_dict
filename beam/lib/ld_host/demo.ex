defmodule LdHost.Demo do
  @moduledoc """
  The arms race: the same goals, three agents, one hidden judge.

  - `grok` — a ReAct-style CLI agent (`grok -p ... --output-format
    json`), scored by us after it exits; it never sees the contract.
  - `cold` — this host, fresh dictionary per task.
  - `warm` — this host, family-shared dictionary carried across the
    task sequence (promoted words compound).

  Tasks come from the vendored eval (`eval/tasks/<id>`): the goal is
  prompt.md, the seed is repo/, and the hidden contract runs the task's
  ACTUAL protected verifier (`protected/verify.py`) — workspace
  confinement keeps the ld arms from ever reading it, and the grok arm
  is never told it exists.

  The cold and warm arms run as obligations through the shared tuple
  space and Jido dispatcher — the demo exercises the whole Layer C
  stack, arms racing concurrently on separate channels.
  """

  alias LdHost.{Cmd, Dispatcher, Ledger, Policy, Progress, Space, Verdict}

  @default_arms ~w(grok cold warm)

  def run(task_ids, opts \\ []) do
    repo = LdHost.Critic.repo_root()
    out = Keyword.get(opts, :out, Path.join([repo, "beam", "runs", "demo-" <> stamp()]))
    arms = Keyword.get(opts, :arms, @default_arms)
    serial? = Keyword.get(opts, :serial, false)
    max_episodes = Keyword.get(opts, :max_episodes, 6)

    File.mkdir_p!(out)
    {:ok, ledger} = Ledger.start_link(Path.join(out, "orchestrator"))
    {:ok, space} = Space.start_link(record: Ledger.emitter(ledger))

    {:ok, _dispatcher} =
      Dispatcher.start_link(space: space, ledger: ledger, run_opts: [max_episodes: max_episodes])

    tasks = Enum.map(task_ids, &load_task(repo, &1))

    runner = fn arm ->
      results = run_arm(arm, tasks, %{out: out, space: space, ledger: ledger})
      {arm, results}
    end

    results =
      if serial? do
        Map.new(arms, runner)
      else
        arms
        |> Enum.map(&Task.async(fn -> runner.(&1) end))
        |> Enum.map(&Task.await(&1, :infinity))
        |> Map.new()
      end

    summarize(out, ledger, tasks, results)
  end

  # ---- tasks ------------------------------------------------------------

  defp load_task(repo, id) do
    dir = Path.join([repo, "eval", "tasks", id])
    toml = File.read!(Path.join(dir, "task.toml"))
    verify = Path.join([dir, "protected", "verify.py"])

    check =
      ~s{out=$(python3 "#{verify}" "$PWD") && echo "$out" | grep -q '"checks"' && } <>
        ~s{! echo "$out" | grep -q '"passed": false'}

    %{
      id: id,
      dir: dir,
      family: toml_value(toml, "family") || "default",
      sequence: String.to_integer(toml_value(toml, "sequence") || "0"),
      goal: File.read!(Path.join(dir, "prompt.md")),
      allowed_globs: toml_list(toml, "allowed_globs"),
      forbidden_globs: toml_list(toml, "forbidden_globs"),
      contract: %{
        "claims" => [
          %{"id" => "hidden-verifier", "kind" => "check", "command" => check, "timeout_seconds" => 120}
        ]
      }
    }
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

  defp seed_workspace(out, arm, task) do
    ws = Path.join([out, arm, task.id, "ws"])
    File.mkdir_p!(Path.dirname(ws))
    File.cp_r!(Path.join(task.dir, "repo"), ws)
    File.write!(Path.join(ws, "TASK.md"), task.goal)
    ws
  end

  # ---- arms -------------------------------------------------------------

  defp run_arm("grok", tasks, ctx) do
    Enum.map(tasks, fn task ->
      ws = seed_workspace(ctx.out, "grok", task)
      started = System.monotonic_time(:millisecond)
      {usage, calls, exit_status} = run_grok(task.goal, ws)

      score = Cmd.sh(hd(task.contract["claims"])["command"], ws, 120_000)

      result = %{
        arm: "grok",
        task: task.id,
        success: score.returncode == 0,
        tokens: usage,
        model_calls: calls,
        wall_ms: System.monotonic_time(:millisecond) - started,
        policy_violations: policy_violation_count(ws, task),
        exit_status: exit_status
      }

      Ledger.trace(ctx.ledger, "demo.arm_result", result)
      result
    end)
  end

  defp run_arm(arm, tasks, ctx) when arm in ["cold", "warm"] do
    shared_dict = Path.join([ctx.out, "warm-dict"])

    tasks
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map(fn task ->
      ws = seed_workspace(ctx.out, arm, task)
      ob_id = "#{arm}-#{task.id}"
      Progress.subscribe({:obligation, ob_id})
      started = System.monotonic_time(:millisecond)

      obligation = %{
        "kind" => "obligation",
        "id" => ob_id,
        "goal" => task.goal,
        "workspace" => ws,
        "contract" => task.contract
      }

      obligation =
        if arm == "warm", do: Map.put(obligation, "dictionary", shared_dict), else: obligation

      {:ok, _} = Space.out(ctx.space, obligation)

      summary = await_obligation(ob_id)

      result = %{
        arm: arm,
        task: task.id,
        success: summary != nil and summary.success,
        tokens: (summary && summary.tokens) || %{input_tokens: 0, output_tokens: 0},
        model_calls: (summary && summary.model_calls) || 0,
        wall_ms: System.monotonic_time(:millisecond) - started,
        policy_violations: policy_violation_count(ws, task),
        run_dir: summary && summary.run_dir
      }

      Ledger.trace(ctx.ledger, "demo.arm_result", result)
      result
    end)
  end

  defp await_obligation(ob_id) do
    receive do
      {:ld_progress, {:obligation, ^ob_id}, {status, summary}} when status in [:completed, :failed] ->
        summary

      {:ld_progress, {:obligation, ^ob_id}, :crashed} ->
        nil

      {:ld_progress, {:obligation, ^ob_id}, _other} ->
        await_obligation(ob_id)
    after
      600_000 -> nil
    end
  end

  defp run_grok(goal, ws) do
    grok = System.find_executable("grok") || Path.expand("~/.grok/bin/grok")

    port =
      Port.open({:spawn_executable, grok}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["-p", goal, "--cwd", ws, "--output-format", "json", "--always-approve", "--max-turns", "6"]
      ])

    {output, exit_status} = drain(port, [])

    case last_json(output) do
      %{"usage" => usage} = blob ->
        {%{
           input_tokens: usage["input_tokens"] || usage["prompt_tokens"] || 0,
           output_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0
         }, blob["num_turns"] || blob["numTurns"] || 0, exit_status}

      _ ->
        {%{input_tokens: 0, output_tokens: 0}, 0, exit_status}
    end
  end

  defp drain(port, acc) do
    receive do
      {^port, {:data, chunk}} -> drain(port, [acc, chunk])
      {^port, {:exit_status, code}} -> {IO.iodata_to_binary(acc), code}
    after
      900_000 ->
        {IO.iodata_to_binary(acc), nil}
    end
  end

  defp last_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      case JSON.decode(String.trim(line)) do
        {:ok, %{} = blob} -> blob
        _ -> nil
      end
    end)
  end

  defp policy_violation_count(ws, task) do
    baseline = Path.join(task.dir, "repo") |> Policy.snapshot()
    now = Policy.snapshot(ws)

    Policy.changed_files(baseline, now)
    |> Enum.reject(&(&1 == "TASK.md"))
    |> Enum.count(fn rel ->
      Policy.matches_any?(rel, task.forbidden_globs) or
        not Policy.matches_any?(rel, task.allowed_globs)
    end)
  end

  # ---- summary ----------------------------------------------------------

  defp summarize(out, ledger, tasks, results) do
    cold = results["cold"] || []
    warm = results["warm"] || []

    verdict =
      if cold != [] and warm != [] do
        measures = Verdict.measures(cold, warm)
        {allowed, reasons} = Verdict.warm_run_allowed(measures)
        %{measures: measures, allowed: allowed, reasons: reasons}
      end

    summary = %{tasks: Enum.map(tasks, & &1.id), results: results, verdict: verdict}
    File.write!(Path.join(out, "summary.json"), JSON.encode!(summary))
    File.write!(Path.join(out, "summary.md"), render_markdown(tasks, results, verdict))

    if verdict, do: Ledger.trace(ledger, "demo.verdict", verdict)

    Map.put(summary, :out, out)
  end

  defp render_markdown(tasks, results, verdict) do
    header = "| arm | " <> Enum.map_join(tasks, " | ", & &1.id) <> " | tokens (in/out) | model calls |\n"
    divider = "|---|" <> String.duplicate("---|", length(tasks) + 2) <> "\n"

    rows =
      Enum.map_join(results, "", fn {arm, arm_results} ->
        by_task = Map.new(arm_results, &{&1.task, &1})

        cells =
          Enum.map_join(tasks, " | ", fn task ->
            case by_task[task.id] do
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

    verdict_md =
      case verdict do
        nil ->
          "\n_No cold/warm pair — verdict not computed._\n"

        %{measures: m, allowed: allowed, reasons: reasons} ->
          """

          ## Preregistered warm-dictionary verdict

          - success delta: #{Float.round(m.success_delta_points * 1.0, 1)} points
          - token reduction: #{Float.round(m.token_reduction_fraction * 100.0, 1)}%
          - policy violations increased: #{m.policy_violations_increased}
          - negative transfer: #{m.negative_transfer}

          **#{if allowed, do: "GO — warm dictionary passes the preregistered thresholds", else: "NO-GO"}**#{if reasons != [], do: "\n\nReasons: " <> Enum.join(reasons, "; "), else: ""}
          """
      end

    "# Arms race: same goals, hidden judge\n\n" <> header <> divider <> rows <> verdict_md
  end

  defp stamp, do: DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
end
