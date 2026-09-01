defmodule LdHost.OODA do
  @moduledoc """
  Deterministic orientation and bounded, read-only workspace research.

  This is deliberately outside the frozen Forth ABI.  It can describe and
  inspect the workspace, but it cannot write, execute, widen policy, or judge
  success.
  """

  alias LdHost.Policy

  # Count is only a guard against context fan-out; bytes are the stronger
  # bound.  A small module graph commonly includes an __init__ plus several
  # tiny nodes (graph-08 has five writable files), and should not pay for a
  # research loop solely because it crossed an overly tight count threshold.
  @direct_files 8
  @direct_bytes 32 * 1024
  @result_bytes 16 * 1024
  @evidence_bytes 64 * 1024
  @tool_calls 8
  @sensitive [
    ~r{(^|/)\.git(/|$)},
    ~r{(^|/)\.livingdict-run(/|$)},
    ~r{(^|/)protected(/|$)},
    ~r{(^|/)(\.env|id_rsa|id_ed25519)(\.|$)},
    ~r{\.(pem|key|p12|pfx)$}i
  ]

  def limits do
    %{tool_calls: @tool_calls, evidence_bytes: @evidence_bytes, result_bytes: @result_bytes}
  end

  def manifest(workspace, opts \\ []) do
    workspace = Path.expand(workspace)
    allowed = Keyword.get(opts, :allowed_globs, ["**"])

    files =
      workspace
      |> safe_files(workspace)
      |> Enum.reject(&sensitive?/1)
      |> Enum.map(fn path ->
        full = Path.join(workspace, path)
        %{path: path, bytes: File.stat!(full).size, sha256: Policy.sha256_hex(File.read!(full))}
      end)
      |> Enum.sort_by(& &1.path)

    writable = Enum.filter(files, &Policy.matches_any?(&1.path, allowed))
    broad = allowed == [] or Enum.any?(allowed, &(&1 in ["*", "**", "**/*"]))

    %{
      workspace: workspace,
      files: files,
      file_count: length(files),
      total_bytes: Enum.sum(Enum.map(files, & &1.bytes)),
      writable_files: writable,
      writable_bytes: Enum.sum(Enum.map(writable, & &1.bytes)),
      allowed_globs: allowed,
      broad_writes: broad,
      approved_contract: Keyword.get(opts, :approved_contract, false)
    }
  end

  def orient(manifest) do
    direct? =
      manifest.approved_contract and not manifest.broad_writes and
        length(manifest.writable_files) <= @direct_files and
        manifest.writable_bytes <= @direct_bytes and manifest.file_count <= 20

    route =
      cond do
        direct? -> :direct
        manifest.broad_writes and manifest.total_bytes > @evidence_bytes -> :deep_research
        true -> :research
      end

    effort = %{direct: "low", research: "medium", deep_research: "high"}[route]

    %{route: route, effort: effort, reasons: route_reasons(manifest, direct?)}
  end

  def direct_context(manifest) do
    entries =
      Enum.map(manifest.writable_files, fn file ->
        case bounded_read(manifest.workspace, file.path, @result_bytes) do
          {:ok, text, meta} -> %{path: file.path, content: text, meta: meta}
          {:error, reason} -> %{path: file.path, error: reason}
        end
      end)

    context(
      manifest,
      %{questions: [], findings: [], recommended_files: [], uncertainties: []},
      entries
    )
  end

  def context(manifest, brief, entries) do
    JSON.encode!(%{
      workspace_manifest: public_manifest(manifest),
      research_brief: brief,
      selected_sources: entries
    })
  end

  def public_manifest(manifest) do
    Map.take(manifest, [
      :files,
      :file_count,
      :total_bytes,
      :allowed_globs,
      :broad_writes,
      :approved_contract
    ])
  end

  def new_budget do
    %{calls_left: @tool_calls, bytes_left: @evidence_bytes, evidence: %{}}
  end

  @doc "Execute one read-only investigator tool under a cumulative budget."
  def tool(manifest, name, args, budget) do
    with :ok <- budget_available(budget),
         {:ok, result} <- execute_tool(manifest, name, args),
         encoded = JSON.encode!(result),
         :ok <- result_fits(encoded, budget) do
      digest = Policy.sha256_hex(encoded)
      evidence = Map.put(budget.evidence, digest, result)

      {:ok, result,
       %{
         budget
         | calls_left: budget.calls_left - 1,
           bytes_left: budget.bytes_left - byte_size(encoded),
           evidence: evidence
       }}
    end
  end

  def selected_sources(manifest, brief) do
    recommended = brief["recommended_files"] || brief[:recommended_files] || []

    recommended
    |> Enum.uniq()
    |> Enum.take(@direct_files)
    |> Enum.map(fn path ->
      case safe_path(manifest, path) do
        {:ok, _full, rel} ->
          case bounded_read(manifest.workspace, rel, @result_bytes) do
            {:ok, text, meta} -> %{path: rel, content: text, meta: meta}
            {:error, reason} -> %{path: rel, error: reason}
          end

        {:error, reason} ->
          %{path: to_string(path), error: reason}
      end
    end)
  end

  def validate_brief(brief, evidence) when is_map(brief) do
    findings = brief["findings"] || []

    valid =
      Enum.filter(findings, fn finding ->
        citations = finding["evidence"] || []

        citations != [] and
          Enum.all?(citations, fn citation ->
            citation_supported?(citation, evidence)
          end)
      end)

    brief
    |> Map.put("findings", valid)
    |> Map.put("discarded_findings", length(findings) - length(valid))
  end

  def validate_brief(_, _),
    do: %{
      "questions" => [],
      "findings" => [],
      "recommended_files" => [],
      "uncertainties" => ["invalid research brief"]
    }

  defp execute_tool(manifest, "list_tree", args) do
    path = normalize_dir(args["path"] || ".")
    depth = clamp(args["depth"] || 2, 0, 6)
    limit = clamp(args["limit"] || 100, 1, 200)
    cursor = clamp(args["cursor"] || 0, 0, 1_000_000)

    rows =
      Enum.filter(manifest.files, fn file ->
        under?(file.path, path) and relative_depth(file.path, path) <= depth
      end)

    page = Enum.slice(rows, cursor, limit)
    {:ok, %{entries: page, next_cursor: next_cursor(cursor, limit, length(rows))}}
  end

  defp execute_tool(manifest, "read_lines", args) do
    with {:ok, full, rel} <- safe_path(manifest, args["path"] || ""),
         {:ok, data} <- File.read(full) do
      if String.valid?(data) do
        lines = String.split(data, "\n")
        first = clamp(args["start_line"] || 1, 1, max(length(lines), 1))
        last = clamp(args["end_line"] || first + 199, first, min(first + 399, length(lines)))

        text =
          lines
          |> Enum.slice((first - 1)..(last - 1))
          |> Enum.join("\n")
          |> truncate(@result_bytes)

        {:ok,
         %{
           path: rel,
           start_line: first,
           end_line: last,
           text: text,
           sha256: Policy.sha256_hex(data)
         }}
      else
        {:ok, %{path: rel, binary: true, bytes: byte_size(data), sha256: Policy.sha256_hex(data)}}
      end
    end
  end

  defp execute_tool(manifest, "search_text", args) do
    query = to_string(args["query"] || "") |> String.slice(0, 256)
    globs = args["path_globs"] || ["**"]
    limit = clamp(args["max_hits"] || 50, 1, 100)
    cursor = clamp(args["cursor"] || 0, 0, 1_000_000)

    hits =
      if query == "" do
        []
      else
        manifest.files
        |> Enum.filter(&Policy.matches_any?(&1.path, globs))
        |> Enum.flat_map(fn file -> search_file(manifest.workspace, file, query) end)
      end

    page = Enum.slice(hits, cursor, limit)
    {:ok, %{hits: page, next_cursor: next_cursor(cursor, limit, length(hits))}}
  end

  defp execute_tool(_, name, _), do: {:error, "unknown research tool: #{name}"}

  defp search_file(workspace, file, query) do
    case File.read(Path.join(workspace, file.path)) do
      {:ok, data} when is_binary(data) ->
        if String.valid?(data) do
          data
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> String.contains?(line, query) end)
          |> Enum.map(fn {line, number} ->
            %{
              path: file.path,
              line: number,
              text: String.slice(line, 0, 500),
              sha256: file.sha256
            }
          end)
        else
          []
        end

      _ ->
        []
    end
  end

  defp safe_path(manifest, path) when is_binary(path) do
    policy = Policy.new(manifest.workspace, ["**"], [])

    with {:ok, rel} when rel != "" <- Policy.relative(policy, path),
         false <- sensitive?(rel),
         true <- Enum.any?(manifest.files, &(&1.path == rel)),
         true <- no_symlink_components?(manifest.workspace, rel) do
      {:ok, Path.join(manifest.workspace, rel), rel}
    else
      true -> {:error, "research path denied"}
      false -> {:error, "file is outside the research manifest"}
      _ -> {:error, "invalid research path"}
    end
  end

  defp safe_path(_, _), do: {:error, "invalid research path"}

  defp bounded_read(workspace, rel, cap) do
    case File.read(Path.join(workspace, rel)) do
      {:ok, data} when byte_size(data) <= cap and is_binary(data) ->
        if String.valid?(data),
          do:
            {:ok, data,
             %{bytes: byte_size(data), sha256: Policy.sha256_hex(data), truncated: false}},
          else:
            {:ok, "<<binary file: #{byte_size(data)} bytes>>",
             %{bytes: byte_size(data), sha256: Policy.sha256_hex(data), binary: true}}

      {:ok, data} ->
        {:ok, truncate(data, cap),
         %{bytes: byte_size(data), sha256: Policy.sha256_hex(data), truncated: true}}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp citation_supported?(citation, evidence) do
    path = citation["path"]
    sha = citation["sha256"]

    Enum.any?(evidence, fn {_digest, result} ->
      encoded = JSON.encode!(result)

      is_binary(path) and String.contains?(encoded, path) and
        (not is_binary(sha) or String.contains?(encoded, sha))
    end)
  end

  defp route_reasons(_manifest, true), do: ["approved contract", "narrow bounded source set"]

  defp route_reasons(manifest, false) do
    []
    |> maybe_reason(not manifest.approved_contract, "no approved contract")
    |> maybe_reason(manifest.broad_writes, "broad write scope")
    |> maybe_reason(
      length(manifest.writable_files) > @direct_files,
      "more than #{@direct_files} writable files"
    )
    |> maybe_reason(
      manifest.writable_bytes > @direct_bytes,
      "writable sources exceed #{@direct_bytes} bytes"
    )
    |> maybe_reason(manifest.file_count > 20, "workspace has more than 20 files")
  end

  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _), do: reasons
  defp budget_available(%{calls_left: n, bytes_left: b}) when n > 0 and b > 0, do: :ok
  defp budget_available(_), do: {:error, "research budget exhausted"}

  defp result_fits(data, %{bytes_left: b})
       when byte_size(data) <= b and byte_size(data) <= @result_bytes, do: :ok

  defp result_fits(_, _), do: {:error, "research result exceeds budget"}
  defp sensitive?(path), do: Enum.any?(@sensitive, &Regex.match?(&1, path))
  defp normalize_dir("."), do: ""
  defp normalize_dir(path), do: path |> to_string() |> String.trim("/")
  defp under?(_path, ""), do: true
  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp relative_depth(path, ""), do: length(Path.split(path))

  defp relative_depth(path, root),
    do: path |> String.replace_prefix(root <> "/", "") |> Path.split() |> length()

  defp next_cursor(cursor, limit, total),
    do: if(cursor + limit < total, do: cursor + limit, else: nil)

  defp truncate(data, cap) when byte_size(data) <= cap, do: data

  defp truncate(data, cap),
    do: String.replace_invalid(binary_part(data, 0, cap)) <> "\n<<truncated>>"

  defp clamp(value, lo, hi) when is_integer(value), do: value |> max(lo) |> min(hi)
  defp clamp(_, lo, _), do: lo

  defp no_symlink_components?(workspace, rel) do
    {_path, safe?} =
      Enum.reduce_while(Path.split(rel), {workspace, true}, fn part, {parent, _} ->
        path = Path.join(parent, part)

        case File.lstat(path) do
          {:ok, %{type: :symlink}} -> {:halt, {path, false}}
          {:ok, _} -> {:cont, {path, true}}
          _ -> {:halt, {path, false}}
        end
      end)

    safe?
  end

  defp safe_files(dir, root) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(Enum.sort(names), fn name ->
          full = Path.join(dir, name)
          rel = Path.relative_to(full, root)

          case {sensitive?(rel), File.lstat(full)} do
            {true, _} -> []
            {false, {:ok, %{type: :directory}}} -> safe_files(full, root)
            {false, {:ok, %{type: :regular}}} -> [rel]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end
end
