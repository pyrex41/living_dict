defmodule LdHost.Envelope do
  @moduledoc """
  Plan envelope: `{language, program, artifacts, rationale, nodes}` plus
  the duplicate-blocking fingerprint (sha256 over normalized program
  tokens and per-artifact content hashes, in the spirit of
  `kernel.py`'s fingerprint).
  """

  alias LdHost.{Forth, Policy}

  defstruct program: "", artifacts: %{}, rationale: "", nodes: nil

  def parse(%{} = value) do
    program = value["program"] || ""
    nodes = normalize_nodes(value["nodes"])

    cond do
      not is_binary(program) ->
        {:error, "envelope.program missing"}

      String.trim(program) == "" and nodes == nil ->
        {:error, "envelope.program missing"}

      not valid_artifacts?(value["artifacts"]) ->
        {:error, "envelope.artifacts must be an object of string -> string"}

      true ->
        {:ok,
         %__MODULE__{
           program: program,
           artifacts: value["artifacts"] || %{},
           rationale: to_string(value["rationale"] || ""),
           nodes: nodes
         }}
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
    tokens = token_fingerprint(env.program)

    artifacts =
      env.artifacts
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> "#{k}:#{Policy.sha256_hex(v)}" end)
      |> Enum.join(<<0>>)

    nodes = nodes_fingerprint(env.nodes)

    Policy.sha256_hex(tokens <> <<1>> <> artifacts <> <<1>> <> nodes)
  rescue
    # An untokenizable program still needs a stable fingerprint so the
    # duplicate guard can block a byte-identical resubmission.
    _ -> Policy.sha256_hex(env.program)
  end

  defp token_fingerprint(program) do
    program
    |> Forth.tokenize()
    |> Enum.map(fn t -> "#{t.kind}:#{t.value}" end)
    |> Enum.join(<<0>>)
  rescue
    _ -> program
  end

  defp nodes_fingerprint(nil), do: ""

  defp nodes_fingerprint(nodes) when is_list(nodes) do
    nodes
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn node ->
      writes = node.writes |> List.wrap() |> Enum.join(",")
      deps = node.depends_on |> List.wrap() |> Enum.join(",")
      "#{node.id}:#{writes}:#{deps}:#{token_fingerprint(node.program || "")}"
    end)
    |> Enum.join(<<0>>)
  end
end
