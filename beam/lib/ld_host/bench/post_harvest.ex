defmodule LdHost.Bench.PostHarvest do
  @moduledoc """
  Build a reproducible, dry-run campaign manifest for the post-harvest
  dictionary measurement.

  This deliberately does not launch a planner.  The demo/polyglot entry
  points now propagate task-level evidence when the VM executes, but rows
  from transport, critic, or trap failures intentionally omit some fields.
  A manifest is therefore the honest boundary: it fixes the campaign shape,
  paths, commands, and gates while preserving every eventual raw run.
  """

  @parser_tasks ~w(parser-01 parser-02 parser-03)
  @graph_tasks ~w(graph-01 graph-02 graph-03 graph-04 graph-05 graph-06 graph-07 graph-08)
  @parser_replicates 3
  @max_episodes 6
  @campaign_timeout_seconds 1_800
  @task_timeout_seconds 600
  @required_row_fields [
    "task",
    "arm",
    "success",
    "tokens",
    "judge",
    "catalog_before",
    "eligible_words",
    "used_words",
    "unused_eligible_words",
    "candidate_words",
    "promoted_words",
    "critic_covering_rejections"
  ]

  @doc "Return the fixed settings used by all planned campaigns."
  def settings do
    %{
      "arms" => ["cold", "warm"],
      "serial" => true,
      "max_episodes" => @max_episodes,
      "campaign_timeout_seconds" => @campaign_timeout_seconds,
      "task_timeout_seconds" => @task_timeout_seconds,
      "token_bar_fraction" => 0.25,
      "raw_runs" => "retain"
    }
  end

  @doc "Build a manifest without running any model or benchmark command."
  def manifest(opts \\ []) do
    repo = Path.expand(Keyword.get(opts, :repo, LdHost.Critic.repo_root()))
    beam_cwd = Path.join(repo, "beam")
    run_id = Keyword.get(opts, :run_id, stamp())

    out_root =
      Path.expand(Keyword.get(opts, :out, Path.join([repo, "beam", "runs", "post-harvest"])))

    run_root = Path.join(out_root, run_id)

    validate_paths!(repo, beam_cwd, run_root)

    parser =
      for replicate <- 1..@parser_replicates do
        campaign(
          "parser-r#{replicate}",
          "parser_pair",
          @parser_tasks,
          replicate,
          run_root,
          beam_cwd
        )
      end

    graph = [
      campaign("graph-confirmation", "graph_confirmation", @graph_tasks, nil, run_root, beam_cwd)
    ]

    rust = [deferred_rust_campaign(run_root, beam_cwd)]

    %{
      "schema_version" => 1,
      "kind" => "post_harvest_campaign",
      "status" => "planned",
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "repo" => repo,
      "beam_cwd" => beam_cwd,
      "run_root" => run_root,
      "source" => git_provenance(repo),
      "settings" => settings(),
      "campaigns" => parser ++ graph ++ rust,
      "blockers" => blockers()
    }
  end

  @doc "Write a manifest JSON file and return `{path, manifest}`."
  def write_manifest(opts \\ []) do
    data = manifest(opts)
    path = Path.join(data["run_root"], "manifest.json")
    File.mkdir_p!(data["run_root"])
    File.write!(path, JSON.encode!(data) <> "\n")
    {path, data}
  end

  @doc "Explain why this tool stops at planning until scoring prerequisites are validated."
  def blockers do
    [
      "Rows must be checked for complete catalog_before/eligible_words/used_words evidence; transport, critic, and trap failures may omit fields by design.",
      "The warm dictionary is shared by a run, so scoring still requires catalog-before versus actual-used comparisons and explicit trap/judge classification.",
      "Score only rows with approved/hidden contract-first judge provenance; model-authored checks are advisory and must be omitted.",
      "mix ld.polyglot has no --serial option; Rust is represented as a deferred confirmation, not an executable prerequisite.",
      "No live or paid planner invocation is performed by this manifest tool."
    ]
  end

  defp campaign(id, kind, tasks, replicate, run_root, beam_cwd) do
    out = Path.join(run_root, id)

    args = [
      "ld.demo",
      "--tasks",
      Enum.join(tasks, ","),
      "--arms",
      "cold,warm",
      "--serial",
      "--max-episodes",
      Integer.to_string(@max_episodes),
      "--out",
      out
    ]

    %{
      "id" => id,
      "kind" => kind,
      "replicate" => replicate,
      "tasks" => tasks,
      "arms" => ["cold", "warm"],
      "command" => ["mix" | args],
      "cwd" => beam_cwd,
      "out" => out,
      "timeout_seconds" => @campaign_timeout_seconds,
      "task_timeout_seconds" => @task_timeout_seconds,
      "raw_artifacts" => [
        Path.join(out, "orchestrator"),
        Path.join(out, "summary.json"),
        Path.join(out, "summary.md"),
        Path.join(out, "command.stdout.log"),
        Path.join(out, "command.stderr.log")
      ],
      "raw_run_roots" => [Path.join(out, "cold"), Path.join(out, "warm")],
      "capture" => "redirect stdout/stderr to raw command logs; never discard",
      "retention" => "retain every raw run and summary",
      "scoring_inputs" => [
        "summary.json",
        "task-level telemetry (required before scoring)",
        "approved/hidden contract-first judge provenance"
      ],
      "required_row_fields" => @required_row_fields,
      "enabled" => true
    }
  end

  defp deferred_rust_campaign(run_root, beam_cwd) do
    out = Path.join(run_root, "rust-confirmation")

    %{
      "id" => "rust-confirmation",
      "kind" => "polyglot_rust_confirmation",
      "tasks" => [],
      "arms" => ["cold", "warm"],
      "command" => [
        "mix",
        "ld.polyglot",
        "--langs",
        "rust",
        "--arms",
        "cold,warm",
        "--sample",
        "30",
        "--max-episodes",
        "4",
        "--out",
        out
      ],
      "cwd" => beam_cwd,
      "out" => out,
      "timeout_seconds" => @campaign_timeout_seconds,
      "enabled" => false,
      "gate" => "enable only after parser/graph rows show non-empty used_words",
      "raw_artifacts" => [
        Path.join(out, "summary.json"),
        Path.join(out, "summary.md"),
        Path.join(out, "command.stdout.log"),
        Path.join(out, "command.stderr.log")
      ],
      "raw_run_roots" => [Path.join(out, "cold"), Path.join(out, "warm")],
      "capture" => "redirect stdout/stderr to raw command logs; never discard",
      "retention" => "retain every raw run and summary",
      "required_row_fields" => @required_row_fields
    }
  end

  defp validate_paths!(repo, beam_cwd, run_root) do
    unless File.dir?(repo), do: raise(ArgumentError, "repo does not exist: #{repo}")
    unless File.dir?(beam_cwd), do: raise(ArgumentError, "beam cwd does not exist: #{beam_cwd}")

    if Path.expand(beam_cwd) == Path.expand(repo) do
      raise ArgumentError, "campaign cwd must not be the repository root"
    end

    if Path.expand(run_root) == Path.expand(repo) do
      raise ArgumentError, "campaign output must not be the repository root"
    end
  end

  defp git_provenance(repo) do
    with {revision, 0} <-
           System.cmd("git", ["rev-parse", "HEAD"], cd: repo, stderr_to_stdout: true),
         {diff, 0} <-
           System.cmd("git", ["diff", "--binary", "--no-ext-diff"],
             cd: repo,
             stderr_to_stdout: true
           ),
         {status, 0} <-
           System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"],
             cd: repo,
             stderr_to_stdout: true
           ) do
      payload = diff <> "\n" <> status

      %{
        "revision" => String.trim(revision),
        "dirty" => String.trim(status) != "",
        "dirty_diff_sha256" => :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      }
    else
      _ -> %{"revision" => "unknown", "dirty" => nil, "dirty_diff_sha256" => "unknown"}
    end
  end

  defp stamp do
    Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <>
      "-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
