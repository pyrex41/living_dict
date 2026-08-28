defmodule LdHost.Application do
  @moduledoc """
  Top supervisor. Runs are dynamic: each `LdHost.Run` starts its own
  Ledger under RunSupervisor. The Critic boots once per node (luerl state
  holding the shaken Shen artifact) and is shared read-only via calls.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: LdHost.Progress.Registry},
      {LdHost.Critic, []},
      {Task.Supervisor, name: LdHost.ObligationTaskSup},
      {DynamicSupervisor, strategy: :one_for_one, name: LdHost.RunSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LdHost.Supervisor)
  end
end
