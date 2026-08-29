defmodule LdHost.Obligation do
  @moduledoc """
  Obligations are the Layer C unit of work: `{kind: "obligation", id,
  goal, workspace, contract?, dictionary?, limits?}` tuples in the
  space. Each taken obligation becomes a Jido agent executing the
  Phase 2 kernel loop in-process — no child protocol, no second runtime.
  """

  defmodule RunGoal do
    @moduledoc "Effectful Jido action: run the kernel loop for one obligation."

    use Jido.Action,
      name: "obligation_run_goal",
      schema: [
        # Opaque to jido: the obligation tuple is a string-keyed JSON map
        # (jido's :map type validates keys as atoms).
        obligation: [type: :any, required: true],
        run_opts: [type: {:list, :any}, default: []]
      ]

    def run(%{obligation: ob, run_opts: extra}, _context) do
      case LdHost.Dispatcher.deny_reason(ob, extra[:obligation_kinds]) do
        reason when is_binary(reason) ->
          {:error, reason}

        nil ->
          run_goal(ob, extra)
      end
    end

    defp run_goal(ob, extra) do
      goal = ob["goal"] || ""
      workspace = ob["workspace"]

      opts =
        [workspace: workspace]
        |> maybe(:contract, contract_of(ob))
        |> maybe(:dictionary_dir, ob["dictionary"])
        |> maybe(:max_episodes, get_in(ob, ["limits", "max_episodes"]))
        |> maybe(:allowed_globs, ob["allowed_globs"])
        |> maybe(:forbidden_globs, forbidden_of(ob))
        |> maybe(:allow_model_checks, ob["allow_model_checks"])
        |> Keyword.merge(extra)

      summary = LdHost.Run.run(goal, opts)
      {:ok, %{status: if(summary.success, do: :completed, else: :failed), summary: summary}}
    end

    defp contract_of(%{"contract" => %{"claims" => claims}}), do: %{claims: claims, source: "approved"}
    defp contract_of(_), do: nil

    # Task forbiddens compose with the host's bookkeeping defaults.
    defp forbidden_of(%{"forbidden_globs" => globs}) when is_list(globs),
      do: globs ++ [".livingdict-run/*", ".git/*", "node_modules/*", "dist/*"]

    defp forbidden_of(_), do: nil

    defp maybe(opts, _key, nil), do: opts
    defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
  end

  defmodule Agent do
    @moduledoc "Jido agent holding one obligation's lifecycle state."

    use Jido.Agent,
      name: "obligation",
      schema: [
        status: [type: :atom, default: :pending],
        obligation_id: [type: :string, default: ""],
        summary: [type: {:or, [:map, nil]}, default: nil]
      ]
  end

  @probe_interval_ms 100

  @doc """
  Execute one claimed obligation under a Jido agent, heart-beating the
  space lease while it runs. Returns `{:completed | :failed, summary}`.

  A tuple with `hold_ms` skips the planner loop: `hold/3` keeps the
  lease live with the model off until the window elapses or a probe fails.
  """
  def execute(space, claim, run_opts \\ []) do
    heartbeat = start_heartbeat(space, claim)

    try do
      case hold_ms(claim.tuple) do
        ms when is_integer(ms) ->
          hold(claim.tuple["workspace"], claim.tuple["probe"], ms)

        nil ->
          run_goal(claim.tuple, run_opts)
      end
    after
      stop_heartbeat(heartbeat)
    end
  end

  @doc """
  Loop `Cmd.sh(probe)` until `hold_ms` elapses or a probe fails. Zero
  planner calls. Returns `{:completed | :failed, summary}`.
  """
  def hold(workspace, probe, hold_ms) when is_integer(hold_ms) and hold_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + hold_ms
    command = probe_command(probe)
    timeout_ms = probe_timeout_ms(probe)
    hold_loop(workspace, command, timeout_ms, deadline, hold_ms, 0, nil)
  end

  defp run_goal(ob, run_opts) do
    agent = Agent.new()

    # jido_action's default exec timeout is 30s; an obligation runs a
    # whole multi-episode loop with model calls, so it gets 30 minutes.
    {agent, directives} =
      Agent.cmd(agent, {RunGoal, %{obligation: ob, run_opts: run_opts}}, timeout: 1_800_000)

    case agent.state do
      %{status: status, summary: %{} = summary} when status in [:completed, :failed] ->
        {status, summary}

      _ ->
        raise "obligation agent did not complete: #{inspect(directives, limit: 5)}"
    end
  end

  defp hold_ms(%{"hold_ms" => ms}) when is_integer(ms) and ms > 0, do: ms
  defp hold_ms(_), do: nil

  defp probe_command(%{"command" => cmd}) when is_binary(cmd) do
    case String.trim(cmd) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp probe_command(_), do: nil

  defp probe_timeout_ms(%{"timeout_seconds" => s}) when is_integer(s) and s > 0, do: s * 1000
  defp probe_timeout_ms(_), do: 60_000

  defp hold_loop(workspace, command, timeout_ms, deadline, hold_ms, probes, last) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        {:completed, hold_summary(true, hold_ms, probes, last)}

      command == nil ->
        Process.sleep(min(@probe_interval_ms, remaining))
        hold_loop(workspace, command, timeout_ms, deadline, hold_ms, probes, last)

      true ->
        result = LdHost.Cmd.sh(command, workspace, min(timeout_ms, max(remaining, 1)))
        probes = probes + 1

        if result.returncode == 0 and not result.timed_out do
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            {:completed, hold_summary(true, hold_ms, probes, result)}
          else
            Process.sleep(min(@probe_interval_ms, remaining))
            hold_loop(workspace, command, timeout_ms, deadline, hold_ms, probes, result)
          end
        else
          {:failed, hold_summary(false, hold_ms, probes, result) |> Map.put(:probe_failed, true)}
        end
    end
  end

  defp hold_summary(success, hold_ms, probes, last_probe) do
    %{
      success: success,
      episodes: 0,
      report: nil,
      judge: "hold",
      tokens: %{input_tokens: 0, output_tokens: 0},
      model_calls: 0,
      promoted_words: [],
      run_dir: nil,
      hold_ms: hold_ms,
      probes: probes,
      last_probe: last_probe
    }
  end

  defp start_heartbeat(space, claim) do
    interval = max(div(claim.lease_ms, 3), 50)

    spawn_link(fn -> heartbeat_loop(space, claim.token, interval) end)
  end

  defp heartbeat_loop(space, token, interval) do
    receive do
      :stop -> :ok
    after
      interval ->
        LdHost.Space.renew(space, token)
        heartbeat_loop(space, token, interval)
    end
  end

  defp stop_heartbeat(pid) do
    Process.unlink(pid)
    send(pid, :stop)
  end
end
