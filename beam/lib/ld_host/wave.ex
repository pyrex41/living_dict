defmodule LdHost.Wave do
  @moduledoc """
  Kahn-level waves for independent artifact nodes. Linda (`Space`) is the
  executor; overlapping writes are refused before any node I/O. Serial
  (`workers: 1`) and waved runs merge in lexicographic node-id order so
  final trees and receipts hash equal.
  """

  alias LdHost.{Forth, Host, Policy, Space}

  @metric_keys [
    :wave_count,
    :max_wave_width,
    :nodes_parallel,
    :conflicts,
    :wall_ms_serial_estimate,
    :wall_ms_actual
  ]

  def synthesize(artifacts) when is_map(artifacts) do
    artifacts
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key ->
      %{id: key, writes: [key], depends_on: [], program: ""}
    end)
  end

  def write_globs(%{writes: writes}) when is_list(writes) and writes != [], do: writes
  def write_globs(_), do: []

  def write_sets_overlap(left, right) do
    left != [] and right != [] and
      Enum.any?(left, fn a ->
        Enum.any?(right, fn b ->
          a == b or Policy.glob_match?(a, b) or Policy.glob_match?(b, a)
        end)
      end)
  end

  def overlap_errors(wave) when is_list(wave) do
    for {left, i} <- Enum.with_index(wave),
        right <- Enum.drop(wave, i + 1),
        write_sets_overlap(write_globs(left), write_globs(right)) do
      "overlapping writes in wave: #{left.id} #{right.id}"
    end
  end

  def overlap_count(wave) when is_list(wave), do: length(overlap_errors(wave))

  def plan_waves([]), do: {:ok, []}

  def plan_waves(nodes) when is_list(nodes) do
    seen =
      Enum.reduce(nodes, %{}, fn node, acc ->
        Map.update(acc, node.id, 1, &(&1 + 1))
      end)

    dupes =
      seen
      |> Enum.filter(fn {_id, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    ids = MapSet.new(Map.keys(seen))

    unknown =
      for node <- nodes,
          dep <- List.wrap(node.depends_on),
          dep not in ids do
        "unknown depends_on: #{node.id} -> #{dep}"
      end

    cond do
      dupes != [] ->
        {:error, "duplicate node id: " <> Enum.join(dupes, ", ")}

      unknown != [] ->
        {:error, Enum.join(unknown, "\n")}

      true ->
        remaining = MapSet.new(Enum.map(nodes, & &1.id))
        step_waves(nodes, remaining, MapSet.new(), [])
    end
  end

  def ready_nodes(nodes, completed) do
    completed = MapSet.new(completed)

    nodes
    |> Enum.filter(fn node ->
      node.id not in completed and Enum.all?(List.wrap(node.depends_on), &(&1 in completed))
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp step_waves(nodes, remaining, completed, waves) do
    if MapSet.size(remaining) == 0 do
      {:ok, Enum.reverse(waves)}
    else
      ready =
        nodes
        |> ready_nodes(completed)
        |> Enum.filter(&(&1.id in remaining))

      if ready == [] do
        {:error, "dependency cycle"}
      else
        remaining = Enum.reduce(ready, remaining, &MapSet.delete(&2, &1.id))
        completed = Enum.reduce(ready, completed, &MapSet.put(&2, &1.id))
        step_waves(nodes, remaining, completed, [ready | waves])
      end
    end
  end

  def compute_metrics(waves, timings, wall_ms_actual, conflicts \\ 0) do
    widths = Enum.map(waves, &length/1)
    parallel = nodes_parallel(waves, timings)

    serial_ms =
      timings
      |> Map.values()
      |> Enum.reduce(0, fn {start, finish}, acc -> acc + interval_ms(start, finish) end)

    %{
      wave_count: length(waves),
      max_wave_width: if(widths == [], do: 0, else: Enum.max(widths)),
      nodes_parallel: MapSet.size(parallel),
      conflicts: conflicts,
      wall_ms_serial_estimate: serial_ms,
      wall_ms_actual: wall_ms_actual
    }
  end

  def metric_keys, do: @metric_keys

  @doc """
  Out ready nodes, workers take + node_view. Rejects overlapping writes
  before the first `out`. Returns `{:ok, host, colon, metrics}`,
  `{:trap, code, message, host, colon, metrics}`, or an error tuple.
  """
  def execute(host, nodes, artifacts, opts) do
    record = Keyword.get(opts, :record, fn _kind, _payload -> :ok end)
    run_id = Keyword.get(opts, :run_id, host.run_id)
    episode = Keyword.get(opts, :episode, host.episode)
    vocab = Keyword.get(opts, :vocab, [])
    workers = max(1, Keyword.get(opts, :workers, 4))
    node_start_hook = Keyword.get(opts, :node_start_hook)

    case plan_waves(nodes) do
      {:error, reason} ->
        {:error, :graph, reason}

      {:ok, waves} ->
        conflicts = Enum.reduce(waves, 0, &(&2 + overlap_count(&1)))

        case Enum.flat_map(waves, &overlap_errors/1) do
          [_ | _] = errors ->
            {:error, :overlap, errors}

          [] ->
            {:ok, space} = Space.start_link(record: record)
            started = System.monotonic_time(:millisecond)

            try do
              case run_waves(
                     host,
                     space,
                     waves,
                     artifacts,
                     vocab,
                     run_id,
                     episode,
                     0,
                     %{},
                     %{},
                     node_start_hook,
                     workers
                   ) do
                {:ok, host, colon, timings, trapped} ->
                  wall = System.monotonic_time(:millisecond) - started
                  metrics = compute_metrics(waves, timings, wall, conflicts)
                  finish_execute(host, colon, metrics, trapped)

                other ->
                  other
              end
            after
              if Process.alive?(space), do: GenServer.stop(space, :normal, 5_000)
            end
        end
    end
  end

  defp finish_execute(host, colon, metrics, trapped) do
    case trapped do
      {node, {code, message}} ->
        {:trap, code, message, host, colon, Map.put(metrics, :trap_node, node)}

      nil ->
        {:ok, host, colon, metrics}
    end
  end

  defp run_waves(
         host,
         _space,
         [],
         _artifacts,
         _vocab,
         _run_id,
         _episode,
         _wave,
         colon,
         timings,
         _hook,
         _workers
       ),
       do: {:ok, host, colon, timings, nil}

  defp run_waves(
         host,
         space,
         [ready | rest],
         artifacts,
         vocab,
         run_id,
         episode,
         wave_index,
         colon,
         timings,
         hook,
         workers
       ) do
    Enum.each(ready, fn node ->
      Space.out(space, %{
        "kind" => "node.ready",
        "run" => run_id,
        "episode" => episode,
        "wave" => wave_index,
        "node" => node.id
      })
    end)

    outcomes =
      dispatch_ready(space, ready, host, artifacts, vocab, wave_index, colon, hook, workers)

    missing = Enum.reject(ready, &Map.has_key?(outcomes, &1.id))

    if missing != [] do
      {:error, :graph, "wave did not resolve all ready nodes"}
    else
      {host, colon, timings, trapped} = merge_wave(host, ready, outcomes, colon, timings)

      host =
        if "exec" in host.allowed_effects do
          report = LdHost.Gates.run(host, persist?: false)

          host.emit.("graph.wave.gates", %{
            wave: wave_index,
            passed: report.ok == true,
            nodes: Enum.map(ready, & &1.id)
          })

          %{host | last_check: report}
        else
          host
        end

      case trapped do
        {_, _} ->
          {:ok, host, colon, timings, trapped}

        nil ->
          run_waves(
            host,
            space,
            rest,
            artifacts,
            vocab,
            run_id,
            episode,
            wave_index + 1,
            colon,
            timings,
            hook,
            workers
          )
      end
    end
  end

  defp dispatch_ready(space, ready, host, artifacts, vocab, wave_index, colon, hook, workers) do
    if workers == 1 do
      serial_take(space, ready, host, artifacts, vocab, wave_index, colon, hook, %{})
    else
      ready
      |> Enum.with_index(1)
      |> Enum.map(fn {_node, i} ->
        Task.async(fn ->
          take_one(space, ready, host, artifacts, vocab, wave_index, colon, hook, "w#{i}")
        end)
      end)
      |> Task.await_many(60_000)
      |> Enum.reject(&is_nil/1)
      |> Map.new()
    end
  end

  defp take_one(space, ready, host, artifacts, vocab, wave_index, colon, hook, worker_id) do
    case Space.take(space, %{"kind" => "node.ready", "wave" => wave_index}, 60_000, worker_id,
           timeout: 15_000
         ) do
      nil -> nil
      claim -> run_claimed(claim, space, ready, host, artifacts, vocab, colon, hook)
    end
  end

  defp serial_take(space, ready, host, artifacts, vocab, wave_index, colon, hook, acc) do
    if map_size(acc) >= length(ready) do
      acc
    else
      case Space.take(space, %{"kind" => "node.ready", "wave" => wave_index}, 60_000, "w0",
             timeout: 15_000
           ) do
        nil ->
          acc

        claim ->
          {id, outcome} = run_claimed(claim, space, ready, host, artifacts, vocab, colon, hook)

          serial_take(
            space,
            ready,
            host,
            artifacts,
            vocab,
            wave_index,
            colon,
            hook,
            Map.put(acc, id, outcome)
          )
      end
    end
  end

  defp run_claimed(claim, space, ready, host, artifacts, vocab, colon, hook) do
    node_id = claim.tuple["node"]
    node = Enum.find(ready, &(&1.id == node_id))

    outcome =
      if node == nil do
        %{
          node: node_id,
          trap: {"graph", "unknown node"},
          view: host,
          colon: %{},
          start: now(),
          finish: now()
        }
      else
        siblings = ready |> Enum.reject(&(&1.id == node_id)) |> Enum.flat_map(&write_globs/1)
        view = Host.node_view(host, write_globs(node), siblings, wrap_emit(host.emit, node.id))
        start = now()
        view.emit.("graph.node.start", %{node: node.id, worker: claim.worker_id})
        if is_function(hook, 1), do: hook.(node.id)

        {view, node_colon, trap} =
          try do
            {:ok, view, node_colon} = run_node(view, node, artifacts, vocab, colon)
            {view, node_colon, nil}
          rescue
            e in Forth.Error -> {view, %{}, {e.code, e.message}}
            e -> {view, %{}, {"error", Exception.message(e)}}
          end

        finish = now()

        if trap do
          {code, message} = trap
          view.emit.("execution.trap", %{reason: code, detail: message, node: node.id})

          view.emit.("graph.node.finish", %{
            node: node.id,
            status: "fail",
            worker: claim.worker_id,
            detail: message
          })
        else
          view.emit.("graph.node.finish", %{node: node.id, status: "ok", worker: claim.worker_id})
        end

        %{node: node.id, trap: trap, view: view, colon: node_colon, start: start, finish: finish}
      end

    Space.ack(space, claim.token)
    {outcome.node, outcome}
  end

  defp wrap_emit(emit, node_id) when is_function(emit, 2) do
    fn type, data ->
      data = if is_map(data), do: Map.put_new(data, :node, node_id), else: data
      emit.(type, data)
    end
  end

  defp run_node(view, node, artifacts, vocab, colon_seed) do
    view =
      Enum.reduce(artifact_keys_for_node(node, artifacts, view.workspace), view, fn path, view ->
        case Map.fetch(artifacts, path) do
          {:ok, body} when is_binary(body) ->
            case Host.write_file(view, body, path) do
              {:ok, _receipt, view} -> view
              {:trap, code, message} -> raise Forth.Error, code: code, message: message
            end

          _ ->
            view
        end
      end)

    program = node.program || ""

    if String.trim(program) == "" do
      {:ok, view, %{}}
    else
      vm =
        %Forth.VM{host: view, artifacts: artifacts, colon: colon_seed}
        |> Forth.bind_vocab(vocab)

      vm = Forth.interpret(vm, program)
      {:ok, vm.host, vm.colon}
    end
  end

  def artifact_keys_for_node(node, artifacts, workspace) do
    globs = write_globs(node)

    if globs == [] do
      []
    else
      policy = Policy.new(workspace, globs, [])

      artifacts
      |> Map.keys()
      |> Enum.filter(fn path ->
        case Policy.relative(policy, path) do
          {:ok, rel} -> Policy.write_allowed(policy, rel) == nil
          _ -> false
        end
      end)
      |> Enum.sort()
    end
  end

  # Lexicographic id order: later ids win on colon name clashes.
  defp merge_wave(host, wave, outcomes, colon, timings) do
    Enum.reduce(wave, {host, colon, timings, nil}, fn node, {host, colon, timings, trapped} ->
      result = Map.fetch!(outcomes, node.id)
      timings = Map.put(timings, node.id, {result.start, result.finish})

      if result.trap do
        {host, colon, timings, trapped || {node.id, result.trap}}
      else
        colon =
          result.colon
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.reduce(colon, fn {name, body}, acc -> Map.put(acc, name, body) end)

        {Host.absorb(host, result.view), colon, timings, trapped}
      end
    end)
  end

  defp nodes_parallel(waves, timings) do
    Enum.reduce(waves, MapSet.new(), fn wave, acc ->
      ids = Enum.map(wave, & &1.id) |> Enum.filter(&Map.has_key?(timings, &1))

      Enum.reduce(Enum.with_index(ids), acc, fn {left, i}, acc ->
        {ls, le} = timings[left]

        Enum.reduce(Enum.drop(ids, i + 1), acc, fn right, acc ->
          {rs, re} = timings[right]

          if overlaps?(ls, le, rs, re) do
            acc |> MapSet.put(left) |> MapSet.put(right)
          else
            acc
          end
        end)
      end)
    end)
  end

  defp overlaps?(a0, a1, b0, b1) do
    sa = parse_ts(a0)
    ea = parse_ts(a1)
    sb = parse_ts(b0)
    eb = parse_ts(b1)

    sa != nil and ea != nil and sb != nil and eb != nil and DateTime.compare(sa, eb) == :lt and
      DateTime.compare(sb, ea) == :lt
  end

  defp interval_ms(start, finish) do
    case {parse_ts(start), parse_ts(finish)} do
      {%DateTime{} = a, %DateTime{} = b} ->
        ms = DateTime.diff(b, a, :millisecond)
        if ms < 0, do: 0, else: ms

      _ ->
        0
    end
  end

  defp parse_ts(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
