defmodule Mix.Tasks.Ld.Exp0 do
  @shortdoc "Exp 0: grant+path retrieved vs load-all over mixed-family warm"
  @moduledoc """
      mix ld.exp0 [--eval-root PATH] [--out DIR] [--max-episodes N] [--reps 3]
                  [--discover]

  Reads vendored `eval/tasks` (never writes eval/). Warms the union of
  sequences 1–7 across families, then scores every `*-08` under
  `LD_DICT_MODE=load-all` vs `retrieved`. Same planner (`LdHost.Planner`).

  `--discover` prints task ids and exits. The compare receipt is for a
  human; this task does not flip the default `LD_DICT_MODE=load-all`.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    LdHost.Bench.Exp0.main(argv)
  end
end
