defmodule LdHost.Obligation do
  @moduledoc """
  Obligations are the Layer C unit of work: `{kind: "obligation", id,
  goal, workspace, contract?, dictionary?, limits?}` tuples in the
  space. Each taken obligation becomes a Jido agent executing the
  Phase 2 kernel loop in-process — no child protocol, no second runtime.

  A tuple with `hold_ms` skips the planner loop: the model is off, the
  lease stays live, and `Cmd.sh(probe)` is the only work. Worker crash
  or lease loss may expire for retake. A deterministic probe failure is
  a completed negative result; an optional `max_attempts`/`backoff_ms`
  policy retries inside the same hold, then terminates. Probe failure
  must not expire-and-retake (that is a hot loop, not liveness).
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

    defp contract_of(%{"contract" => %{"claims" => claims}}),
      do: %{claims: claims, source: "obligation"}

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
  @max_attempts_cap 100

  @doc """
  Execute one claimed obligation under a Jido agent, heart-beating the
  space lease while it runs. Returns `{:completed | :failed, summary}`.

  A tuple with `hold_ms` skips the planner loop.
  """
  def execute(space, claim, run_opts \\ []) do
    heartbeat = start_heartbeat(space, claim)

    try do
      case hold_ms(claim.tuple) do
        ms when is_integer(ms) ->
          hold(claim.tuple["workspace"], claim.tuple["probe"], ms, retry_opts(claim.tuple))

        nil ->
          run_goal(claim.tuple, run_opts)
      end
    after
      stop_heartbeat(heartbeat)
    end
  end

  @doc """
  Loop `Cmd.sh(probe)` until `hold_ms` elapses or the probe is
  terminally failed. Zero planner calls. Bounded `max_attempts` with
  backoff apply only to consecutive probe failures.
  """
  def hold(workspace, probe, hold_ms, opts \\ [])

  def hold(workspace, probe, hold_ms, opts) when is_integer(hold_ms) and hold_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + hold_ms
    command = probe_command(probe)
    timeout_ms = probe_timeout_ms(probe)
    max_attempts = max_attempts(opts)
    backoff_ms = backoff_ms(opts)

    hold_loop(%{
      workspace: workspace,
      command: command,
      timeout_ms: timeout_ms,
      deadline: deadline,
      hold_ms: hold_ms,
      probes: 0,
      last: nil,
      consecutive_fails: 0,
      max_attempts: max_attempts,
      backoff_ms: backoff_ms,
      attempt_log: []
    })
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

  defp retry_opts(tuple) when is_map(tuple) do
    retry = tuple["retry"] || %{}

    [
      max_attempts: tuple["max_attempts"] || retry["max_attempts"],
      backoff_ms: tuple["backoff_ms"] || retry["backoff_ms"]
    ]
  end

  defp max_attempts(opts) do
    raw = Keyword.get(opts, :max_attempts, 1)

    cond do
      is_integer(raw) and raw >= 1 -> min(raw, @max_attempts_cap)
      true -> 1
    end
  end

  defp backoff_ms(opts) do
    raw = Keyword.get(opts, :backoff_ms, 50)

    cond do
      is_integer(raw) and raw >= 0 -> raw
      true -> 50
    end
  end

  defp probe_command(%{"command" => cmd}) when is_binary(cmd) do
    case String.trim(cmd) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp probe_command(_), do: nil

  defp probe_timeout_ms(%{"timeout_seconds" => s}) when is_integer(s) and s > 0, do: s * 1000
  defp probe_timeout_ms(_), do: 60_000

  defp hold_loop(state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)

    cond do
      state.command == nil ->
        {:failed, Map.put(hold_summary(state, false), :probe_failed, true)}

      remaining <= 0 ->
        deadline_outcome(state)

      true ->
        result =
          LdHost.Cmd.sh(state.command, state.workspace, min(state.timeout_ms, max(remaining, 1)))

        probes = state.probes + 1
        attempt_log = state.attempt_log ++ [probe_attempt(probes, result)]
        state = %{state | probes: probes, last: result, attempt_log: attempt_log}

        if result.returncode == 0 and not result.timed_out do
          remaining = state.deadline - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            {:completed, hold_summary(state, true)}
          else
            Process.sleep(min(@probe_interval_ms, remaining))
            hold_loop(%{state | consecutive_fails: 0})
          end
        else
          fails = state.consecutive_fails + 1
          state = %{state | consecutive_fails: fails}

          if fails >= state.max_attempts do
            {:failed, Map.put(hold_summary(state, false), :probe_failed, true)}
          else
            remaining = state.deadline - System.monotonic_time(:millisecond)

            if remaining <= 0 do
              {:failed, Map.put(hold_summary(state, false), :probe_failed, true)}
            else
              sleep_ms = min(state.backoff_ms * fails, remaining)
              if sleep_ms > 0, do: Process.sleep(sleep_ms)
              hold_loop(state)
            end
          end
        end
    end
  end

  defp deadline_outcome(state) do
    if failed_last_probe?(state.last) do
      {:failed, Map.put(hold_summary(state, false), :probe_failed, true)}
    else
      {:completed, hold_summary(state, true)}
    end
  end

  defp failed_last_probe?(%{returncode: 0, timed_out: false}), do: false
  defp failed_last_probe?(%{timed_out: true}), do: true
  defp failed_last_probe?(%{returncode: code}) when code != 0, do: true
  defp failed_last_probe?(_), do: false

  defp probe_attempt(n, result) do
    %{
      n: n,
      at_ms: System.monotonic_time(:millisecond),
      returncode: result.returncode,
      timed_out: result.timed_out
    }
  end

  defp hold_summary(state, success) do
    %{
      success: success,
      episodes: 0,
      report: nil,
      judge: "hold",
      tokens: %{input_tokens: 0, output_tokens: 0},
      model_calls: 0,
      promoted_words: [],
      run_dir: nil,
      hold_ms: state.hold_ms,
      probes: state.probes,
      last_probe: state.last,
      max_attempts: state.max_attempts,
      backoff_ms: state.backoff_ms,
      consecutive_fails: state.consecutive_fails,
      attempt_log: state.attempt_log
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
