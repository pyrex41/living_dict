defmodule Mix.Tasks.Ld.Elaborate do
  @shortdoc "Elaborate an ld-system/v1 manifest into a canonical derivation"
  @moduledoc """
  Judge an `ld-system/v1` manifest and print its derivation.

      mix ld.elaborate --manifest PATH [--out FILE]

  Exit 0 iff the manifest is accepted. The derivation (steps, failed
  judgments, obligations, hashes) is printed as JSON, or written to `--out`.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [manifest: :string, out: :string])
    path = opts[:manifest] || Mix.raise("--manifest is required")

    case LdHost.Elaborate.derive_file(path) do
      {:ok, derivation} ->
        json = JSON.encode!(derivation)
        if opts[:out], do: File.write!(opts[:out], json), else: IO.puts(json)
        if derivation["verdict"] != "accepted", do: exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("manifest rejected: #{reason}")
        exit({:shutdown, 2})
    end
  end
end
