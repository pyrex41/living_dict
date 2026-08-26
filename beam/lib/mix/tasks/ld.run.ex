defmodule Mix.Tasks.Ld.Run do
  @shortdoc "Run the Living Dictionary BEAM host on a goal (headless)"
  @moduledoc """
  Headless run: exits 0 iff the contract's claims discharged.

      mix ld.run --goal "..." --cwd PATH [--contract claims.json]
                 [--dictionary DIR] [--max-episodes N]

  `--contract` points at a JSON file `{"claims": [...]}` — the
  approved/hidden contract whose `check` commands judge success. Without
  it, the model's own claims are measured (checks refused) and the run
  is loudly labeled model-judged.
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
          dictionary: :string,
          max_episodes: :integer
        ]
      )

    goal = opts[:goal] || Mix.raise("--goal is required")
    cwd = Path.expand(opts[:cwd] || File.cwd!())

    run_opts =
      [workspace: cwd]
      |> maybe(:contract, load_contract(opts[:contract]))
      |> maybe(:dictionary_dir, opts[:dictionary])
      |> maybe(:max_episodes, opts[:max_episodes])

    result = LdHost.Run.run(goal, run_opts)

    IO.puts("")
    IO.puts("run: #{result.run_dir}")
    IO.puts("judge: #{result.judge}")
    IO.puts("episodes: #{result.episodes}  model calls: #{result.model_calls}")
    IO.puts("tokens: in #{result.tokens.input_tokens} / out #{result.tokens.output_tokens}")
    IO.puts(if result.success, do: "SUCCESS — claims discharged", else: "FAILED — claims not discharged")

    unless result.success, do: exit({:shutdown, 1})
  end

  defp load_contract(nil), do: nil

  defp load_contract(path) do
    case path |> File.read!() |> JSON.decode!() do
      %{"claims" => claims} -> %{claims: claims, source: "approved"}
      claims when is_list(claims) -> %{claims: claims, source: "approved"}
    end
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
end
