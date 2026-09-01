defmodule LdHost.EvidenceCache do
  @moduledoc "Content-addressed cache for read-only OODA tool results."

  alias LdHost.{CachePolicy, Policy}

  def get(:off, _run_dir, _manifest, _tool, _args), do: :miss

  def get(scope, run_dir, manifest, tool, args) do
    path = entry_path(scope, run_dir, manifest, tool, args)

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"result" => result}} <- JSON.decode(bytes) do
      {:hit, result}
    else
      _ -> :miss
    end
  end

  def put(:off, _run_dir, _manifest, _tool, _args, _result), do: :ok

  def put(scope, run_dir, manifest, tool, args, result) do
    path = entry_path(scope, run_dir, manifest, tool, args)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(tmp, JSON.encode!(%{version: 1, result: result}), [:binary])
    File.chmod(tmp, 0o600)
    File.rename(tmp, path)
  rescue
    _ -> :ok
  end

  def key(manifest, tool, args) do
    files = Enum.map(manifest.files, &[&1.path, &1.bytes, &1.sha256])
    Policy.sha256_hex(JSON.encode!(%{version: 1, files: files, tool: tool, args: args}))
  end

  defp entry_path(scope, run_dir, manifest, tool, args) do
    root =
      case scope do
        :run -> Path.join(run_dir, "cache/evidence")
        :shared -> Path.join(CachePolicy.shared_root(), "evidence")
      end

    Path.join(root, key(manifest, tool, args) <> ".json")
  end
end
