defmodule Mix.Tasks.Ld.VerifyRuntime do
  @shortdoc "Independently verify wasm-durable-v1 evidence directories"
  @moduledoc """
  Run `LdHost.RuntimeProfiles.verify_receipt/4` over evidence directories,
  for example everything the kill matrix left under
  `spike/wasm/.livingdict-run/kill-matrix`:

      mix ld.verify_runtime --workspace ../spike/wasm --config order.machine.toml \\
          --evidence ../spike/wasm/.livingdict-run/kill-matrix

  `--evidence` may name one evidence directory (containing `receipt.json`)
  or a directory of them. Exit 0 iff every receipt verifies and every
  property it claims is re-derived from the files.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [workspace: :string, config: :string, evidence: :string])

    workspace = opts[:workspace] || Mix.raise("--workspace is required")
    config = opts[:config] || Mix.raise("--config is required")
    evidence = opts[:evidence] || Mix.raise("--evidence is required")

    dirs =
      if File.regular?(Path.join(evidence, "receipt.json")),
        do: [evidence],
        else:
          evidence
          |> File.ls!()
          |> Enum.sort()
          |> Enum.map(&Path.join(evidence, &1))
          |> Enum.filter(&File.regular?(Path.join(&1, "receipt.json")))

    if dirs == [], do: Mix.raise("no receipt.json under #{evidence}")

    results =
      Enum.map(dirs, fn dir ->
        receipt = dir |> Path.join("receipt.json") |> File.read!() |> JSON.decode!()

        case LdHost.RuntimeProfiles.verify_receipt(workspace, config, dir, receipt) do
          {:ok, props} ->
            missing = MapSet.difference(MapSet.new(receipt["properties"] || []), props)

            if MapSet.size(missing) == 0 do
              Mix.shell().info(
                "ok    #{Path.basename(dir)} #{Enum.join(Enum.sort(MapSet.to_list(props)), ",")}"
              )

              :ok
            else
              Mix.shell().error(
                "FAIL  #{Path.basename(dir)} unverified: #{Enum.join(missing, ",")}"
              )

              :error
            end

          {:error, reason} ->
            Mix.shell().error("FAIL  #{Path.basename(dir)} #{reason}")
            :error
        end
      end)

    if Enum.any?(results, &(&1 == :error)), do: exit({:shutdown, 1})
  end
end
