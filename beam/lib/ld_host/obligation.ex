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
      goal = ob["goal"] || ""
      workspace = ob["workspace"]

      opts =
        [workspace: workspace]
        |> maybe(:contract, contract_of(ob))
        |> maybe(:dictionary_dir, ob["dictionary"])
        |> maybe(:max_episodes, get_in(ob, ["limits", "max_episodes"]))
        |> Keyword.merge(extra)

      summary = LdHost.Run.run(goal, opts)
      {:ok, %{status: if(summary.success, do: :completed, else: :failed), summary: summary}}
    end

    defp contract_of(%{"contract" => %{"claims" => claims}}), do: %{claims: claims, source: "obligation"}
    defp contract_of(_), do: nil

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

  @doc """
  Execute one claimed obligation under a Jido agent, heart-beating the
  space lease while it runs. Returns `{:completed | :failed, summary}`.
  """
  def execute(space, claim, run_opts \\ []) do
    heartbeat = start_heartbeat(space, claim)

    try do
      agent = Agent.new()

      # jido_action's default exec timeout is 30s; an obligation runs a
      # whole multi-episode loop with model calls, so it gets 30 minutes.
      {agent, directives} =
        Agent.cmd(agent, {RunGoal, %{obligation: claim.tuple, run_opts: run_opts}}, timeout: 1_800_000)

      case agent.state do
        %{status: status, summary: %{} = summary} when status in [:completed, :failed] ->
          {status, summary}

        _ ->
          raise "obligation agent did not complete: #{inspect(directives, limit: 5)}"
      end
    after
      stop_heartbeat(heartbeat)
    end
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
