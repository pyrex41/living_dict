defmodule Mix.Tasks.Ld.Extract do
  @shortdoc "Exp A: extract installer words from successful warm traces (no planner)"
  @moduledoc """
      mix ld.extract [--in DIR] [--out DIR]

  Offline replay. Reads traces under `--in` (default
  `beam/runs/exp0-kill-switch` if present, else
  `beam/test/fixtures/extract`). Writes a synthetic dictionary and
  `receipt.json` under `--out` (default `beam/runs/extract-a`).

  Never calls the planner. Never writes `eval/`.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [in: :string, out: :string])

    beam_root = Path.expand(Path.join([__DIR__, "..", "..", ".."]))
    exp0 = Path.join([beam_root, "runs", "exp0-kill-switch"])
    fixtures = Path.join([beam_root, "test", "fixtures", "extract"])

    in_dir =
      cond do
        is_binary(opts[:in]) -> opts[:in]
        File.dir?(exp0) -> exp0
        true -> fixtures
      end

    out_dir = opts[:out] || Path.join([beam_root, "runs", "extract-a"])

    receipt = LdHost.Extract.replay(in_dir, out_dir)
    IO.puts(JSON.encode!(receipt))
    IO.puts("receipt: #{Path.join(Path.expand(out_dir), "receipt.json")}")
  end
end
