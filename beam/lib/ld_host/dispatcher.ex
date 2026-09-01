defmodule LdHost.Dispatcher do
  @moduledoc """
  Takes obligations from the space and runs each under a supervised
  task wrapping a Jido obligation agent.

  - Deny-by-default gate before any work: an obligation with no goal or
    a workspace that is not an existing directory is refused (acked and
    recorded — a denied obligation must not loop forever). The gate
    never widens scope: the run's own Host confines every write to the
    obligation's workspace regardless of what the tuple asks for.
  - Success or terminal failure (including a completed negative probe
    result) acks the lease. Bounded probe retries happen inside the
    hold, never by expire-and-retake.
  - A crashed run or lost lease expires immediately — the tuple returns
    to the bag so a sibling can retake. Stale tokens cannot ack.
  - Lifecycle lands in the orchestrator ledger (trace shape), never in
    any run's events.jsonl: run dirs stay run-owned, the single-writer
    rule never crosses processes.
  """

  use GenServer

  alias LdHost.{Obligation, Progress, Space}

  @lease_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Block until `count` obligations have finished (for tests/demos)."
  def await_idle(dispatcher, timeout \\ :infinity),
    do: GenServer.call(dispatcher, :await_idle, timeout)

  @impl true
  def init(opts) do
    space = Keyword.fetch!(opts, :space)
    ledger = Keyword.fetch!(opts, :ledger)
    worker_id = Keyword.get(opts, :worker_id, "dispatcher-#{node()}")

    state = %{
      space: space,
      ledger: ledger,
      worker_id: worker_id,
      run_opts: Keyword.get(opts, :run_opts, []),
      running: %{},
      idle_waiters: []
    }

    {:ok, spawn_taker(state)}
  end

  defp spawn_taker(state) do
    parent = self()
    space = state.space
    worker_id = state.worker_id

    taker =
      spawn_link(fn ->
        claim =
          Space.take(space, %{"kind" => "obligation"}, @lease_ms, worker_id, timeout: :infinity)

        send(parent, {:claimed, claim})
      end)

    Map.put(state, :taker, taker)
  end

  @impl true
  def handle_info({:claimed, claim}, state) do
    state = handle_claim(state, claim)
    {:noreply, spawn_taker(state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, {:done, result})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, finish(state, ref, {:crashed, reason})}
  end

  @impl true
  def handle_call(:await_idle, from, state) do
    if map_size(state.running) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | idle_waiters: [from | state.idle_waiters]}}
    end
  end

  defp handle_claim(state, claim) do
    ob = claim.tuple
    ob_id = ob["id"] || claim.tuple_id

    case deny_reason(ob) do
      reason when is_binary(reason) ->
        Space.ack(state.space, claim.token)
        record(state, "obligation.denied", %{id: ob_id, reason: reason})
        state

      nil ->
        record(state, "obligation.spawned", %{
          id: ob_id,
          goal: ob["goal"],
          workspace: ob["workspace"]
        })

        Progress.broadcast({:obligation, ob_id}, :spawned)

        task =
          Task.Supervisor.async_nolink(LdHost.ObligationTaskSup, fn ->
            Obligation.execute(state.space, claim, state.run_opts)
          end)

        put_in(state.running[task.ref], %{claim: claim, id: ob_id, pid: task.pid})
    end
  end

  defp deny_reason(ob) do
    cond do
      not is_binary(ob["goal"]) or String.trim(ob["goal"] || "") == "" ->
        "obligation has no goal"

      not is_binary(ob["workspace"]) or not File.dir?(ob["workspace"]) ->
        "workspace is not an existing directory: #{inspect(ob["workspace"])}"

      true ->
        nil
    end
  end

  defp finish(state, ref, outcome) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        state

      {%{claim: claim, id: ob_id}, running} ->
        state =
          case outcome do
            {:done, {status, summary}} ->
              Space.ack(state.space, claim.token)
              record(state, "obligation.#{status}", trace_data(ob_id, summary))
              Progress.broadcast({:obligation, ob_id}, {status, summary})
              state

            {:crashed, reason} ->
              Space.expire(state.space, claim.token)
              record(state, "obligation.crashed", %{id: ob_id, reason: inspect(reason, limit: 5)})
              Progress.broadcast({:obligation, ob_id}, :crashed)
              state
          end

        state = %{state | running: running}

        if map_size(running) == 0 do
          Enum.each(state.idle_waiters, &GenServer.reply(&1, :ok))
          %{state | idle_waiters: []}
        else
          state
        end
    end
  end

  defp record(state, type, data), do: LdHost.Ledger.trace(state.ledger, type, data)

  defp trace_data(ob_id, summary) do
    %{
      id: ob_id,
      success: Map.get(summary, :success),
      episodes: Map.get(summary, :episodes),
      judge: Map.get(summary, :judge),
      tokens: Map.get(summary, :tokens),
      run_dir: Map.get(summary, :run_dir)
    }
    |> maybe_put(:hold_ms, Map.get(summary, :hold_ms))
    |> maybe_put(:probes, Map.get(summary, :probes))
    |> maybe_put(:last_probe, Map.get(summary, :last_probe))
    |> maybe_put(:max_attempts, Map.get(summary, :max_attempts))
    |> maybe_put(:backoff_ms, Map.get(summary, :backoff_ms))
    |> maybe_put(:probe_failed, Map.get(summary, :probe_failed))
    |> maybe_put(:attempt_log, Map.get(summary, :attempt_log))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
