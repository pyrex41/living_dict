defmodule LdHost.CLI do
  @moduledoc """
  Release entry point. A mix release has no Mix, so the packaged binary
  is driven through eval:

      bin/ld_host eval "LdHost.CLI.main_from_env()"

  Configuration comes from the environment:

    * `LD_GOAL_FILE` (required) — file containing the goal text
    * `LD_CWD` — task workspace (default: cwd)
    * `LD_RUN_DIR` — run ledger/artifacts directory
    * `LD_MAX_EPISODES` — episode budget (optional)
    * `LD_CONTRACT` — path to an approved claims JSON (optional)

  Prints exactly ONE JSON line with the run summary, then halts with an
  HONEST exit code: 0 iff the claims discharged, 1 otherwise. Exit-0
  wrapping for harnesses that treat non-zero as infrastructure failure
  (Harbor) is the shim's job, not ours.
  """

  def main_from_env do
    goal =
      case System.get_env("LD_GOAL_FILE") do
        nil ->
          IO.puts(:stderr, "LD_GOAL_FILE is required")
          System.halt(2)

        path ->
          File.read!(path)
      end

    {:ok, _} = Application.ensure_all_started(:ld_host)

    opts =
      run_opts(System.get_env("LD_CWD") || File.cwd!(),
        run_dir: System.get_env("LD_RUN_DIR"),
        max_episodes: parse_positive_int(System.get_env("LD_MAX_EPISODES")),
        contract: load_contract(System.get_env("LD_CONTRACT"))
      )

    result = LdHost.Run.run(goal, opts)

    IO.puts(
      JSON.encode!(%{
        success: result.success,
        judge: result.judge,
        episodes: result.episodes,
        model_calls: result.model_calls,
        tokens: result.tokens,
        engine: LdHost.Critic.engine(),
        run_dir: result.run_dir
      })
    )

    System.halt(if result.success, do: 0, else: 1)
  end

  @doc """
  Build `LdHost.Run.run/2` options from a workspace and optional extras
  (`:contract`, `:dictionary_dir`, `:max_episodes`, `:run_dir`). Shared
  by the release entry point and `mix ld.run`; nil extras are dropped.
  """
  def run_opts(workspace, extras \\ []) do
    Enum.reduce([:contract, :dictionary_dir, :max_episodes, :run_dir], [workspace: Path.expand(workspace)], fn key, opts ->
      case Keyword.get(extras, key) do
        nil -> opts
        value -> Keyword.put(opts, key, value)
      end
    end)
  end

  @doc """
  Load an approved contract from a claims JSON file: either
  `{"claims": [...]}` or a bare claims list. nil path -> nil.
  """
  def load_contract(nil), do: nil

  def load_contract(path) do
    case path |> File.read!() |> JSON.decode!() do
      %{"claims" => claims} -> %{claims: claims, source: "approved"}
      claims when is_list(claims) -> %{claims: claims, source: "approved"}
    end
  end

  defp parse_positive_int(nil), do: nil

  defp parse_positive_int(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end
end
