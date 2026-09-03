defmodule LdHost.SystemManifest do
  @moduledoc """
  `ld-system/v1`: one typed, content-addressed description of a composed
  system. Components, their ports and substrate requirements, typed channels
  with declared delivery semantics, effects with a single owner, invariants,
  and the failure model the system must survive.

  This module loads and structurally validates a manifest. Judgments about
  it (types compose, substrates satisfy requirements, obligations that
  follow) live in `LdHost.Elaborate`. `deployment` is reserved for the
  production twin and must be absent in v1.

  Schema reference: `docs/design/schema/ld-system-v1.md`.
  """

  alias LdHost.JCS

  @schema "ld-system/v1"
  @deliveries ~w(at-most-once at-least-once exactly-once)
  @orderings ~w(none per-key total)
  @faults ~w(drop duplicate delay reorder)
  @effect_protocols ~w(durable-intent-commit recorded ambient)
  @identities ~w(host-derived guest)
  @invariant_kinds ~w(safety liveness forbidden-path required-waypoint)
  @failure_model ~w(crash-before-effect crash-after-effect crash-after-commit message-duplicate message-reorder message-drop message-delay partition heal provider-timeout)

  def schema, do: @schema
  def failure_model_vocabulary, do: @failure_model

  def load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, raw} <- JSON.decode(text) do
      validate(raw)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, %{__struct__: _} = e} -> {:error, "manifest is not JSON: #{Exception.message(e)}"}
      {:error, reason} -> {:error, "manifest unreadable: #{inspect(reason)}"}
    end
  end

  @doc "Content address of a manifest: SHA-256 of its canonical JSON."
  def hash(manifest), do: JCS.hash!(manifest)

  @doc "Structural validation. Returns `{:ok, manifest}` with string keys."
  def validate(raw) when is_map(raw) do
    problems =
      []
      |> check(raw["schema"] == @schema, "schema must be #{@schema}")
      |> check(nonempty?(raw["system"]), "system must be a non-empty string")
      |> check(
        map_of_maps?(raw["components"]) and map_size(raw["components"]) > 0,
        "components must be a non-empty object"
      )
      |> check(map_of_maps?(raw["channels"] || %{}), "channels must be an object")
      |> check(map_of_maps?(raw["effects"] || %{}), "effects must be an object")
      |> check(map_of_maps?(raw["externals"] || %{}), "externals must be an object")
      |> check(is_list(raw["invariants"] || []), "invariants must be a list")
      |> check(is_list(raw["failure_model"] || []), "failure_model must be a list")
      |> check(
        is_nil(raw["deployment"]) or raw["deployment"] == %{},
        "deployment is reserved in v1 and must be absent"
      )
      |> check(
        Map.keys(raw) --
          ~w(schema system components channels effects externals invariants failure_model deployment) ==
          [],
        "unknown top-level keys"
      )

    problems =
      if problems == [] do
        problems
        |> components(raw["components"])
        |> channels(raw["channels"] || %{})
        |> effects(raw["effects"] || %{})
        |> invariants(raw["invariants"] || [])
        |> failure_model(raw["failure_model"] || [])
      else
        problems
      end

    case Enum.reverse(problems) do
      [] -> {:ok, normalize(raw)}
      list -> {:error, Enum.join(list, "; ")}
    end
  end

  def validate(_), do: {:error, "manifest must be a JSON object"}

  defp normalize(raw) do
    raw
    |> Map.put_new("channels", %{})
    |> Map.put_new("effects", %{})
    |> Map.put_new("externals", %{})
    |> Map.put_new("invariants", [])
    |> Map.put_new("failure_model", [])
    |> Map.delete("deployment")
  end

  defp components(problems, components) do
    Enum.reduce(components, problems, fn {name, c}, acc ->
      acc
      |> check(nonempty?(c["contract"]), "component #{name}: contract required")
      |> check(artifact?(c["artifact"]), "component #{name}: artifact must be sha256:<64 hex>")
      |> check(nonempty?(c["substrate"]), "component #{name}: substrate required")
      |> check(map_of_maps?(c["ports"] || %{}), "component #{name}: ports must be an object")
      |> check(is_map(c["requires"] || %{}), "component #{name}: requires must be an object")
      |> requires(name, c["requires"] || %{})
      |> ports(name, c["ports"] || %{})
    end)
  end

  # requires: dimension => string | [string]; anything else is refused here
  # rather than tolerated by the elaborator.
  defp requires(problems, _cname, requires) when not is_map(requires), do: problems

  defp requires(problems, cname, requires) do
    Enum.reduce(requires, problems, fn {dim, v}, acc ->
      check(
        acc,
        is_binary(dim) and (is_binary(v) or (is_list(v) and Enum.all?(v, &is_binary/1))),
        "component #{cname}: requires.#{inspect(dim)} must be a string or a list of strings"
      )
    end)
  end

  defp ports(problems, _cname, ports) when not is_map(ports), do: problems

  defp ports(problems, cname, ports) do
    Enum.reduce(ports, problems, fn
      {pname, p}, acc when is_map(p) ->
        acc
        |> check(
          p["direction"] in ~w(in out),
          "port #{cname}.#{pname}: direction must be in or out"
        )
        |> check(nonempty?(p["type"]), "port #{cname}.#{pname}: type required")

      {pname, _}, acc ->
        check(acc, false, "port #{cname}.#{inspect(pname)}: must be an object")
    end)
  end

  defp channels(problems, channels) do
    Enum.reduce(channels, problems, fn {name, ch}, acc ->
      acc
      |> check(endpoint?(ch["from"]), "channel #{name}: from must be component.port")
      |> check(endpoint?(ch["to"]), "channel #{name}: to must be component.port")
      |> check(
        ch["delivery"] in @deliveries,
        "channel #{name}: delivery must be one of #{Enum.join(@deliveries, ", ")}"
      )
      |> check(
        ch["ordering"] in @orderings,
        "channel #{name}: ordering must be one of #{Enum.join(@orderings, ", ")}"
      )
      |> check(
        is_integer(ch["capacity"]) and ch["capacity"] > 0,
        "channel #{name}: capacity must be a positive integer"
      )
      |> check(
        is_list(ch["faults"] || []) and Enum.all?(ch["faults"] || [], &(&1 in @faults)),
        "channel #{name}: faults must be drawn from #{Enum.join(@faults, ", ")}"
      )
    end)
  end

  defp effects(problems, effects) do
    Enum.reduce(effects, problems, fn {name, e}, acc ->
      acc
      |> check(nonempty?(e["owner"]), "effect #{name}: owner required")
      |> check(
        e["protocol"] in @effect_protocols,
        "effect #{name}: protocol must be one of #{Enum.join(@effect_protocols, ", ")}"
      )
      |> check(
        e["identity"] in @identities,
        "effect #{name}: identity must be host-derived or guest"
      )
      |> check(
        is_nil(e["target"]) or nonempty?(e["target"]),
        "effect #{name}: target must name an external"
      )
    end)
  end

  defp invariants(problems, invariants) do
    ids = for inv <- invariants, is_map(inv), is_binary(inv["id"]), do: inv["id"]
    dups = ids -- Enum.uniq(ids)

    problems =
      check(problems, dups == [], "duplicate invariant ids: #{Enum.join(Enum.uniq(dups), ", ")}")

    Enum.reduce(invariants, problems, fn inv, acc ->
      acc
      |> check(is_map(inv), "invariant must be an object")
      |> check(is_map(inv) and nonempty?(inv["id"]), "invariant must have an id")
      |> check(
        is_map(inv) and inv["kind"] in @invariant_kinds,
        "invariant #{inspect(is_map(inv) && inv["id"])}: kind must be one of #{Enum.join(@invariant_kinds, ", ")}"
      )
      |> check(
        is_map(inv) and is_list(inv["about"]) and inv["about"] != [],
        "invariant #{inspect(is_map(inv) && inv["id"])}: about must list the names it constrains"
      )
    end)
  end

  defp failure_model(problems, entries) do
    Enum.reduce(entries, problems, fn f, acc ->
      check(
        acc,
        f in @failure_model,
        "failure_model entry #{inspect(f)} is not in the vocabulary"
      )
    end)
  end

  defp check(problems, true, _), do: problems
  defp check(problems, false, msg), do: [msg | problems]

  defp nonempty?(s), do: is_binary(s) and s != ""

  defp map_of_maps?(m),
    do: is_map(m) and Enum.all?(m, fn {k, v} -> is_binary(k) and is_map(v) end)

  defp artifact?(a), do: is_binary(a) and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, a)
  defp endpoint?(e), do: is_binary(e) and Regex.match?(~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/, e)
end
