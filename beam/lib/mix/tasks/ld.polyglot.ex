defmodule Mix.Tasks.Ld.Polyglot do
  @shortdoc "Race cold / warm (and optional grok) arms on Aider polyglot exercises"
  @moduledoc """
      mix ld.polyglot --langs rust,go,cpp [--arms cold,warm]
                      [--sample N] [--grok-sample N]
                      [--max-episodes 4] [--out DIR] [--bench-root DIR]

  Runs each arm over the alphabetical exercise sequence of every listed
  language track from a checkout of Aider-AI/polyglot-benchmark
  (default `~/projects/polyglot-benchmark`), scoring each workspace with
  the language's offline-guarded test command as a hidden contract, and
  computes the preregistered warm-dictionary go/no-go per track.

  - `--sample N` limits every track to its first N exercises.
  - `--grok-sample N` runs the grok baseline (when `grok` is in
    `--arms`) only on the first N exercises of each track.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          langs: :string,
          arms: :string,
          sample: :integer,
          grok_sample: :integer,
          max_episodes: :integer,
          out: :string,
          bench_root: :string,
          ooda: :string,
          reasoning_effort: :string
        ]
      )

    langs =
      (opts[:langs] || Mix.raise("--langs is required, e.g. --langs rust,go,cpp"))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    poly_opts =
      []
      |> maybe(:arms, opts[:arms] && String.split(opts[:arms], ",", trim: true))
      |> maybe(:sample, opts[:sample])
      |> maybe(:grok_sample, opts[:grok_sample])
      |> maybe(:max_episodes, opts[:max_episodes])
      |> maybe(:out, opts[:out])
      |> maybe(:bench_root, opts[:bench_root])
      |> maybe(:ooda_mode, opts[:ooda])
      |> maybe(:reasoning_effort, opts[:reasoning_effort])

    summary = LdHost.Bench.Polyglot.run(langs, poly_opts)

    IO.puts("")
    IO.puts(File.read!(Path.join(summary.out, "summary.md")))
    IO.puts("full results: #{summary.out}")
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
end
