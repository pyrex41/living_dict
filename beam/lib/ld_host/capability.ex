defmodule LdHost.Capability do
  @moduledoc """
  The host word contract between the Forth VM and a capability host.

  A host is any struct whose module implements `call/3`. Words receive
  already-popped arguments (the VM owns stack discipline and type traps)
  and return `{:ok, value, host}` or `{:trap, code, message}` — the VM
  converts traps to `LdHost.Forth.Error`, mirroring the Python
  CapabilityError -> ForthError conversion.
  """

  @type result :: {:ok, term(), struct()} | {:trap, String.t(), String.t()}

  @callback call(host :: struct(), word :: String.t(), args :: [term()]) :: result()

  def call(%mod{} = host, word, args), do: mod.call(host, word, args)
end
