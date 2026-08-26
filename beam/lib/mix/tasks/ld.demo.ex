defmodule Mix.Tasks.Ld.Demo do
  @shortdoc "Race grok / cold / warm arms on eval tasks with a hidden judge"
  @moduledoc """
      mix ld.demo --tasks config-01,config-02 [--arms grok,cold,warm]
                  [--serial] [--max-episodes N] [--out DIR]

  Runs each arm on the same goals (vendored eval tasks), scores every
  workspace with the task's actual protected verifier, and computes the
  preregistered warm-dictionary go/no-go. Requires planner credentials
  (XAI_API_KEY or ~/.grok/auth.json) for the cold/warm arms and the
  grok CLI for the baseline arm.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [tasks: :string, arms: :string, serial: :boolean, max_episodes: :integer, out: :string]
      )

    task_ids =
      (opts[:tasks] || Mix.raise("--tasks is required, e.g. --tasks config-01,config-02"))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    demo_opts =
      []
      |> maybe(:arms, opts[:arms] && String.split(opts[:arms], ",", trim: true))
      |> maybe(:serial, opts[:serial])
      |> maybe(:max_episodes, opts[:max_episodes])
      |> maybe(:out, opts[:out])

    summary = LdHost.Demo.run(task_ids, demo_opts)

    IO.puts("")
    IO.puts(File.read!(Path.join(summary.out, "summary.md")))
    IO.puts("full results: #{summary.out}")
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
end
