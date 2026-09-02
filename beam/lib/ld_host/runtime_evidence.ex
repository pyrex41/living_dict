defmodule LdHost.RuntimeEvidence do
  @moduledoc """
  Independent verification of `wasm-durable-v1` evidence.

  The executor (`spike/wasm`) has execution and provider authority and emits
  a receipt with advisory `properties`. This module has neither. It reads the
  evidence files in the host-owned run directory and re-derives every
  property from them: oplog chain and continuity, route structure, effect
  intent/commit pairing under host-derived keys, the provider's own call log,
  checkpoint contents and host state, snapshot round trips, replay and
  recovery equivalence, fork lineage, crash-recovery consistency, and the
  engine attestation against an allowlist.

  `verify/2` returns the set of properties the evidence actually supports. A
  receipt that claims a property this module cannot establish is rejected.
  """

  alias LdHost.JCS

  @oplog "ld.oplog/v2"
  @checkpoint "ld.checkpoint/v1"
  @checkpoint_version 2
  @provider "ld.provider/v1"
  @kinds ~w(worker-creation invocation capability-request capability-result effect-intent effect-reissue effect-commit semantic-output checkpoint snapshot-roundtrip fault-injection resume claim-observation exit trap)
  @zero String.duplicate("0", 64)

  # Engine profiles this host accepts for wasm-durable-v1. The hash is over
  # the executor's `engine_settings()` (Wasmtime version and every
  # determinism-relevant switch); the world hash is over `wit/durable.wit`.
  @engine_allowlist %{
    "wasm-durable-v1" => %{
      config: ["09d09cde4ac6ecafd2aab3e1df7d9f4d49b39a6e97dda8d5002915907cd09620"],
      world: ["dff3a6146f4577a2751ee15abfdb754bd7c8edb292540886cd1349c0d2c13c20"]
    }
  }

  def engine_allowlist, do: @engine_allowlist

  @doc """
  Verify evidence under `dir` against `receipt`. Returns
  `{:ok, %{properties: MapSet.t(), summary: map()}}` or `{:error, reason}`.
  """
  def verify(dir, receipt) when is_map(receipt) do
    with :ok <- engine(receipt),
         {:ok, log} <- oplog(dir, receipt),
         {:ok, routes} <- routes(log, receipt),
         {:ok, parent} <- parent_history(routes),
         {:ok, effects} <- effects(log, receipt),
         {:ok, provider} <- provider_log(dir, receipt),
         {:ok, checkpoint} <- checkpoint(dir, receipt, log),
         {:ok, branch} <- branch(dir, receipt, log, routes) do
      props =
        MapSet.new()
        |> put_if(replay_stable?(routes, parent), ["replay-stable", "state-hash-stable"])
        |> put_if(checkpoint_recovered?(routes, parent, checkpoint), ["checkpoint-recovered"])
        |> put_if(branch.diverged, ["fork-diverged"])
        |> put_if(exactly_once?(effects, provider, routes), ["effects-exactly-once"])
        |> put_if(guest_hash_discriminates?(routes, parent, branch), ["guest-hash-discriminates"])
        |> maybe_crash_recovered(routes, parent)

      with :ok <- receipt_consistent(receipt, parent, routes, props) do
        {:ok,
         %{
           properties: props,
           summary: %{
             entries: length(log),
             routes: Map.keys(routes),
             committed: map_size(effects.committed),
             provider_executed: MapSet.size(provider.executed),
             resumed: Map.get(routes, "parent", []) |> Enum.any?(&(&1["kind"] == "resume"))
           }
         }}
      end
    end
  end

  # ------------------------------------------------------------ engine

  defp engine(receipt) do
    engine = receipt["engine"]
    allow = @engine_allowlist[receipt["profile"]]

    cond do
      not is_map(engine) ->
        {:error, "runtime receipt lacks engine attestation"}

      is_nil(allow) ->
        {:error, "no engine allowlist for profile"}

      engine["config_hash"] not in allow.config ->
        {:error, "engine configuration is not allowlisted"}

      engine["world_hash"] not in allow.world ->
        {:error, "component world is not allowlisted"}

      engine["wasmtime_version"] != "48.0.1" ->
        {:error, "wasmtime version is not allowlisted"}

      true ->
        :ok
    end
  end

  # ------------------------------------------------------------ oplog

  defp oplog(dir, receipt) do
    path = Path.join(dir, receipt["evidence"]["oplog"]["path"] || "oplog.jsonl")

    with {:ok, text} <- File.read(path),
         {:ok, entries} <- decode_lines(text),
         :ok <- chain(entries, receipt) do
      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "oplog unreadable"}
    end
  end

  defp decode_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case JSON.decode(line) do
        {:ok, m} when is_map(m) -> {:cont, {:ok, [m | acc]}}
        _ -> {:halt, {:error, "oplog line is not a JSON object"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp chain(entries, receipt) do
    worker = entries |> List.first(%{}) |> Map.get("worker")

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, @zero}, fn {e, i}, {:ok, prev} ->
      body = Map.delete(e, "entry_hash")

      ok? =
        e["schema"] == @oplog and e["sequence"] == i and e["previous_entry_hash"] == prev and
          e["component_hash"] == receipt["artifact_hash"] and e["worker"] == worker and
          e["scenario_seed"] == receipt["seed"] and e["kind"] in @kinds and
          is_binary(e["route"]) and JCS.hash!(body) == e["entry_hash"]

      if ok?,
        do: {:cont, {:ok, e["entry_hash"]}},
        else: {:halt, {:error, "oplog chain broken at entry #{i}"}}
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # ------------------------------------------------------------ routes

  defp routes(log, receipt) do
    routes = Enum.group_by(log, & &1["route"])
    replay_count = receipt["replay_count"]

    expected =
      ["parent", "recovered", "fork"] ++ Enum.map(1..max(replay_count, 1)//1, &"replay-#{&1}")

    cond do
      not is_integer(replay_count) or replay_count < 1 ->
        {:error, "replay_count must be positive"}

      Enum.any?(expected, &(not Map.has_key?(routes, &1))) ->
        {:error, "oplog is missing a required route"}

      Enum.any?(routes, fn {name, entries} ->
        name != "parent" and not well_formed_route?(entries)
      end) ->
        {:error, "a route is not a complete worker-creation .. exit history"}

      Enum.any?(routes, fn {name, entries} -> replay_route?(name) and live?(entries) end) ->
        {:error, "a replay route performed a live effect"}

      true ->
        {:ok, routes}
    end
  end

  defp replay_route?(name), do: name == "recovered" or String.starts_with?(name, "replay-")

  defp live?(entries),
    do:
      Enum.any?(entries, fn e ->
        e["kind"] in ["effect-intent", "effect-reissue", "effect-commit"] or
          (e["kind"] == "capability-result" and e["input"]["source"] == "provider")
      end)

  defp well_formed_route?([first | _] = entries) do
    first["kind"] == "worker-creation" and List.last(entries)["kind"] == "exit" and
      Enum.count(entries, &(&1["kind"] == "exit")) == 1 and
      Enum.count(entries, &(&1["kind"] == "worker-creation")) == 1 and
      invocations_continuous?(entries)
  end

  defp well_formed_route?(_), do: false

  # Each invocation's before-hash is the previous after-hash (or the
  # restore's resnapshot hash), and the after-hash is the snapshot hash it
  # reports.
  defp invocations_continuous?(entries) do
    start =
      case Enum.find(
             entries,
             &(&1["kind"] == "snapshot-roundtrip" and &1["input"]["at"] == "restore")
           ) do
        nil -> @zero
        e -> e["result"]["resnapshot_hash"]
      end

    entries
    |> Enum.filter(&(&1["kind"] == "invocation"))
    |> Enum.reduce_while({true, start, nil}, fn e, {_, prev, idx} ->
      i = e["input"]["event_index"]

      if e["state_hash_before"] == prev and e["result"]["snapshot_hash"] == e["state_hash_after"] and
           (is_nil(idx) or i == idx + 1) and is_integer(i) do
        {:cont, {true, e["state_hash_after"], i}}
      else
        {:halt, {false, prev, idx}}
      end
    end)
    |> elem(0)
  end

  # The parent route may contain several segments separated by `resume`
  # entries. Every segment before the last resume must end in a
  # fault-injection (a deliberate abort); the final one must be complete.
  defp parent_history(routes) do
    entries = routes["parent"]
    segments = split_on(entries, &(&1["kind"] == "resume"))
    {final, earlier} = List.pop_at(segments, -1)

    cond do
      not well_formed_route?(final) ->
        {:error, "parent route does not end in a complete history"}

      Enum.any?(earlier, fn seg -> List.last(seg)["kind"] != "fault-injection" end) ->
        {:error, "an interrupted parent segment has no recorded fault injection"}

      true ->
        {:ok, %{final: final, earlier: earlier, resumed: earlier != []}}
    end
  end

  defp split_on(list, pred) do
    Enum.reduce(list, [[]], fn e, [cur | rest] ->
      if pred.(e), do: [[] | [Enum.reverse(cur) | rest]], else: [[e | cur] | rest]
    end)
    |> then(fn [cur | rest] -> Enum.reverse([Enum.reverse(cur) | rest]) end)
  end

  # ------------------------------------------------------------ effects

  # Every intent/commit key is recomputed from the receipt's run identity
  # and the entry's logical position; commits pair one-to-one with intents.
  defp effects(log, receipt) do
    run_id =
      JCS.hash!(%{
        "config_hash" => receipt["machine_config_hash"],
        "scenario_id" => receipt["scenario_id"],
        "seed" => receipt["seed"]
      })

    if run_id != receipt["run_id"] do
      {:error, "run identity does not derive from config, scenario, and seed"}
    else
      log
      |> Enum.filter(
        &(&1["kind"] in ["effect-intent", "effect-reissue", "effect-commit", "capability-result"])
      )
      |> Enum.reduce_while({:ok, %{intents: MapSet.new(), committed: %{}}}, fn e, {:ok, acc} ->
        case check_effect(e, run_id, receipt["artifact_hash"], acc) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          {:error, r} -> {:halt, {:error, r}}
        end
      end)
    end
  end

  defp check_effect(%{"kind" => "capability-result"} = e, _run_id, _component, acc) do
    key = e["input"]["key"]

    case e["input"]["source"] do
      "journal" ->
        if Map.has_key?(acc.committed, key) and
             acc.committed[key].result_hash == e["result"]["result_hash"],
           do: {:ok, acc},
           else: {:error, "journal replay references an uncommitted or altered effect"}

      "provider" ->
        if Map.has_key?(acc.committed, key),
          do: {:ok, acc},
          else: {:error, "provider result delivered without a commit"}

      _ ->
        {:error, "capability-result has no source"}
    end
  end

  defp check_effect(e, run_id, component, acc) do
    input = e["input"]

    expected =
      JCS.hash!(%{
        "run_id" => run_id,
        "branch" => input["branch"],
        "component_hash" => component,
        "event_index" => input["event_index"],
        "effect_index" => input["effect_index"]
      })

    key = input["key"]

    cond do
      key != expected ->
        {:error, "effect key is not host-derived from its logical position"}

      e["kind"] == "effect-intent" and Map.has_key?(acc.committed, key) ->
        {:error, "intent recorded for an already committed effect"}

      e["kind"] == "effect-intent" ->
        {:ok, %{acc | intents: MapSet.put(acc.intents, key)}}

      e["kind"] == "effect-reissue" and not MapSet.member?(acc.intents, key) ->
        {:error, "reissue without a dangling intent"}

      e["kind"] == "effect-reissue" ->
        {:ok, acc}

      e["kind"] == "effect-commit" and Map.has_key?(acc.committed, key) ->
        {:error, "duplicate commit for one effect key"}

      e["kind"] == "effect-commit" and not MapSet.member?(acc.intents, key) ->
        {:error, "commit without a preceding intent"}

      e["kind"] == "effect-commit" ->
        result = e["result"]

        with {:ok, bytes} <- Base.decode16(result["result_hex"] || "", case: :lower),
             true <- sha256(bytes) == result["result_hash"] do
          committed =
            Map.put(acc.committed, key, %{
              name: input["name"],
              result_hash: result["result_hash"],
              branch: input["branch"]
            })

          {:ok, %{acc | intents: MapSet.delete(acc.intents, key), committed: committed}}
        else
          _ -> {:error, "commit result bytes do not match their hash"}
        end
    end
  end

  # ------------------------------------------------------------ provider

  defp provider_log(dir, receipt) do
    case receipt["evidence"]["provider_calls"] do
      nil ->
        {:ok, %{present: false, executed: MapSet.new(), results: %{}, over_executed: false}}

      %{"path" => rel} ->
        with {:ok, text} <- File.read(Path.join(dir, rel)),
             {:ok, entries} <- decode_lines(text),
             :ok <- provider_chain(entries) do
          {executed, results, over} =
            Enum.reduce(entries, {MapSet.new(), %{}, false}, fn e, {ex, res, over} ->
              case e["status"] do
                "executed" ->
                  {MapSet.put(ex, e["key"]), Map.put(res, e["key"], e["result_hash"]),
                   over or MapSet.member?(ex, e["key"])}

                _ ->
                  {ex, res, over}
              end
            end)

          {:ok, %{present: true, executed: executed, results: results, over_executed: over}}
        else
          {:error, r} -> {:error, r}
          _ -> {:error, "provider log unreadable"}
        end
    end
  end

  defp provider_chain(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, @zero}, fn {e, i}, {:ok, prev} ->
      body = Map.delete(e, "entry_hash")

      if e["schema"] == @provider and e["sequence"] == i and e["previous_hash"] == prev and
           JCS.hash!(body) == e["entry_hash"],
         do: {:cont, {:ok, e["entry_hash"]}},
         else: {:halt, {:error, "provider log chain broken at entry #{i}"}}
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp exactly_once?(effects, provider, routes) do
    committed = MapSet.new(Map.keys(effects.committed))

    live_commits =
      Enum.any?(routes, fn {_, entries} ->
        Enum.any?(entries, &(&1["kind"] == "effect-commit"))
      end)

    cond do
      MapSet.size(effects.intents) > 0 -> false
      not live_commits -> true
      not provider.present -> false
      provider.over_executed -> false
      not MapSet.equal?(provider.executed, committed) -> false
      true -> Enum.all?(effects.committed, fn {k, c} -> provider.results[k] == c.result_hash end)
    end
  end

  # ------------------------------------------------------------ checkpoint

  defp checkpoint(dir, receipt, log) do
    rel = receipt["evidence"]["checkpoint"]["path"] || "checkpoint.json"

    with {:ok, text} <- File.read(Path.join(dir, rel)),
         {:ok, cp} <- JSON.decode(text),
         {:ok, bytes} <- Base.decode16(cp["bytes"] || "", case: :lower),
         entry when is_map(entry) <-
           log |> Enum.filter(&(&1["kind"] == "checkpoint")) |> List.last(),
         true <- cp["schema"] == @checkpoint and cp["schema_version"] == @checkpoint_version,
         true <- cp["component_hash"] == receipt["artifact_hash"],
         true <- sha256(bytes) == cp["bytes_hash"],
         true <- entry["result"]["snapshot_hash"] == cp["bytes_hash"],
         true <- entry["input"]["index"] == cp["oplog_index"],
         true <- entry["input"]["host"] == cp["host"],
         true <- entry["input"]["branch"] == cp["branch"],
         true <-
           is_map(cp["host"]) and is_integer(cp["host"]["event_index"]) and
             cp["host"]["event_index"] == cp["oplog_index"] do
      {:ok, cp}
    else
      {:error, r} when is_binary(r) -> {:error, r}
      _ -> {:error, "checkpoint does not match the oplog"}
    end
  end

  # ------------------------------------------------------------ branch

  defp branch(dir, receipt, log, routes) do
    rel = receipt["evidence"]["branch"]["path"] || "branches/fork/manifest.json"
    hashes = MapSet.new(log, & &1["entry_hash"])
    fork = routes["fork"]

    prefix_frames =
      fork
      |> Enum.filter(&(&1["kind"] == "invocation" and &1["input"]["branch"] == "parent"))
      |> Enum.map(& &1["input"]["frame"])

    fork_exit = List.last(fork)

    with {:ok, text} <- File.read(Path.join(dir, rel)),
         {:ok, m} <- JSON.decode(text),
         true <- m["schema"] == "ld.branch/v1" and m["branch_id"] == "fork",
         true <- MapSet.member?(hashes, m["parent_final_oplog_hash"]),
         true <- m["cutoff_index"] == length(prefix_frames),
         true <- m["cutoff_hash"] == JCS.hash!(prefix_frames),
         true <- m["final_snapshot_hash"] == fork_exit["result"]["snapshot_hash"],
         true <- receipt["fork"]["final_state_hash"] == m["final_snapshot_hash"] do
      parent_hash = routes["parent"] |> List.last() |> get_in(["result", "snapshot_hash"])

      {:ok,
       %{
         diverged: m["final_snapshot_hash"] != parent_hash,
         guest_hash: fork_exit["result"]["guest_state_hash"]
       }}
    else
      _ -> {:error, "branch manifest does not match the oplog"}
    end
  end

  # ------------------------------------------------------------ properties

  defp transitions(entries),
    do:
      entries
      |> Enum.filter(&(&1["kind"] == "invocation"))
      |> Enum.map(
        &{&1["input"]["event_index"], &1["result"]["frame_hash"], &1["state_hash_after"]}
      )

  defp exit_of(entries), do: List.last(entries)

  defp roundtrips_ok?(entries),
    do:
      Enum.all?(entries, fn e ->
        e["kind"] != "snapshot-roundtrip" or e["result"]["equal"] == true
      end)

  defp replay_stable?(routes, parent) do
    pexit = exit_of(parent.final)
    ptrans = transitions(parent.final)

    roundtrips_ok?(parent.final) and
      routes
      |> Enum.filter(fn {name, _} -> String.starts_with?(name, "replay-") end)
      |> Enum.all?(fn {_, entries} ->
        rexit = exit_of(entries)

        roundtrips_ok?(entries) and transitions(entries) == ptrans and
          rexit["result"]["snapshot_hash"] == pexit["result"]["snapshot_hash"] and
          rexit["result"]["host"] == pexit["result"]["host"] and rexit["result"]["live"] == 0
      end)
  end

  defp checkpoint_recovered?(routes, parent, cp) do
    rec = routes["recovered"]
    rexit = exit_of(rec)
    pexit = exit_of(parent.final)
    creation = List.first(rec)

    restore =
      Enum.find(rec, &(&1["kind"] == "snapshot-roundtrip" and &1["input"]["at"] == "restore"))

    suffix =
      parent.final |> transitions() |> Enum.filter(fn {i, _, _} -> i >= cp["oplog_index"] end)

    is_map(restore) and restore["result"]["equal"] == true and
      restore["result"]["resnapshot_hash"] == cp["bytes_hash"] and
      creation["input"]["host"] == cp["host"] and
      creation["input"]["resumed_from_checkpoint"] == true and
      roundtrips_ok?(rec) and transitions(rec) == suffix and
      rexit["result"]["snapshot_hash"] == pexit["result"]["snapshot_hash"] and
      rexit["result"]["host"] == pexit["result"]["host"] and rexit["result"]["live"] == 0
  end

  defp guest_hash_discriminates?(routes, parent, branch) do
    pguest = exit_of(parent.final)["result"]["guest_state_hash"]

    replays_agree =
      routes
      |> Enum.filter(fn {name, _} -> replay_route?(name) end)
      |> Enum.all?(fn {_, entries} ->
        exit_of(entries)["result"]["guest_state_hash"] == pguest
      end)

    replays_agree and (not branch.diverged or branch.guest_hash != pguest)
  end

  defp maybe_crash_recovered(props, _routes, %{resumed: false}), do: props

  defp maybe_crash_recovered(props, _routes, parent) do
    final = transitions(parent.final)

    ok? =
      parent.earlier
      |> Enum.flat_map(&transitions/1)
      |> Enum.all?(fn t -> t in final end)

    put_if(props, ok?, ["crash-recovered"])
  end

  defp put_if(set, true, items), do: Enum.reduce(items, set, &MapSet.put(&2, &1))
  defp put_if(set, false, _), do: set

  # ------------------------------------------------------------ receipt

  defp receipt_consistent(receipt, parent, routes, props) do
    pexit = exit_of(parent.final)
    claimed = MapSet.new(receipt["properties"] || [])
    replays = routes |> Map.keys() |> Enum.count(&String.starts_with?(&1, "replay-"))

    cond do
      receipt["final_state_hash"] != pexit["result"]["snapshot_hash"] ->
        {:error, "receipt final state does not match the parent route"}

      receipt["guest_state_hash"] != pexit["result"]["guest_state_hash"] ->
        {:error, "receipt guest hash does not match the parent route"}

      receipt["replay_count"] != replays ->
        {:error, "receipt replay count does not match the oplog"}

      not MapSet.subset?(claimed, props) ->
        missing = claimed |> MapSet.difference(props) |> Enum.sort() |> Enum.join(", ")
        {:error, "receipt claims properties the evidence does not establish: #{missing}"}

      receipt["recovery"]["resumed"] != parent.resumed ->
        {:error, "receipt recovery flag disagrees with the oplog"}

      true ->
        :ok
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
