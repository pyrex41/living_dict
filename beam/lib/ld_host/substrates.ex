defmodule LdHost.Substrates do
  @moduledoc """
  Substrate capability vectors and the lattice that orders them.

  A runtime profile is a behavioral contract, not a launcher name. Each
  profile declares what it guarantees along every dimension below; a
  component's `requires` (from an `ld-system/v1` manifest or a runtime claim)
  must be satisfied dimension by dimension before the host dispatches to it.
  Unsatisfied dimensions are reported by name so the rejection is legible.

  Only profiles with `claims: true` may back a runtime claim. Experimental
  profiles are registered so their honest vector is visible and comparable,
  and so a manifest that names one is rejected for the right reason.
  """

  # Each dimension lists its values from weakest to strongest. A requirement
  # is satisfied when the guarantee is at least as strong. Set-valued
  # dimensions (fault_controls) require superset.
  @orders %{
    isolation: ~w(none process container microvm wasm-component),
    clock: ~w(ambient recorded logical),
    entropy: ~w(ambient ambient-seeded seeded-replayable),
    scheduler: ~w(preemptive cooperative host-serialized),
    filesystem: ~w(ambient mediated read-only-image none),
    network: ~w(ambient recorded mediated-messages none),
    external_effects: ~w(ambient recorded durable-intent-commit),
    # `component`: the guest declares its own state representation; the host
    # proves it round-trips and hashes it, not that it is complete.
    # `whole-machine`: linear memories, tables, globals, and host state are
    # captured by the host itself. No registered profile provides it yet.
    snapshot: ~w(none guest-declared component whole-machine),
    global_checkpoint: ~w(unsupported supported),
    floating_point: ~w(platform canonical),
    memory_growth: ~w(platform bounded deterministic),
    replay: ~w(none rerun-only in-process cross-process),
    branching: ~w(unsupported supported),
    build_reproducibility: ~w(unpinned pinned attested)
  }

  @profiles %{
    "wasm-durable-v1" => %{
      claims: true,
      executor: "spike/wasm/target/release/ld-wasm",
      vector: %{
        isolation: "wasm-component",
        clock: "logical",
        entropy: "seeded-replayable",
        scheduler: "host-serialized",
        filesystem: "none",
        network: "none",
        external_effects: "durable-intent-commit",
        snapshot: "component",
        global_checkpoint: "unsupported",
        floating_point: "canonical",
        memory_growth: "bounded",
        replay: "cross-process",
        branching: "supported",
        fault_controls: ~w(crash),
        # Toolchain, lockfile, source, and executor digests are bound into
        # every receipt, but the runner is a checkout path, not a host-owned
        # immutable artifact: pinned, not attested.
        build_reproducibility: "pinned"
      }
    },
    # The Unikraft product gate as it exists: a static musl PIE booted by an
    # unpinned base runtime under QEMU with RDRAND/RDSEED exposed. Honest
    # vector; not a claim backend.
    "unikraft-confined-transducer-experimental" => %{
      claims: false,
      executor: nil,
      vector: %{
        isolation: "microvm",
        clock: "ambient",
        entropy: "ambient-seeded",
        scheduler: "cooperative",
        filesystem: "read-only-image",
        network: "none",
        external_effects: "ambient",
        snapshot: "none",
        global_checkpoint: "unsupported",
        floating_point: "platform",
        memory_growth: "platform",
        replay: "rerun-only",
        branching: "unsupported",
        fault_controls: [],
        build_reproducibility: "unpinned"
      }
    }
  }

  def dimensions, do: Map.keys(@orders) ++ [:fault_controls]
  @doc "Lattice orders per dimension, weakest value first."
  def orders, do: @orders
  def profiles, do: @profiles
  def profile(name), do: Map.fetch(@profiles, name)

  @doc "Executor path for a claim-capable profile, relative to the repo root."
  def executor(name) do
    case @profiles[name] do
      %{claims: true, executor: exe} ->
        {:ok, exe}

      %{claims: false} ->
        {:error, "runtime profile #{name} is experimental and cannot back a claim"}

      nil ->
        {:error, "unknown runtime profile: #{name}"}
    end
  end

  @doc """
  Check `requires` (a map of dimension => value, string or atom keys)
  against a profile's guarantees. Returns `:ok` or
  `{:error, [{dimension, required, supplied}]}` listing every unmet
  dimension. Unknown dimensions or values are unmet, never ignored.
  """
  def satisfies(requires, profile_name) when is_map(requires) do
    case @profiles[profile_name] do
      nil ->
        {:error, [{:profile, profile_name, "unknown"}]}

      %{vector: vector} ->
        unmet =
          requires
          |> Enum.map(fn {k, v} -> {normalize_key(k), v} end)
          |> Enum.reject(fn {dim, required} -> meets?(dim, required, vector[dim]) end)
          |> Enum.map(fn {dim, required} -> {dim, required, vector[dim]} end)

        if unmet == [], do: :ok, else: {:error, unmet}
    end
  end

  defp normalize_key(k) when is_atom(k), do: k

  defp normalize_key(k) when is_binary(k) do
    k = String.replace(k, "-", "_")
    Enum.find(dimensions(), :unknown, &(Atom.to_string(&1) == k))
  end

  defp meets?(:unknown, _, _), do: false

  defp meets?(:fault_controls, required, supplied) when is_list(required) and is_list(supplied),
    do: Enum.all?(required, &(to_string(&1) in supplied))

  defp meets?(:fault_controls, _, _), do: false

  defp meets?(dim, required, supplied) do
    order = @orders[dim]

    with true <- is_list(order),
         r when is_integer(r) <- Enum.find_index(order, &(&1 == to_string(required))),
         s when is_integer(s) <- Enum.find_index(order, &(&1 == to_string(supplied))) do
      s >= r
    else
      _ -> false
    end
  end
end
