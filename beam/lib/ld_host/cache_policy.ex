defmodule LdHost.CachePolicy do
  @moduledoc """
  Cache identity for model calls and read-only OODA evidence.

  Provider keys are routing hints, never result-cache keys: xAI still requires
  an exact prompt prefix before it can reuse KV state.  Keys are hashed so run
  paths, goals, and repository names never leave the host as identifiers.
  """

  alias LdHost.Policy

  @scopes [:off, :run, :shared]

  def normalize(nil), do: :run
  def normalize(value) when value in @scopes, do: value
  def normalize(value) when value in ~w(off run shared), do: String.to_existing_atom(value)

  def normalize(value),
    do: raise(ArgumentError, "invalid cache scope: #{inspect(value)}")

  def routing_key(:off, _opts), do: nil

  def routing_key(scope, opts) when scope in [:run, :shared] do
    phase = Keyword.fetch!(opts, :phase)
    model = Keyword.fetch!(opts, :model)
    protocol = Keyword.get(opts, :protocol, "chat-completions")
    schema = Keyword.get(opts, :schema, "v1")

    identity =
      case scope do
        :run ->
          run_id = Keyword.fetch!(opts, :run_id)
          "run\0#{run_id}\0#{model}\0#{protocol}\0#{phase}\0#{schema}"

        :shared ->
          "shared\0#{model}\0#{protocol}\0#{phase}\0#{schema}"
      end

    "ld-" <> Policy.sha256_hex(identity)
  end

  def fingerprint(nil), do: nil
  def fingerprint(key), do: Policy.sha256_hex(key)

  def shared_root do
    base =
      System.get_env("XDG_CACHE_HOME") ||
        Path.join(System.user_home!(), ".cache")

    Path.join([base, "livingdict", "v1"])
  end
end
