defmodule LdHost.Wave do
  @moduledoc """
  Kahn-level waves for independent artifact nodes. Linda (`Space`) is the
  executor; overlapping writes are refused before any node I/O.
  """

  alias LdHost.{Forth, Host, Policy, Space}

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

  def plan_waves([]), do: {:ok, []}

  def plan_waves(nodes) when is_list(nodes) do
    seen =
      Enum.reduce(nodes, %{}, fn node, acc ->
        Map.update(acc, node.id, 1, &(&1 + 1))
      end)

    dupes = seen |> Enum.filter(fn {_id, n} -> n > 1 end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    cond do
      dupes != [] ->
        {:error, "duplicate node id: " <> Enum.join(dupes, ", ")}

      true ->
        remaining = MapSet.new(Enum.map(nodes, & &1.id))
        step_waves(nodes, remaining, MapSet.new(), [])
    end
  end

  def ready_nodes(nodes, completed) do
    nodes
    |> Enum.filter(fn node ->
      node.id not in completed and Enum.all?(node.depends_on, &(&1 in completed))
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

  @doc """
  Out ready nodes, workers take + node_view. Rejects overlapping writes
  before the first `out`. Returns `{:ok, host}` or an error tuple.
  """
  def execute(host, nodes, artifacts, opts) do
    record = Keyword.fetch!(opts, :record)
    run_id = Keyword.get(opts, :run_id, host.run_id)
    episode = Keyword.get(opts, :episode, host.episode)
    vocab = Keyword.get(opts, :vocab, [])

    case plan_waves(nodes) do
      {:error, reason} ->
        {:error, :graph, reason}

      {:ok, waves} ->
        case Enum.flat_map(waves, &overlap_errors/1) do
          [_ | _] = errors ->
            {:error, :overlap, errors}

          [] ->
            {:ok, space} = Space.start_link(record: record)

            try do
              run_waves(host, space, waves, artifacts, vocab, run_id, episode, 0)
            after
              if Process.alive?(space), do: GenServer.stop(space, :normal, 5_000)
            end
        end
    end
  end

  defp run_waves(host, _space, [], _artifacts, _vocab, _run_id, _episode, _wave), do: {:ok, host}

  defp run_waves(host, space, [ready | rest], artifacts, vocab, run_id, episode, wave_index) do
    Enum.each(ready, fn node ->
      Space.out(space, %{
        "kind" => "node.ready",
        "run" => run_id,
        "episode" => episode,
        "wave" => wave_index,
        "node" => node.id
      })
    end)

    tasks =
      Enum.map(ready, fn _node ->
        Task.async(fn ->
          wave_worker(space, wave_index, host, ready, artifacts, vocab)
        end)
      end)

    results = Task.await_many(tasks, 60_000)

    case Enum.find(results, &match?({:trap, _, _}, &1)) do
      {:trap, code, message} ->
        {:trap, code, message}

      nil ->
        host =
          Enum.reduce(results, host, fn
            {:ok, view}, acc -> Host.absorb(acc, view)
            _, acc -> acc
          end)

        if "exec" in host.allowed_effects do
          _ = LdHost.Gates.run(host, persist?: false)
        end

        run_waves(host, space, rest, artifacts, vocab, run_id, episode, wave_index + 1)
    end
  end

  defp wave_worker(space, wave_index, host, ready, artifacts, vocab) do
    worker_id = "w-#{:erlang.unique_integer([:positive])}"

    case Space.take(space, %{"kind" => "node.ready", "wave" => wave_index}, 60_000, worker_id,
           timeout: 15_000
         ) do
      nil ->
        {:error, :empty}

      claim ->
        node_id = claim.tuple["node"]
        node = Enum.find(ready, &(&1.id == node_id))
        siblings = ready |> Enum.reject(&(&1.id == node_id)) |> Enum.flat_map(&write_globs/1)
        view = Host.node_view(host, write_globs(node), siblings, host.emit)

        result =
          try do
            {:ok, run_node(view, node, artifacts, vocab)}
          rescue
            e in Forth.Error -> {:trap, e.code, e.message}
          end

        Space.ack(space, claim.token)
        result
    end
  end

  defp run_node(view, node, artifacts, vocab) do
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
      view
    else
      vm =
        %Forth.VM{host: view, artifacts: artifacts}
        |> Forth.bind_vocab(vocab)

      Forth.interpret(vm, program).host
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
end
