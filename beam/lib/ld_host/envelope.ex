defmodule LdHost.Envelope do
  @moduledoc """
  Plan envelope: `{language, program, artifacts, rationale, nodes}` plus
  optional nested `cartridge`. Fingerprint is sha256 over normalized
  program tokens, per-artifact content hashes, and when present the
  canonical overlay object (interned definition bodies as 64-hex).

  `LD_CARTRIDGE=0` (default): parse/fingerprint the cartridge; do not
  execute it. Overlay interpret is PR 6.
  """

  alias LdHost.{Dictionary, Forth, Policy, Store}

  @cartridge_keys ~w(parent memory_view action_topology capabilities budget definitions entrypoint)

  defstruct program: "", artifacts: %{}, rationale: "", nodes: nil, cartridge: nil

  def parse(%{} = value) do
    program = get(value, "program") || ""
    nodes = normalize_nodes(get(value, "nodes"))

    cond do
      not is_binary(program) ->
        {:error, "envelope.program missing"}

      String.trim(program) == "" and nodes == nil ->
        {:error, "envelope.program missing"}

      not valid_artifacts?(get(value, "artifacts")) ->
        {:error, "envelope.artifacts must be an object of string -> string"}

      true ->
        case normalize_cartridge(get(value, "cartridge")) do
          {:error, reason} ->
            {:error, reason}

          {:ok, cartridge} ->
            {:ok,
             %__MODULE__{
               program: program,
               artifacts: get(value, "artifacts") || %{},
               rationale: to_string(get(value, "rationale") || ""),
               nodes: nodes,
               cartridge: cartridge
             }}
        end
    end
  end

  defp valid_artifacts?(nil), do: true

  defp valid_artifacts?(map) when is_map(map) do
    Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end)
  end

  defp valid_artifacts?(_), do: false

  defp normalize_nodes(nil), do: nil
  defp normalize_nodes([]), do: nil

  defp normalize_nodes(nodes) when is_list(nodes) do
    Enum.map(nodes, fn node ->
      %{
        id: to_string(node["id"] || ""),
        writes: node["writes"] || [],
        depends_on: node["depends_on"] || [],
        program: node["program"] || ""
      }
    end)
  end

  defp normalize_nodes(_), do: nil

  def fingerprint(%__MODULE__{} = env) do
    tokens =
      env.program
      |> Forth.tokenize()
      |> Enum.map(fn t -> "#{t.kind}:#{t.value}" end)
      |> Enum.join(<<0>>)

    artifacts =
      env.artifacts
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> "#{k}:#{Policy.sha256_hex(v)}" end)
      |> Enum.join(<<0>>)

    Policy.sha256_hex(tokens <> <<1>> <> artifacts <> overlay_suffix(env.cartridge))
  rescue
    # An untokenizable program still needs a stable fingerprint so the
    # duplicate guard can block a byte-identical resubmission.
    _ -> Policy.sha256_hex(env.program <> overlay_material(env.cartridge))
  end

  @doc """
  Canonical overlay object: sorted keys, interned definition bodies as
  64-hex with no `sha256:` prefix. Same bytes interned as the overlay blob.
  """
  def overlay_identity(nil), do: nil

  def overlay_identity(cartridge) when is_map(cartridge) do
    defs =
      (cartridge["definitions"] || %{})
      |> Map.new(fn {name, body} ->
        {to_string(name), Policy.sha256_hex(to_string(body))}
      end)

    %{
      "parent" => Dictionary.digest_hex(cartridge["parent"]),
      "memory_view" => cartridge["memory_view"],
      "action_topology" => cartridge["action_topology"],
      "capabilities" => cartridge["capabilities"] |> List.wrap() |> Enum.map(&to_string/1) |> Enum.sort(),
      "budget" => stringify_keys(cartridge["budget"] || %{}),
      "definitions" => defs,
      "entrypoint" => cartridge["entrypoint"] || ""
    }
  end

  def overlay_bytes(cartridge) do
    case overlay_identity(cartridge) do
      nil -> ""
      obj -> Store.canonical_json(obj)
    end
  end

  defp overlay_suffix(nil), do: ""
  defp overlay_suffix(cartridge), do: <<1>> <> overlay_bytes(cartridge)

  defp overlay_material(nil), do: ""
  defp overlay_material(cartridge), do: overlay_bytes(cartridge)

  defp normalize_cartridge(nil), do: {:ok, nil}

  defp normalize_cartridge(cartridge) when is_map(cartridge) do
    cartridge = stringify_keys(cartridge)

    cartridge =
      cartridge
      |> then(fn c ->
        if is_map(c["definitions"]), do: Map.put(c, "definitions", stringify_keys(c["definitions"])), else: c
      end)
      |> then(fn c ->
        if is_map(c["budget"]), do: Map.put(c, "budget", stringify_keys(c["budget"])), else: c
      end)

    keys = Map.keys(cartridge)
    unknown = Enum.sort(keys -- @cartridge_keys)
    missing = Enum.sort(@cartridge_keys -- keys)

    cond do
      unknown != [] ->
        {:error, "envelope.cartridge unknown keys: #{Enum.join(unknown, ", ")}"}

      missing != [] ->
        {:error, "envelope.cartridge missing keys: #{Enum.join(missing, ", ")}"}

      not cartridge_shape?(cartridge) ->
        {:error, "envelope.cartridge is not a structural overlay object"}

      true ->
        {:ok, cartridge}
    end
  end

  defp normalize_cartridge(_), do: {:error, "envelope.cartridge must be an object"}

  defp cartridge_shape?(c) do
    parent_ok = is_binary(c["parent"]) or is_nil(c["parent"])
    view_ok = is_binary(c["memory_view"])
    topo_ok = is_binary(c["action_topology"])
    caps_ok = is_list(c["capabilities"])
    budget_ok = is_map(c["budget"])
    defs_ok =
      is_map(c["definitions"]) and
        Enum.all?(c["definitions"], fn {k, v} ->
          (is_binary(k) or is_atom(k)) and is_binary(v)
        end)
    entry_ok = is_binary(c["entrypoint"])

    parent_ok and view_ok and topo_ok and caps_ok and budget_ok and defs_ok and entry_ok
  end

  defp stringify_keys(nil), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom, do: Map.get(map, atom)
    end
  end
end
