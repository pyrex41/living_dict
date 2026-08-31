defmodule LdHost.Ledger do
  @moduledoc """
  Per-run append-only logs, single-writer by construction (one GenServer
  per run owns both file handles).

  - `events.jsonl` — the kernel transaction log: closed kind set,
    monotonic sequence (port of `kernel.py`'s reduce discipline: unknown
    kind refused, sequence is exactly revision+1).
  - `trace.jsonl` — unsequenced observability events
    (`{type, timestamp, data}`), same shape as the Python trace.

  `dictionary.promoted` payloads include identity fields retrieval needs:
  `effects` (in-band contract), `path_region` (literal WRITE-FILE globs
  else the episode grant), and empty `task_families` on live jobs.

  Overlay kinds are record-only. Freeze is a host fold (`LdHost.Run.freeze_of/1`),
  not a ledger State field. `dictionary.overlay.rejected` coincides with
  `critic.rejected`: emit both; one `pending_execute=false` (the existing
  critic.rejected continue). Python `EVENT_KINDS` stays frozen.
  """

  use GenServer

  @event_kinds ~w(
    episode.planned critic.accepted critic.rejected artifacts.applied
    gates.measured budget.consumed episode.blocked_duplicate
    dictionary.promoted dictionary.promotion_evidence contract.approved
    dictionary.overlay.proposed dictionary.overlay.admitted
    dictionary.overlay.rejected dictionary.narrowed dictionary.discarded
  )

  def event_kinds, do: @event_kinds

  def start_link(run_dir), do: GenServer.start_link(__MODULE__, run_dir)

  @doc "Commit a kernel event; returns {:ok, sequence} or {:error, reason}."
  def commit(ledger, kind, payload), do: GenServer.call(ledger, {:commit, kind, payload})

  @doc "Append a trace event (fire and forget)."
  def trace(ledger, type, data), do: GenServer.cast(ledger, {:trace, type, data})

  def revision(ledger), do: GenServer.call(ledger, :revision)

  @doc "An emit closure for LdHost.Host wiring."
  def emitter(ledger), do: fn type, data -> trace(ledger, type, data) end

  @impl true
  def init(run_dir) do
    File.mkdir_p!(run_dir)
    events_path = Path.join(run_dir, "events.jsonl")
    revision = existing_revision(events_path)
    events = File.open!(events_path, [:append, :utf8])
    trace = File.open!(Path.join(run_dir, "trace.jsonl"), [:append, :utf8])
    {:ok, %{events: events, trace: trace, revision: revision, run_dir: run_dir}}
  end

  defp existing_revision(path) do
    case File.read(path) do
      {:ok, bin} -> bin |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  @impl true
  def handle_call({:commit, kind, payload}, _from, state) do
    if kind in @event_kinds do
      seq = state.revision + 1
      line = JSON.encode!(%{kind: kind, payload: payload, sequence: seq})
      IO.write(state.events, line <> "\n")
      {:reply, {:ok, seq}, %{state | revision: seq}}
    else
      {:reply, {:error, "unknown event kind: #{kind}"}, state}
    end
  end

  def handle_call(:revision, _from, state), do: {:reply, state.revision, state}

  @impl true
  def handle_cast({:trace, type, data}, state) do
    payload = %{type: type, timestamp: DateTime.utc_now() |> DateTime.to_iso8601(), data: data}

    # Trace data can carry workspace-derived bytes; a bad byte must cost
    # one lossy line, never the ledger process.
    line =
      try do
        JSON.encode!(payload)
      rescue
        _ -> JSON.encode!(%{payload | data: inspect(data, limit: 50)})
      end

    IO.write(state.trace, line <> "\n")
    {:noreply, state}
  end
end
