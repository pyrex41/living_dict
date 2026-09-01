defmodule Mix.Tasks.Ld.PostHarvest do
  @shortdoc "Write a dry-run manifest for post-harvest dictionary campaigns"
  @moduledoc """
      mix ld.post_harvest [--repo DIR] [--out DIR] [--run-id ID]

  Writes a manifest for three isolated parser cold/warm replicates and one
  graph confirmation.  It never invokes a planner.  Rust is included only as
  a disabled, post-observation confirmation entry.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv, strict: [repo: :string, out: :string, run_id: :string])

    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    post_opts =
      []
      |> maybe(:repo, opts[:repo])
      |> maybe(:out, opts[:out])
      |> maybe(:run_id, opts[:run_id])

    {path, manifest} = LdHost.Bench.PostHarvest.write_manifest(post_opts)
    IO.puts("post-harvest manifest: #{path}")

    IO.puts(
      "planned campaigns: #{Enum.count(manifest["campaigns"], & &1["enabled"])} enabled, 1 deferred"
    )

    IO.puts("No live planner or paid campaign was run.")
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
end
