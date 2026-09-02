defmodule LdHost.RuntimeProfiles do
  @moduledoc "Host-owned, literal dispatch for runtime evidence profiles."
  alias LdHost.Cmd
  @protocol "ld.runtime.receipt/v1"
  @required ~w(protocol profile artifact_hash machine_config_hash scenario_id seed oplog_hash checkpoint_hash final_state_hash semantic_output_hash replay_count replay_equal fork effects limits traps properties evidence passed reason)

  def run(workspace, claim) do
    with {:ok, executable} <- executable(claim.profile),
         {:ok, config} <- confined_file(workspace, claim.config),
         evidence <- evidence_dir(workspace, claim.id),
         :ok <- File.mkdir_p(evidence),
         argv = [
           "run",
           "--workspace",
           Path.expand(workspace),
           "--run-dir",
           evidence,
           "--claim-id",
           claim.id,
           "--config",
           config,
           "--timeout-ms",
           Integer.to_string(claim.timeout_seconds * 1000)
         ],
         outcome <- Cmd.exec(executable, argv, workspace, claim.timeout_seconds * 1000),
         :ok <- if(outcome.timed_out, do: {:error, "runtime profile timed out"}, else: :ok),
         {:ok, receipt} when is_map(receipt) <- JSON.decode(outcome.output),
         :ok <- validate(receipt, claim.profile),
         :ok <- validate_hashes(receipt, config, evidence),
         :ok <- properties(receipt, claim.must),
         true <-
           (outcome.returncode == 0 and receipt["passed"] == true) ||
             {:error, bounded(receipt["reason"] || "runtime failed")} do
      %{passed: true, receipt: receipt}
    else
      {:error, reason} -> %{passed: false, reason: reason}
      _ -> %{passed: false, reason: "runtime profile emitted malformed receipt"}
    end
  end

  @doc "Revalidate a stored runtime receipt against confined config, artifact, and evidence files."
  def verify_receipt(workspace, config_rel, evidence_dir, receipt) when is_map(receipt) do
    with {:ok, config} <- confined_file(workspace, config_rel),
         :ok <- validate(receipt, receipt["profile"]),
         :ok <- validate_hashes(receipt, config, evidence_dir) do
      :ok
    end
  end

  defp executable("wasm-durable-v1") do
    path = Path.expand("../../../spike/wasm/target/release/ld-wasm", __DIR__)
    if File.regular?(path), do: {:ok, path}, else: {:error, "profile not installed"}
  end

  defp executable(profile), do: {:error, "unknown runtime profile: #{profile}"}

  defp confined_file(workspace, rel) when is_binary(rel) and rel != "" do
    with root when is_binary(root) <- canonical(workspace),
         resolved when is_binary(resolved) <- canonical(Path.expand(rel, root)),
         true <- File.regular?(resolved) and String.starts_with?(resolved, root <> "/") do
      {:ok, resolved}
    else
      _ -> {:error, "runtime config must resolve beneath workspace"}
    end
  end

  defp confined_file(_, _), do: {:error, "runtime config must resolve beneath workspace"}

  defp evidence_dir(workspace, id) do
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join([workspace, ".livingdict-run", "runtime", id, nonce])
  end

  defp validate(receipt, profile) do
    missing = Enum.reject(@required, &Map.has_key?(receipt, &1))

    cond do
      missing != [] ->
        {:error, "runtime receipt is missing required evidence"}

      receipt["protocol"] != @protocol ->
        {:error, "runtime receipt protocol mismatch"}

      receipt["profile"] != profile ->
        {:error, "runtime receipt profile mismatch"}

      not is_binary(receipt["scenario_id"]) or receipt["scenario_id"] == "" ->
        {:error, "runtime receipt scenario type mismatch"}

      not is_integer(receipt["seed"]) or not is_integer(receipt["replay_count"]) ->
        {:error, "runtime receipt numeric type mismatch"}

      not is_boolean(receipt["replay_equal"]) or not is_boolean(receipt["passed"]) ->
        {:error, "runtime receipt boolean type mismatch"}

      not is_list(receipt["properties"]) or not Enum.all?(receipt["properties"], &is_binary/1) ->
        {:error, "runtime receipt properties type mismatch"}

      not is_map(receipt["fork"]) or not is_map(receipt["effects"]) or
        not is_map(receipt["limits"]) or not is_map(receipt["evidence"]) ->
        {:error, "runtime receipt container type mismatch"}

      receipt["passed"] and
          (receipt["replay_equal"] != true or receipt["fork"]["diverged"] != true) ->
        {:error, "runtime receipt invariants disagree"}

      Enum.any?(
        ~w(artifact_hash machine_config_hash oplog_hash checkpoint_hash final_state_hash semantic_output_hash),
        &(not sha256?(receipt[&1]))
      ) ->
        {:error, "runtime receipt hash syntax mismatch"}

      true ->
        :ok
    end
  end

  defp validate_hashes(receipt, config, evidence) do
    with {:ok, config_bytes} <- File.read(config),
         true <-
           digest(config_bytes) == receipt["machine_config_hash"] ||
             {:error, "runtime config hash mismatch"},
         {:ok, component_rel} <- component_path(config_bytes),
         {:ok, component} <- confined_file(Path.dirname(config), component_rel),
         {:ok, component_bytes} <- File.read(component),
         true <-
           digest(component_bytes) == receipt["artifact_hash"] ||
             {:error, "runtime artifact hash mismatch"},
         :ok <- validate_evidence(receipt["evidence"], evidence),
         true <-
           receipt["oplog_hash"] == get_in(receipt, ["evidence", "oplog", "sha256"]) ||
             {:error, "runtime oplog hash mismatch"},
         true <-
           receipt["checkpoint_hash"] == get_in(receipt, ["evidence", "checkpoint", "sha256"]) ||
             {:error, "runtime checkpoint hash mismatch"} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "runtime evidence validation failed"}
    end
  end

  defp validate_evidence(entries, root) do
    Enum.reduce_while(entries, :ok, fn {_name, item}, :ok ->
      with true <- is_map(item) and is_binary(item["path"]) and sha256?(item["sha256"]),
           {:ok, path} <- confined_file(root, item["path"]),
           {:ok, bytes} <- File.read(path),
           true <- digest(bytes) == item["sha256"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, "runtime evidence file missing or hash mismatch"}}
      end
    end)
  end

  defp component_path(bytes) do
    case Regex.run(~r/^component\s*=\s*"([^"]+)"\s*$/m, bytes) do
      [_, path] -> {:ok, path}
      _ -> {:error, "runtime config component missing"}
    end
  end

  defp sha256?(x), do: is_binary(x) and Regex.match?(~r/\A[0-9a-f]{64}\z/, x)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp canonical(path) do
    expanded = Path.expand(path)
    resolve_parts(String.split(expanded, "/", trim: true), "/", 0)
  end

  defp resolve_parts(_, _, depth) when depth > 40, do: nil
  defp resolve_parts([], current, _depth), do: if(File.exists?(current), do: current)

  defp resolve_parts([part | rest], current, depth) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, target} ->
            target =
              if Path.type(target) == :absolute, do: target, else: Path.expand(target, current)

            resolve_parts(
              String.split(Path.join([target | rest]), "/", trim: true),
              "/",
              depth + 1
            )

          _ ->
            nil
        end

      {:ok, _} ->
        resolve_parts(rest, candidate, depth)

      _ ->
        nil
    end
  end

  defp properties(receipt, required) do
    actual = MapSet.new(receipt["properties"] || [])
    missing = Enum.reject(required || [], &MapSet.member?(actual, &1))

    if missing == [],
      do: :ok,
      else: {:error, "runtime properties not satisfied: #{Enum.join(missing, ", ")}"}
  end

  defp bounded(value), do: value |> to_string() |> String.slice(0, 500)
end
