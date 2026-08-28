defmodule LdHost.Policy do
  @moduledoc """
  Workspace path and change-policy helpers.

  Port of `harness/src/livingdict/policy.py`. Glob semantics are
  fnmatch-style: `*` and `?` match across slashes (so `tests/**` and
  `tests/*` behave alike), matching both the Python host and the portable
  Shen critic. Character classes are not supported — nothing in the tree
  uses them.
  """

  defstruct [:workspace, allowed: [], forbidden: []]

  @skip_dirs ~w(.git __pycache__ .mypy_cache .pytest_cache .ruff_cache node_modules dist build target .vite .livingdict-run .sb)

  def new(workspace, allowed, forbidden) do
    %__MODULE__{workspace: Path.expand(workspace), allowed: allowed, forbidden: forbidden}
  end

  @doc "Posix path inside the workspace ({:ok, rel}) or {:error, reason}."
  def relative(%__MODULE__{workspace: ws}, path) do
    resolved =
      if match?("/" <> _, path) do
        Path.expand(path)
      else
        Path.expand(Path.join(ws, path))
      end

    cond do
      resolved == ws -> {:ok, ""}
      String.starts_with?(resolved, ws <> "/") -> {:ok, String.replace_prefix(resolved, ws <> "/", "")}
      true -> {:error, "path escapes workspace: #{path}"}
    end
  end

  def resolve(%__MODULE__{workspace: ws} = policy, path) do
    case relative(policy, path) do
      {:ok, ""} -> {:ok, ws}
      {:ok, rel} -> {:ok, Path.join(ws, rel)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Denial reason for writing rel, or nil when the write is in policy."
  def write_allowed(%__MODULE__{} = policy, rel) do
    cond do
      matches_any?(rel, policy.forbidden) -> "forbidden path: #{rel}"
      not matches_any?(rel, policy.allowed) -> "path outside allowed change set: #{rel}"
      true -> nil
    end
  end

  def matches_any?(path, patterns), do: Enum.any?(patterns, &glob_match?(path, &1))

  @doc "fnmatch-lite: * and ? cross slashes, everything else is literal."
  def glob_match?(path, pattern) do
    regex = pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")
    Regex.match?(~r/^#{regex}$/s, path)
  end

  # ---- snapshots --------------------------------------------------------

  @doc "Map of rel path -> sha256 hex over workspace files (skip dirs pruned)."
  def snapshot(root) do
    root = Path.expand(root)

    walk_files(root, root)
    |> Enum.reject(fn rel ->
      parts = Path.split(rel)
      Enum.any?(parts, &(&1 in @skip_dirs)) or Path.extname(rel) in [".pyc", ".pyo"]
    end)
    |> Enum.sort()
    |> Map.new(fn rel ->
      {rel, sha256_hex(File.read!(Path.join(root, rel)))}
    end)
  end

  defp walk_files(dir, root) do
    case File.ls(dir) do
      {:error, _} ->
        []

      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          full = Path.join(dir, name)

          cond do
            File.dir?(full) ->
              if name in @skip_dirs, do: [], else: walk_files(full, root)

            File.regular?(full) ->
              [Path.relative_to(full, root)]

            true ->
              []
          end
        end)
    end
  end

  def changed_files(before, after_snap) do
    (Map.keys(before) ++ Map.keys(after_snap))
    |> Enum.uniq()
    |> Enum.filter(fn key -> Map.get(before, key) != Map.get(after_snap, key) end)
    |> Enum.sort()
  end

  def workspace_digest(files) do
    files
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {rel, digest}, acc ->
      acc
      |> :crypto.hash_update(rel)
      |> :crypto.hash_update(<<0>>)
      |> :crypto.hash_update(digest)
      |> :crypto.hash_update("\n")
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
