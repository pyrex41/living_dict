defmodule LdHost.Progress do
  @moduledoc """
  Duplicate-Registry pub/sub: channels between agents without a broker.
  Topics: `{:obligation, id}`, `{:run, run_id}`, `:all`.
  """

  @registry LdHost.Progress.Registry

  def subscribe(topic) do
    {:ok, _} = Registry.register(@registry, topic, [])
    :ok
  end

  def broadcast(topic, message) do
    for t <- [topic, :all] do
      Registry.dispatch(@registry, t, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:ld_progress, topic, message})
      end)
    end

    :ok
  end
end
