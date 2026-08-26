defmodule LdHost.Space do
  @moduledoc """
  Linda tuple space, Layer C native: the BEAM port of
  `harness/src/livingdict/space.py` — same semantics, OTP mechanics.

  - out/rd/take/renew/ack/expire with generation-fenced lease tokens.
    A claim bumps the tuple's generation; a stale token can never ack.
  - Subset matching with strict typing (integer 1 never matches 1.0 or
    "1"; lists exact; nested maps recurse). Waiter handoff is ordered by
    (-specificity, arrival): the most specific pattern wins, FIFO breaks
    ties. Assignment IS the claim (a BEAM waiter cannot wake and
    decline); dead waiters are dropped via monitors.
  - OTP timers replace the reference's lazy reap: each lease schedules
    `{:lease_expired, token, timer_ref}`; a renew installs a new timer
    and the handler ignores stale refs. Expiry returns the tuple to the
    bag and records `space.lease_expired`.
  - Accepts `kind: "obligation"` — the Layer C kind the in-process
    Python space refuses by design — alongside the Layer B kinds.
  - Every out/take/lease_expired/ack is recorded through the `record`
    closure with the reference payload shape; determinism lives in the
    ledger, liveness lives here.
  """

  use GenServer

  @allowed_kinds ~w(node.ready gate.result critic.reject obligation)

  defmodule Claim do
    @enforce_keys [:token, :generation, :worker_id, :tuple, :tuple_id]
    defstruct [:token, :generation, :worker_id, :tuple, :tuple_id, :lease_ms]
  end

  # ---- client -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def out(space, tuple), do: GenServer.call(space, {:out, tuple})

  @doc "Non-destructive read; nil when nothing matches (no blocking)."
  def rd(space, pattern), do: GenServer.call(space, {:rd, pattern})

  @doc """
  Atomic take with lease. `timeout: :infinity` blocks until a match;
  `timeout: 0` is non-blocking. Returns %Claim{} or nil.
  """
  def take(space, pattern, lease_ms, worker_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 0)
    call_timeout = if timeout == :infinity, do: :infinity, else: timeout + 5_000
    GenServer.call(space, {:take, pattern, lease_ms, worker_id, timeout}, call_timeout)
  end

  def renew(space, token, lease_ms \\ nil), do: GenServer.call(space, {:renew, token, lease_ms})
  def ack(space, token), do: GenServer.call(space, {:ack, token})
  def expire(space, token), do: GenServer.call(space, {:expire, token})
  def bag_size(space), do: GenServer.call(space, :bag_size)
  def leased_count(space), do: GenServer.call(space, :leased_count)
  def waiter_count(space), do: GenServer.call(space, :waiter_count)

  # ---- matching (pure) --------------------------------------------------

  @doc "Dict-subset match: pattern keys must exist and match exactly; nested maps recurse."
  def subset_match(pattern, data) when is_map(pattern) and is_map(data) do
    Enum.all?(pattern, fn {key, want} ->
      case Map.fetch(data, key) do
        {:ok, got} -> exact(want, got)
        :error -> false
      end
    end)
  end

  def subset_match(_, _), do: false

  defp exact(want, got) when is_map(want) and is_map(got), do: subset_match(want, got)

  defp exact(want, got) when is_list(want) and is_list(got) do
    length(want) == length(got) and Enum.zip(want, got) |> Enum.all?(fn {w, g} -> exact(w, g) end)
  end

  defp exact(want, got), do: want === got

  @doc "Recursive key count — pattern specificity for waiter ordering."
  def specificity(pattern) when is_map(pattern) do
    Enum.reduce(pattern, 0, fn {_k, v}, acc -> acc + 1 + nested(v) end)
  end

  defp nested(v) when is_map(v), do: specificity(v)
  defp nested(_), do: 0

  # ---- server -----------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       record: Keyword.get(opts, :record, fn _kind, _payload -> :ok end),
       bag: :gb_trees.empty(),
       seq: 0,
       next_id: 1,
       leases: %{},
       waiters: [],
       waiter_seq: 0
     }}
  end

  @impl true
  def handle_call({:out, tuple}, _from, state) do
    kind = tuple["kind"] || tuple[:kind]

    cond do
      not is_map(tuple) ->
        {:reply, {:error, "tuple must be a map"}, state}

      kind != nil and to_string(kind) not in @allowed_kinds ->
        {:reply, {:error, "unknown tuple kind: #{kind}"}, state}

      true ->
        tuple_id = "t#{state.next_id}"
        entry = %{tuple_id: tuple_id, tuple: tuple, generation: 0}
        state = %{state | next_id: state.next_id + 1, seq: state.seq + 1}
        state = %{state | bag: :gb_trees.insert(state.seq, entry, state.bag)}

        record(state, "space.out", %{
          worker: "host",
          tuple_id: tuple_id,
          generation: 0,
          lease_s: 0,
          pattern_or_tuple: tuple,
          node: tuple["node"]
        })

        {:reply, {:ok, tuple_id}, handoff(state)}
    end
  end

  def handle_call({:rd, pattern}, _from, state) do
    reply =
      case find_oldest(state.bag, pattern) do
        {:ok, _key, entry} -> entry.tuple
        :none -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:take, pattern, lease_ms, worker_id, timeout}, from, state) do
    case find_oldest(state.bag, pattern) do
      {:ok, key, entry} ->
        {claim, state} = claim_entry(state, key, entry, pattern, lease_ms, worker_id)
        {:reply, claim, state}

      :none when timeout == 0 ->
        {:reply, nil, state}

      :none ->
        {caller, _tag} = from
        monitor = Process.monitor(caller)
        waiter_seq = state.waiter_seq + 1

        timer =
          if timeout == :infinity do
            nil
          else
            Process.send_after(self(), {:waiter_timeout, waiter_seq}, timeout)
          end

        waiter = %{
          pattern: pattern,
          lease_ms: lease_ms,
          worker_id: worker_id,
          from: from,
          seq: waiter_seq,
          monitor: monitor,
          timer: timer
        }

        {:noreply, %{state | waiters: state.waiters ++ [waiter], waiter_seq: waiter_seq}}
    end
  end

  def handle_call({:renew, token, lease_ms}, _from, state) do
    case Map.fetch(state.leases, token) do
      :error ->
        {:reply, false, state}

      {:ok, lease} ->
        Process.cancel_timer(lease.timer)
        ms = lease_ms || lease.lease_ms
        ref = make_ref()
        timer = Process.send_after(self(), {:lease_expired, token, ref}, ms)
        lease = %{lease | timer: timer, timer_ref: ref, lease_ms: ms}
        {:reply, true, %{state | leases: Map.put(state.leases, token, lease)}}
    end
  end

  def handle_call({:ack, token}, _from, state) do
    case Map.pop(state.leases, token) do
      {nil, _} ->
        {:reply, false, state}

      {lease, leases} ->
        Process.cancel_timer(lease.timer)

        record(state, "space.ack", %{
          worker: lease.worker_id,
          tuple_id: lease.entry.tuple_id,
          generation: lease.entry.generation,
          lease_s: lease.lease_ms / 1000,
          pattern_or_tuple: lease.entry.tuple,
          node: lease.entry.tuple["node"]
        })

        {:reply, true, %{state | leases: leases}}
    end
  end

  def handle_call({:expire, token}, _from, state) do
    case Map.fetch(state.leases, token) do
      :error ->
        {:reply, false, state}

      {:ok, lease} ->
        Process.cancel_timer(lease.timer)
        {:reply, true, expire_lease(state, token, lease)}
    end
  end

  def handle_call(:bag_size, _from, state), do: {:reply, :gb_trees.size(state.bag), state}
  def handle_call(:leased_count, _from, state), do: {:reply, map_size(state.leases), state}
  def handle_call(:waiter_count, _from, state), do: {:reply, length(state.waiters), state}

  @impl true
  def handle_info({:lease_expired, token, ref}, state) do
    case Map.fetch(state.leases, token) do
      {:ok, %{timer_ref: ^ref} = lease} -> {:noreply, expire_lease(state, token, lease)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:waiter_timeout, waiter_seq}, state) do
    case Enum.split_with(state.waiters, &(&1.seq == waiter_seq)) do
      {[waiter], rest} ->
        Process.demonitor(waiter.monitor, [:flush])
        GenServer.reply(waiter.from, nil)
        {:noreply, %{state | waiters: rest}}

      {[], _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {dead, rest} = Enum.split_with(state.waiters, &(&1.monitor == monitor))
    Enum.each(dead, fn w -> if w.timer, do: Process.cancel_timer(w.timer) end)
    {:noreply, %{state | waiters: rest}}
  end

  # ---- internals --------------------------------------------------------

  defp claim_entry(state, key, entry, pattern, lease_ms, worker_id) do
    generation = entry.generation + 1
    entry = %{entry | generation: generation}
    token = "#{entry.tuple_id}:#{generation}:#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    ref = make_ref()
    timer = Process.send_after(self(), {:lease_expired, token, ref}, lease_ms)

    lease = %{
      entry: entry,
      bag_key: key,
      worker_id: worker_id,
      lease_ms: lease_ms,
      timer: timer,
      timer_ref: ref
    }

    record(state, "space.take", %{
      worker: worker_id,
      tuple_id: entry.tuple_id,
      generation: generation,
      lease_s: lease_ms / 1000,
      pattern_or_tuple: pattern,
      node: entry.tuple["node"]
    })

    claim = %Claim{
      token: token,
      generation: generation,
      worker_id: worker_id,
      tuple: entry.tuple,
      tuple_id: entry.tuple_id,
      lease_ms: lease_ms
    }

    state = %{
      state
      | bag: :gb_trees.delete(key, state.bag),
        leases: Map.put(state.leases, token, lease)
    }

    {claim, state}
  end

  defp expire_lease(state, token, lease) do
    state = %{state | leases: Map.delete(state.leases, token)}
    state = %{state | seq: state.seq + 1}
    state = %{state | bag: :gb_trees.insert(state.seq, lease.entry, state.bag)}

    record(state, "space.lease_expired", %{
      worker: lease.worker_id,
      tuple_id: lease.entry.tuple_id,
      generation: lease.entry.generation,
      lease_s: lease.lease_ms / 1000,
      pattern_or_tuple: lease.entry.tuple,
      node: lease.entry.tuple["node"]
    })

    handoff(state)
  end

  # Most specific pattern first, FIFO among equals; assignment is the claim.
  defp handoff(%{waiters: []} = state), do: state

  defp handoff(state) do
    ordered = Enum.sort_by(state.waiters, fn w -> {-specificity(w.pattern), w.seq} end)

    {state, served} =
      Enum.reduce(ordered, {state, []}, fn waiter, {state, served} ->
        case find_oldest(state.bag, waiter.pattern) do
          {:ok, key, entry} ->
            {claim, state} =
              claim_entry(state, key, entry, waiter.pattern, waiter.lease_ms, waiter.worker_id)

            Process.demonitor(waiter.monitor, [:flush])
            if waiter.timer, do: Process.cancel_timer(waiter.timer)
            GenServer.reply(waiter.from, claim)
            {state, [waiter.seq | served]}

          :none ->
            {state, served}
        end
      end)

    %{state | waiters: Enum.reject(state.waiters, &(&1.seq in served))}
  end

  defp find_oldest(bag, pattern) do
    bag
    |> :gb_trees.iterator()
    |> iterate(pattern)
  end

  defp iterate(iter, pattern) do
    case :gb_trees.next(iter) do
      :none ->
        :none

      {key, entry, rest} ->
        if subset_match(pattern, entry.tuple), do: {:ok, key, entry}, else: iterate(rest, pattern)
    end
  end

  defp record(%{record: record}, kind, payload), do: record.(kind, payload)
end
