defmodule Mix.Tasks.Ld.Run do
  @shortdoc "Run the Living Dictionary BEAM host on a goal (headless)"
  @moduledoc """
  Headless run: exits 0 iff the contract's claims discharged.

      mix ld.run --goal "..." --cwd PATH [--contract claims.json]
                 [--spec PATH --sign]
                 [--dictionary DIR] [--max-episodes N]
                 [--allow-model-checks]

  `--contract` points at a JSON file `{"claims": [...]}` — the
  approved/hidden contract whose `check` commands judge success. Without
  it, the model's own claims are measured (checks refused) and the run
  is loudly labeled model-judged.

  `--spec` compiles a product JSON through the typed spec: claims plus
  required `globs`, `effects`, and `obligation_kinds` lists (empty is
  deny-all; missing lists are an error). Checks stay refused until
  `--sign` (compiled is not approval). Claim objects may include the
  `atomize_claim/1` fields (`any`/`must`, `min_bytes`, `timeout_seconds`,
  `depends_on`); unknown keys are rejected.

  `--allow-model-checks` (benchmark mode) lets model-authored check
  claims execute advisorily when no approved contract exists; the report
  stays labeled "model-authored claims".
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          goal: :string,
          cwd: :string,
          contract: :string,
          spec: :string,
          sign: :boolean,
          dictionary: :string,
          max_episodes: :integer,
          allow_model_checks: :boolean
        ]
      )

    goal = opts[:goal] || Mix.raise("--goal is required")

    run_opts =
      LdHost.CLI.run_opts(opts[:cwd] || File.cwd!(), spec_run_extras(opts))

    result = LdHost.Run.run(goal, run_opts)

    IO.puts("")
    IO.puts("run: #{result.run_dir}")
    IO.puts("judge: #{result.judge}")
    IO.puts("episodes: #{result.episodes}  model calls: #{result.model_calls}")
    IO.puts("tokens: in #{result.tokens.input_tokens} / out #{result.tokens.output_tokens}")
    IO.puts(if result.success, do: "SUCCESS — claims discharged", else: "FAILED — claims not discharged")

    unless result.success, do: exit({:shutdown, 1})
  end

  defp spec_run_extras(opts) do
    base = [
      contract: LdHost.CLI.load_contract(opts[:contract]),
      dictionary_dir: opts[:dictionary],
      max_episodes: opts[:max_episodes],
      allow_model_checks: opts[:allow_model_checks]
    ]

    case opts[:spec] do
      nil ->
        base

      path ->
        compiled =
          case LdHost.Spec.compile_file(path) do
            {:error, reason} -> Mix.raise(reason)
            map -> map
          end

        contract =
          if opts[:sign] do
            LdHost.Spec.sign(compiled, nil)
          else
            compiled
          end

        Keyword.merge(base,
          contract: contract,
          allowed_globs: compiled.globs,
          allowed_effects: compiled.effects
        )
    end
  end
end
