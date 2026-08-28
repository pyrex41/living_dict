defmodule LdHost.Host do
  @moduledoc """
  The capability host: the only I/O a Living Dictionary arm may perform.

  Port of `harness/src/livingdict/host.py` — same words, same trap codes,
  same receipt shape. Events go through the `emit` closure (wired to the
  run's Ledger); the host itself owns no process state, it is a value
  threaded through the Forth VM.

  Documented divergence from the frozen Python reference: READ-FILE on a
  non-UTF-8 file does NOT trap `decode`. It returns a summary value string
  (`"<<binary file: N bytes, magic xxxxxxxx 'printable head'>>"`) so the
  planner can observe the file exists and is binary instead of retrying
  the read and burning episodes. The `decode` trap code itself remains
  reserved for any other path that used it.
  """

  @behaviour LdHost.Capability

  alias LdHost.{Policy, Cmd}

  defstruct workspace: nil,
            allowed_effects: ["read", "write", "exec"],
            allowed_globs: [],
            forbidden_globs: [],
            run_id: "",
            task_id: "",
            episode: 0,
            test_timeout_seconds: 60,
            emit: nil,
            policy: nil,
            outer_policy: nil,
            before: %{},
            effects_used: MapSet.new(),
            last_check: nil,
            contract: nil,
            allow_model_checks: false,
            objects_dir: nil,
            receipt_path: nil,
            write_receipt?: true

  def new(workspace, opts \\ []) do
    workspace = Path.expand(workspace)

    unless File.dir?(workspace) do
      raise ArgumentError, "workspace is not a directory: #{workspace}"
    end

    allowed = Keyword.get(opts, :allowed_globs, ["**"])
    forbidden = Keyword.get(opts, :forbidden_globs, [])

    %__MODULE__{
      workspace: workspace,
      allowed_effects: Keyword.get(opts, :allowed_effects, ["read", "write", "exec"]),
      allowed_globs: allowed,
      forbidden_globs: forbidden,
      run_id: Keyword.get(opts, :run_id, ""),
      task_id: Keyword.get(opts, :task_id, ""),
      episode: Keyword.get(opts, :episode, 0),
      test_timeout_seconds: Keyword.get(opts, :test_timeout_seconds, 60),
      emit: Keyword.get(opts, :emit, fn _type, _data -> :ok end),
      policy: Policy.new(workspace, allowed, forbidden),
      before: Policy.snapshot(workspace),
      contract: Keyword.get(opts, :contract),
      allow_model_checks: Keyword.get(opts, :allow_model_checks, false),
      objects_dir: Keyword.get(opts, :objects_dir),
      receipt_path: Keyword.get(opts, :receipt_path),
      write_receipt?: Keyword.get(opts, :write_receipt?, true)
    }
  end

  @doc """
  Isolated host for one graph node: narrowed write globs, sibling write
  sets forbidden, buffered-elsewhere event emission, no receipt writing.
  """
  def node_view(%__MODULE__{} = host, write_globs, extra_forbidden, emit) do
    forbidden = host.forbidden_globs ++ extra_forbidden

    %{
      host
      | allowed_globs: write_globs,
        forbidden_globs: forbidden,
        policy: Policy.new(host.workspace, write_globs, forbidden),
        outer_policy: host.outer_policy || host.policy,
        effects_used: MapSet.new(),
        last_check: nil,
        emit: emit,
        write_receipt?: false
    }
  end

  @doc "Merge a node view's observations back into the parent host."
  def absorb(%__MODULE__{} = host, %__MODULE__{} = view) do
    %{
      host
      | effects_used: MapSet.union(host.effects_used, view.effects_used),
        last_check: view.last_check || host.last_check
    }
  end

  # ---- Capability dispatch ---------------------------------------------

  @impl true
  def call(host, "READ-FILE", [path]), do: read_file(host, path)
  def call(host, "LIST-DIR", [path]), do: list_dir(host, path)
  def call(host, "SEARCH", [query]), do: search(host, query)
  def call(host, "WRITE-FILE", [content, path]), do: write_file(host, content, path)
  def call(host, "USE-OBJECT", [sha]), do: fetch_object(host, sha)
  def call(host, "PATCH-FILE", [patch, path]), do: patch_file(host, patch, path)
  def call(host, "RUN-TESTS", []), do: run_checks(host, "RUN-TESTS", false)
  def call(host, "RUN-GATES", []), do: run_checks(host, "RUN-GATES", true)
  def call(host, "RECEIPT", []), do: receipt(host)

  # ---- words ------------------------------------------------------------

  def read_file(host, path) do
    with {:ok, host} <- require_effect(host, "read"),
         {:ok, rel} <- rel(host, path),
         target = target_path(host, rel),
         true <- File.regular?(target) || {:missing, rel} do
      tool(host, "READ-FILE", %{path: rel})

      case File.read(target) do
        {:ok, data} ->
          if String.valid?(data) do
            {:ok, data, host}
          else
            # Divergence from the Python reference (which traps "decode"):
            # a binary read returns a summary so the planner does not
            # blindly retry the read. See the moduledoc.
            {:ok, binary_summary(data), host}
          end

        {:error, _} ->
          trap_event(host, %{reason: "missing_file", path: empty_dot(rel)})
          {:trap, "missing_file", "missing file: #{empty_dot(rel)}"}
      end
    else
      {:missing, rel} ->
        trap_event(host, %{reason: "missing_file", path: empty_dot(rel)})
        {:trap, "missing_file", "missing file: #{empty_dot(rel)}"}

      {:trap, _, _} = trap ->
        trap
    end
  end

  def list_dir(host, path) do
    with {:ok, host} <- require_effect(host, "read"),
         {:ok, rel} <- rel_dir(host, path),
         target = target_path(host, rel),
         true <- File.dir?(target) || {:missing, rel} do
      tool(host, "LIST-DIR", %{path: empty_dot(rel)})

      names =
        target
        |> File.ls!()
        |> Enum.sort()
        |> Enum.map(fn name ->
          rel_child = if rel == "", do: name, else: "#{rel}/#{name}"
          if File.dir?(Path.join(target, name)), do: rel_child <> "/", else: rel_child
        end)

      {:ok, names, host}
    else
      {:missing, rel} ->
        trap_event(host, %{reason: "missing_file", path: empty_dot(rel)})
        {:trap, "missing_file", "missing directory: #{empty_dot(rel)}"}

      {:trap, _, _} = trap ->
        trap
    end
  end

  def search(host, query) do
    with {:ok, host} <- require_effect(host, "read") do
      tool(host, "SEARCH", %{query: query})

      hits =
        if query == "" do
          []
        else
          host.workspace
          |> Policy.snapshot()
          |> Map.keys()
          |> Enum.sort()
          |> Enum.flat_map(fn rel ->
            case File.read(Path.join(host.workspace, rel)) do
              {:ok, text} when is_binary(text) ->
                if String.valid?(text) do
                  text
                  |> String.split("\n")
                  |> Enum.with_index(1)
                  |> Enum.filter(fn {line, _} -> String.contains?(line, query) end)
                  |> Enum.map(fn {line, number} -> %{path: rel, line: number, text: line} end)
                else
                  []
                end

              _ ->
                []
            end
          end)
        end

      {:ok, hits, host}
    end
  end

  def write_file(host, content, path) do
    with {:ok, host} <- require_effect(host, "write"),
         {:ok, rel} <- rel(host, path) do
      reason =
        Policy.write_allowed(host.policy, rel) ||
          (host.outer_policy && Policy.write_allowed(host.outer_policy, rel))

      if reason do
        tool(host, "WRITE-FILE", %{path: rel, denied: true})
        trap_event(host, %{reason: "policy", detail: reason, path: rel})
        {:trap, "policy", reason}
      else
        target = Path.join(host.workspace, rel)
        digest = Policy.sha256_hex(content)
        intern_blob(host, content, digest)
        receipt = %{path: rel, bytes: byte_size(content), sha256: digest}

        case File.read(target) do
          {:ok, existing} when existing == content ->
            tool(host, "WRITE-FILE", %{path: rel, bytes: byte_size(content), idempotent: true})
            {:ok, receipt, host}

          _ ->
            File.mkdir_p!(Path.dirname(target))
            File.write!(target, content)
            tool(host, "WRITE-FILE", %{path: rel, bytes: byte_size(content)})
            emit(host, "mutation.applied", %{path: rel, sha256: digest})
            {:ok, receipt, host}
        end
      end
    end
  end

  defp run_checks(host, word, persist?) do
    with {:ok, host} <- require_effect(host, "exec") do
      tool(host, word, %{command: word})
      report = LdHost.Gates.run(host, persist?: persist?)
      host = %{host | last_check: report}

      if report[:timed_out] do
        trap_event(host, %{reason: "test_timeout"})
      end

      {:ok, report, host}
    end
  end

  def receipt(host, extra \\ %{}) do
    after_snap = Policy.snapshot(host.workspace)
    changed = Policy.changed_files(host.before, after_snap)

    violations =
      Enum.filter(changed, fn rel -> Policy.write_allowed(host.policy, rel) != nil end)

    payload =
      %{
        run_id: host.run_id,
        task_id: host.task_id,
        success: violations == [],
        workspace_before: Policy.workspace_digest(host.before),
        workspace_after: Policy.workspace_digest(after_snap),
        changed_files: changed,
        effects_used: host.effects_used |> MapSet.to_list() |> Enum.sort(),
        policy_violations:
          Enum.map(violations, &"path outside policy after the fact: #{&1}")
      }
      |> maybe_put(:check, host.last_check)
      |> Map.merge(extra)

    if host.write_receipt? do
      target = host.receipt_path || Path.join(host.workspace, "receipt.json")
      File.write!(target, JSON.encode!(payload))
      tool(host, "RECEIPT", %{path: target, changed_files: changed})
    else
      tool(host, "RECEIPT", %{path: nil, changed_files: changed})
    end

    {:ok, payload, host}
  end

  @doc "CAS intern. Identical bytes reuse the same objects/<aa>/<sha> path."
  def intern(%__MODULE__{} = host, content) when is_binary(content) do
    digest = Policy.sha256_hex(content)
    intern_blob(host, content, digest)
    digest
  end

  @doc "Read an interned blob. Requires the read effect (USE-OBJECT)."
  def fetch_object(host, sha) do
    with {:ok, host} <- require_effect(host, "read") do
      tool(host, "USE-OBJECT", %{sha256: sha})

      case read_blob(host.objects_dir, sha) do
        {:ok, data} ->
          {:ok, data, host}

        {:error, reason} ->
          trap_event(host, %{reason: "missing_object", sha256: sha, detail: reason})
          {:trap, "missing_object", "no object: #{sha}"}
      end
    end
  end

  def patch_file(host, patch, path) do
    with {:ok, current, host} <- read_file(host, path) do
      write_file(host, apply_patch(current, patch), path)
    end
  end

  # ---- internals --------------------------------------------------------

  defp require_effect(host, effect) do
    if effect in host.allowed_effects do
      {:ok, %{host | effects_used: MapSet.put(host.effects_used, effect)}}
    else
      trap_event(host, %{reason: "effect", effect: effect})
      {:trap, "effect", "effect not allowed: #{effect}"}
    end
  end

  defp rel(host, path) do
    case Policy.relative(host.policy, path) do
      {:ok, rel} ->
        {:ok, rel}

      {:error, reason} ->
        trap_event(host, %{reason: "path", detail: reason})
        {:trap, "path", reason}
    end
  end

  defp rel_dir(_host, path) when path in ["", "."], do: {:ok, ""}
  defp rel_dir(host, path), do: rel(host, path)

  defp target_path(host, ""), do: host.workspace
  defp target_path(host, rel), do: Path.join(host.workspace, rel)

  defp empty_dot(""), do: "."
  defp empty_dot(rel), do: rel

  def intern_blob(%{objects_dir: nil}, _content, _digest), do: :ok

  def intern_blob(%{objects_dir: dir}, content, digest) when is_binary(dir) and is_binary(digest) do
    path = blob_path(dir, digest)

    unless path == nil or File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    :ok
  end

  def intern_blob(_host, _content, _digest), do: :ok

  defp read_blob(nil, _sha), do: {:error, "no objects_dir"}

  defp read_blob(dir, sha) do
    case blob_path(dir, sha) do
      nil ->
        {:error, "invalid sha"}

      path ->
        case File.read(path) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "missing"}
        end
    end
  end

  defp blob_path(dir, sha) when is_binary(sha) do
    if sha =~ ~r/^[0-9a-f]{64}$/ do
      Path.join([dir, String.slice(sha, 0, 2), sha])
    end
  end

  defp blob_path(_, _), do: nil

  # First-occurrence find/replace when the patch has a >>> separator;
  # otherwise the patch is the whole new body (file must already exist).
  defp apply_patch(current, patch) do
    case String.split(patch, ">>>", parts: 2) do
      [find, replace] -> String.replace(current, find, replace, global: false)
      _ -> patch
    end
  end

  # Summary value for a non-UTF-8 read: size, first 4 bytes as hex, and
  # up to 16 leading printable chars (e.g. a magic string like
  # "SQLite format 3").
  defp binary_summary(data) do
    size = byte_size(data)
    magic = data |> binary_part(0, min(4, size)) |> Base.encode16(case: :lower)

    head =
      data
      |> :binary.bin_to_list(0, min(16, size))
      |> Enum.take_while(&(&1 in 32..126))
      |> List.to_string()

    if head == "" do
      "<<binary file: #{size} bytes, magic #{magic}>>"
    else
      "<<binary file: #{size} bytes, magic #{magic} '#{head}'>>"
    end
  end

  defp tool(host, name, data), do: emit(host, "tool.call", Map.put(data, :tool, name))
  defp trap_event(host, data), do: emit(host, "execution.trap", data)
  defp emit(%{emit: emit}, type, data), do: emit.(type, data)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Timeout in ms for one gate command, from the host default."
  def timeout_ms(%__MODULE__{test_timeout_seconds: s}), do: s * 1000

  def cmd(host, command, timeout_ms), do: Cmd.sh(command, host.workspace, timeout_ms)
end
