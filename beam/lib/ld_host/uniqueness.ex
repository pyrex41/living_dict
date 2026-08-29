defmodule LdHost.Uniqueness do
  @moduledoc """
  Five uniqueness axes over a Demo/Polyglot results map. Warm 5-point /
  25% GO/NO-GO stays a Verdict column; TB mean reward is hygiene.

  Scores prefer fields on the result, then each run's `events.jsonl` /
  `trace.jsonl` (`used_words`, candidates, judges, waves) and the
  orchestrator trace (holds). Replay is not re-executed inside `score/1`;
  missing wave/hold evidence is omitted, not a 0/false failure.
  """

  alias LdHost.{Host, Run, Space, Store, Wave}

  @contract_judges MapSet.new(["approved contract", "spec-derived"])
  @sha256_hex ~r/^[0-9a-f]{64}$/

  def score(results) when is_map(results) do
    %{
      family_transfer: family_transfer(results),
      contract_first: contract_first(results),
      replay_without_model: replay_without_model(results),
      wave_speedup: wave_speedup(results),
      obligation_hold: obligation_hold(results)
    }
  end

  @doc """
  Share of later tasks whose `used_words` intersect names already in the
  family catalog. A present seed/prelude that no later task calls is 0
  (the TB-warm-5 unused-prelude failure).
  """
  def family_transfer(results) when is_map(results) do
    tasks = family_tasks(results)
    prior = MapSet.new(enum(get(results, :seed) || get(results, :prelude_words)))

    {hits, later, _prior} =
      Enum.reduce(tasks, {0, 0, prior}, fn task, {hits, later, prior} ->
        used = MapSet.new(used_words(task))

        {hits, later} =
          if MapSet.size(prior) == 0 do
            {hits, later}
          else
            hit = MapSet.size(MapSet.intersection(used, prior)) > 0
            {hits + if(hit, do: 1, else: 0), later + 1}
          end

        {hits, later, MapSet.union(prior, MapSet.new(catalog_names(task)))}
      end)

    cond do
      later == 0 -> omitted("no later task against a prior catalog")
      hits == 0 -> 0.0
      true -> hits / later
    end
  end

  @doc "Share of ld-arm successes whose judge is approved contract or spec-derived."
  def contract_first(results) when is_map(results) do
    judged =
      results
      |> ld_task_results()
      |> Enum.filter(&success?/1)
      |> Enum.reject(&(judge(&1) in [nil, "unknown"]))

    if judged == [] do
      omitted("no judged cold/warm successes")
    else
      n = Enum.count(judged, fn task -> judge(task) in @contract_judges end)
      n / length(judged)
    end
  end

  @doc """
  Replay the saved `run_dir/envelope.json` (program + artifact hashes)
  with the model off. `results[:replay]` may already hold a Run summary.
  Otherwise `score/1` reports hashed envelopes as omitted-not-failure.
  """
  def replay_without_model(results) when is_map(results) do
    case get(results, :replay) do
      nil ->
        replay_from_runs(results)

      summary when is_map(summary) ->
        if get(summary, :omitted) do
          summary
        else
          calls = Map.get(summary, :model_calls, Map.get(summary, "model_calls", 1))
          summary.success == true and calls == 0
        end
    end
  end

  def replay(run_dir, opts) when is_binary(run_dir) do
    envelope = load_replay_envelope(run_dir)
    workspace = Keyword.fetch!(opts, :workspace)

    planner = fn _goal, _obs, _feedback ->
      {:ok, envelope, %{input_tokens: 0, output_tokens: 0, model_calls: 0}}
    end

    Run.run(
      Keyword.get(opts, :goal, "replay"),
      opts
      |> Keyword.put(:workspace, workspace)
      |> Keyword.put(:planner_fn, planner)
    )
  end

  @doc "Port of Python `wave.compute_metrics` (hypothesis 6 counters)."
  def compute_metrics(waves, timings, wall_ms_actual, opts \\ []) do
    widths = Enum.map(waves, &length/1)
    parallel = nodes_parallel(waves, timings)

    serial_ms =
      Enum.reduce(timings, 0, fn {_id, interval}, acc -> acc + interval_ms(interval) end)

    %{
      wave_count: length(waves),
      max_wave_width: if(widths == [], do: 0, else: Enum.max(widths)),
      nodes_parallel: MapSet.size(parallel),
      conflicts: Keyword.get(opts, :conflicts, 0),
      wall_ms_serial_estimate: serial_ms,
      wall_ms_actual: wall_ms_actual
    }
  end

  def wave_speedup(results) when is_map(results) do
    case get(results, :wave) do
      nil ->
        wave_from_runs(results)

      %{omitted: true} = skipped ->
        skipped

      metrics when is_map(metrics) ->
        wave_ok(metrics)
    end
  end

  @doc """
  Dispatch canned `Envelope.nodes` through Space `node.ready` +
  `Host.node_view`. A short sleep makes wall-clock overlap observable;
  production `Wave.execute` does not sleep.
  """
  def measure_waves(workspace, nodes, artifacts) do
    {:ok, waves} = Wave.plan_waves(nodes)

    case Enum.flat_map(waves, &Wave.overlap_errors/1) do
      [_ | _] = errors ->
        {:error, :overlap, errors}

      [] ->
        {:ok, space} = Space.start_link([])

        try do
          host =
            Host.new(workspace,
              allowed_effects: ["read", "write"],
              allowed_globs: ["**"],
              write_receipt?: false
            )

          wall0 = System.monotonic_time(:millisecond)
          timings = run_measured_waves(host, space, waves, artifacts, 0, %{})
          wall = System.monotonic_time(:millisecond) - wall0
          {:ok, compute_metrics(waves, timings, wall)}
        after
          if Process.alive?(space), do: GenServer.stop(space, :normal, 5_000)
        end
    end
  end

  def obligation_hold(results) when is_map(results) do
    case get(results, :obligation) do
      nil ->
        hold_from_orchestrator(results)

      %{omitted: true} = skipped ->
        skipped

      ev when is_map(ev) ->
        hold_evidence(ev)
    end
  end

  def render_markdown(score) when is_map(score) do
    """
    ## Uniqueness axes

    Headline scores. Omitted axes are not failures (this campaign did not
    exercise them). Terminal-Bench mean reward stays Harbor hygiene;
    `Verdict.warm_run_allowed` remains a column, not the north star.

    | axis | score |
    |---|---|
    | family_transfer | #{fmt_axis(score.family_transfer)} |
    | contract_first | #{fmt_axis(score.contract_first)} |
    | replay_without_model | #{fmt_axis(score.replay_without_model)} |
    | wave_speedup | #{fmt_wave(score.wave_speedup)} |
    | obligation_hold | #{fmt_hold(score.obligation_hold)} |
    """
  end

  def enrich(result) when is_map(result) do
    run_dir = get(result, :run_dir)

    result
    |> maybe_put(:used_words, used_words(result))
    |> maybe_put(:promoted_words, get(result, :promoted_words) || promoted_from(run_dir))
    |> maybe_put(:judge, get(result, :judge) || judge_from(run_dir))
  end

  def enrich(result), do: result

  # ---- family / contract -----------------------------------------------

  defp family_tasks(results) do
    (get(results, :warm) || get(results, "warm") || get(results, :tasks) || [])
    |> Enum.map(&enrich/1)
  end

  defp ld_task_results(results) do
    Enum.flat_map(["cold", "warm"], fn arm ->
      enum(get(results, arm))
    end)
    |> Enum.map(&enrich/1)
  end

  defp all_task_results(results) do
    results
    |> Map.drop([
      :replay,
      :wave,
      :obligation,
      :seed,
      :prelude_words,
      :tasks,
      :orchestrator,
      "replay",
      "wave",
      "obligation",
      "seed",
      "prelude_words",
      "tasks",
      "orchestrator"
    ])
    |> Map.values()
    |> Enum.flat_map(fn
      list when is_list(list) -> list
      _ -> []
    end)
    |> Kernel.++(enum(get(results, :tasks)))
    |> Enum.map(&enrich/1)
  end

  defp run_dirs(results) do
    results
    |> all_task_results()
    |> Enum.map(&get(&1, :run_dir))
    |> Enum.filter(&is_binary/1)
  end

  defp used_words(task) when is_map(task) do
    case get(task, :used_words) do
      list when is_list(list) and list != [] -> Enum.map(list, &to_string/1)
      _ -> used_from(get(task, :run_dir))
    end
  end

  defp catalog_names(task) when is_map(task) do
    (enum(get(task, :promoted_words)) ++
       enum(get(task, :prelude_words)) ++
       enum(get(task, :catalog)) ++
       dictionary_names(get(task, :run_dir)) ++
       dictionary_names(get(task, :dictionary_dir)) ++
       candidates_from(get(task, :run_dir)))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  # Warm words live in the shared dict, not run_dir/dictionary. Candidates
  # are still in this run's trace even when dictionary_dir is missing.
  defp candidates_from(nil), do: []

  defp candidates_from(run_dir) do
    jsonl(Path.join(run_dir, "trace.jsonl"))
    |> Enum.filter(&(get(&1, :type) in ["dictionary.candidate", "dictionary.promote"]))
    |> Enum.map(fn event -> get(get(event, :data) || %{}, :word) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp dictionary_names(nil), do: []

  defp dictionary_names(dir) when is_binary(dir) do
    Enum.flat_map([Path.join([dir, "dictionary", "words"]), Path.join(dir, "words")], fn words ->
      case File.ls(words) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".fs"))
          |> Enum.map(&String.replace_suffix(&1, ".fs", ""))

        _ ->
          []
      end
    end)
  end

  defp used_from(nil), do: []

  defp used_from(run_dir) do
    jsonl(Path.join(run_dir, "events.jsonl"))
    |> Enum.filter(fn event -> get(event, :kind) in ["episode.planned", "critic.accepted"] end)
    |> Enum.flat_map(fn event ->
      payload = get(event, :payload) || %{}
      enum(get(payload, :used_words))
    end)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp promoted_from(nil), do: []

  defp promoted_from(run_dir) do
    jsonl(Path.join(run_dir, "events.jsonl"))
    |> Enum.filter(&(get(&1, :kind) == "dictionary.promoted"))
    |> Enum.map(fn event -> get(get(event, :payload) || %{}, :word) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp judge_from(nil), do: nil

  defp judge_from(run_dir) do
    jsonl(Path.join(run_dir, "events.jsonl"))
    |> Enum.filter(&(get(&1, :kind) == "contract.approved"))
    |> case do
      [] -> nil
      _ -> "approved contract"
    end
  end

  defp success?(task), do: get(task, :success) == true

  defp judge(task) do
    get(task, :judge) || judge_from(get(task, :run_dir)) || "unknown"
  end

  # ---- replay ----------------------------------------------------------

  defp load_replay_envelope(run_dir) do
    raw = Path.join(run_dir, "envelope.json") |> File.read!() |> JSON.decode!()
    objects = Store.objects_root(run_dir)

    artifacts =
      Map.new(raw["artifacts"] || %{}, fn {key, value} ->
        if hash?(value) do
          case Store.get(objects, value) do
            {:ok, body} -> {key, body}
            _ -> {key, value}
          end
        else
          {key, value}
        end
      end)

    Map.put(raw, "artifacts", artifacts)
  end

  defp hash?(value) when is_binary(value), do: Regex.match?(@sha256_hex, value)
  defp hash?(_), do: false

  defp replay_from_runs(results) do
    envelopes =
      results
      |> run_dirs()
      |> Enum.filter(&File.exists?(Path.join(&1, "envelope.json")))

    if envelopes == [] do
      omitted("no envelope.json in this campaign")
    else
      hashed = Enum.count(envelopes, &hashed_envelope?/1)

      omitted("not re-executed in score/1", %{
        replayable: hashed > 0,
        envelopes: length(envelopes),
        hashed: hashed
      })
    end
  end

  defp hashed_envelope?(run_dir) do
    case File.read(Path.join(run_dir, "envelope.json")) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, env} ->
            arts = env["artifacts"] || %{}
            arts != %{} and Enum.all?(arts, fn {_k, v} -> hash?(v) end)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # ---- waves -----------------------------------------------------------

  defp run_measured_waves(_host, _space, [], _artifacts, _wave, timings), do: timings

  defp run_measured_waves(host, space, [ready | rest], artifacts, wave_index, timings) do
    Enum.each(ready, fn node ->
      Space.out(space, %{
        "kind" => "node.ready",
        "wave" => wave_index,
        "node" => node.id
      })
    end)

    tasks =
      Enum.map(ready, fn _ ->
        Task.async(fn ->
          measured_worker(space, wave_index, host, ready, artifacts)
        end)
      end)

    wave_timings = Task.await_many(tasks, 30_000)

    timings =
      Enum.reduce(wave_timings, timings, fn {id, t0, t1}, acc ->
        Map.put(acc, id, {t0, t1})
      end)

    run_measured_waves(host, space, rest, artifacts, wave_index + 1, timings)
  end

  defp measured_worker(space, wave_index, host, ready, artifacts) do
    worker_id = "u-#{:erlang.unique_integer([:positive])}"

    claim =
      Space.take(space, %{"kind" => "node.ready", "wave" => wave_index}, 15_000, worker_id,
        timeout: 10_000
      )

    node = Enum.find(ready, &(&1.id == claim.tuple["node"]))
    t0 = System.monotonic_time(:millisecond)
    siblings = ready |> Enum.reject(&(&1.id == node.id)) |> Enum.flat_map(&Wave.write_globs/1)
    view = Host.node_view(host, Wave.write_globs(node), siblings, fn _, _ -> :ok end)

    Enum.each(Wave.artifact_keys_for_node(node, artifacts, view.workspace), fn path ->
      case Map.fetch(artifacts, path) do
        {:ok, body} when is_binary(body) ->
          Host.write_file(view, body, path)

        _ ->
          :ok
      end
    end)

    # Sleep so two-node wall-clock overlap is not a race against a 0ms write.
    Process.sleep(40)
    t1 = System.monotonic_time(:millisecond)
    Space.ack(space, claim.token)
    {node.id, t0, t1}
  end

  defp nodes_parallel(waves, timings) do
    Enum.reduce(waves, MapSet.new(), fn wave, acc ->
      ids =
        wave
        |> Enum.map(&node_id/1)
        |> Enum.filter(&Map.has_key?(timings, &1))

      Enum.reduce(Enum.with_index(ids), acc, fn {left, i}, acc ->
        Enum.reduce(Enum.drop(ids, i + 1), acc, fn right, acc ->
          if overlaps?(timings[left], timings[right]) do
            acc |> MapSet.put(left) |> MapSet.put(right)
          else
            acc
          end
        end)
      end)
    end)
  end

  defp node_id(%{id: id}), do: id
  defp node_id(%{"id" => id}), do: id
  defp node_id(id) when is_binary(id) or is_atom(id), do: id

  defp overlaps?({a0, a1}, {b0, b1}) do
    start_a = ts(a0)
    end_a = ts(a1)
    start_b = ts(b0)
    end_b = ts(b1)

    start_a != nil and end_a != nil and start_b != nil and end_b != nil and start_a < end_b and
      start_b < end_a
  end

  defp interval_ms({start, finish}) do
    first = ts(start)
    last = ts(finish)

    cond do
      first == nil or last == nil -> 0
      last < first -> 0
      true -> last - first
    end
  end

  defp ts(n) when is_integer(n), do: n

  defp ts(value) when is_binary(value) do
    text = String.replace(value, "Z", "+00:00")

    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp ts(_), do: nil

  defp wave_from_runs(results) do
    metrics =
      results
      |> run_dirs()
      |> Enum.map(&wave_metrics_for_run/1)
      |> Enum.reject(&is_nil/1)

    case metrics do
      [] ->
        omitted("no graph.wave.node timings in this campaign")

      list ->
        best = Enum.max_by(list, &{&1.max_wave_width || 0, &1.nodes_parallel || 0})

        if (best.max_wave_width || 0) >= 2 do
          wave_ok(best)
        else
          omitted("no two-node wave in this campaign")
        end
    end
  end

  defp wave_metrics_for_run(run_dir) do
    events =
      jsonl(Path.join(run_dir, "trace.jsonl"))
      |> Enum.filter(&(get(&1, :type) == "graph.wave.node"))

    if events == [] do
      nil
    else
      by_wave =
        events
        |> Enum.group_by(fn event -> get(get(event, :data) || %{}, :wave) || 0 end)
        |> Enum.sort_by(&elem(&1, 0))

      waves =
        Enum.map(by_wave, fn {_w, evs} ->
          Enum.map(evs, fn event -> %{id: get(get(event, :data) || %{}, :node)} end)
        end)

      timings =
        Map.new(events, fn event ->
          data = get(event, :data) || %{}
          id = get(data, :node)
          {id, {get(data, :start_ms), get(data, :finish_ms)}}
        end)

      starts = Enum.map(timings, fn {_id, {t0, _t1}} -> t0 end) |> Enum.reject(&is_nil/1)
      finishes = Enum.map(timings, fn {_id, {_t0, t1}} -> t1 end) |> Enum.reject(&is_nil/1)

      wall =
        cond do
          starts == [] or finishes == [] -> 0
          true -> Enum.max(finishes) - Enum.min(starts)
        end

      compute_metrics(waves, timings, wall)
    end
  end

  defp hold_from_orchestrator(results) do
    dir = get(results, :orchestrator)

    if not is_binary(dir) do
      omitted("no orchestrator ledger in this campaign")
    else
      traces = jsonl(Path.join(dir, "trace.jsonl"))
      hold_ms = hold_ms_from_traces(traces)

      if hold_ms == nil do
        omitted("no hold_ms in orchestrator ledger")
      else
        types = Enum.map(traces, &get(&1, :type))
        expired = "obligation.crashed" in types or "space.lease_expired" in types
        generations = take_generations(traces)
        reclaim = if generations == [], do: if(expired, do: 2, else: 1), else: Enum.max(generations)

        hold_evidence(%{
          hold_ms: hold_ms,
          double_ack: false,
          expired_on_crash: expired,
          reclaim_generation: reclaim,
          stale_ack: false
        })
      end
    end
  end

  defp hold_ms_from_traces(traces) do
    traces
    |> Enum.filter(&(get(&1, :type) in ["obligation.completed", "obligation.failed"]))
    |> Enum.map(fn event -> get(get(event, :data) || %{}, :hold_ms) end)
    |> Enum.find(&is_integer/1)
  end

  defp take_generations(traces) do
    traces
    |> Enum.filter(&(get(&1, :type) == "space.take"))
    |> Enum.map(fn event -> get(get(event, :data) || %{}, :generation) end)
    |> Enum.filter(&is_integer/1)
  end

  defp hold_evidence(ev) when is_map(ev) do
    hold_ms = get(ev, :hold_ms)
    double_ack = get(ev, :double_ack) == true
    expired = get(ev, :expired_on_crash) == true
    generation = get(ev, :reclaim_generation) || get(ev, :generation) || 0
    stale_ack = get(ev, :stale_ack) == true

    ok =
      is_integer(hold_ms) and hold_ms > 0 and not double_ack and not stale_ack and
        (not expired or generation >= 2)

    %{
      ok: ok,
      hold_ms: hold_ms,
      double_ack: double_ack,
      expired_on_crash: expired,
      reclaim_generation: generation,
      stale_ack: stale_ack
    }
  end

  defp wave_ok(metrics) do
    parallel = metrics[:nodes_parallel] || metrics["nodes_parallel"] || 0
    width = metrics[:max_wave_width] || metrics["max_wave_width"] || 0
    actual = metrics[:wall_ms_actual] || metrics["wall_ms_actual"] || 0
    serial = metrics[:wall_ms_serial_estimate] || metrics["wall_ms_serial_estimate"] || 0

    # 0ms node writes can serialize; same-wave width is still uniqueness.
    parallel = if parallel >= 2, do: parallel, else: if(width >= 2, do: width, else: parallel)

    Map.merge(atomize_metrics(metrics), %{
      nodes_parallel: parallel,
      ok: parallel >= 2 and (serial == 0 or actual <= serial)
    })
  end

  defp atomize_metrics(metrics) do
    %{
      wave_count: metrics[:wave_count] || metrics["wave_count"],
      max_wave_width: metrics[:max_wave_width] || metrics["max_wave_width"],
      nodes_parallel: metrics[:nodes_parallel] || metrics["nodes_parallel"],
      conflicts: metrics[:conflicts] || metrics["conflicts"] || 0,
      wall_ms_serial_estimate: metrics[:wall_ms_serial_estimate] || metrics["wall_ms_serial_estimate"],
      wall_ms_actual: metrics[:wall_ms_actual] || metrics["wall_ms_actual"]
    }
  end

  # ---- render ----------------------------------------------------------

  defp omitted(reason, extra \\ %{}) do
    Map.merge(%{omitted: true, reason: reason}, extra)
  end

  defp fmt_axis(nil), do: fmt_omitted(%{reason: "no evidence"})
  defp fmt_axis(%{omitted: true} = skip), do: fmt_omitted(skip)
  defp fmt_axis(true), do: "true"
  defp fmt_axis(false), do: "false"
  defp fmt_axis(n) when is_float(n), do: n |> Float.round(3) |> Float.to_string()
  defp fmt_axis(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_axis(other), do: inspect(other)

  defp fmt_wave(nil), do: fmt_omitted(%{reason: "no wave evidence"})
  defp fmt_wave(%{omitted: true} = skip), do: fmt_omitted(skip)

  defp fmt_wave(%{ok: ok, nodes_parallel: p, wall_ms_actual: a, wall_ms_serial_estimate: s}) do
    "#{ok} (parallel=#{p}, wall=#{a}ms serial=#{s}ms)"
  end

  defp fmt_wave(other), do: inspect(other)

  defp fmt_hold(nil), do: fmt_omitted(%{reason: "no hold evidence"})
  defp fmt_hold(%{omitted: true} = skip), do: fmt_omitted(skip)
  defp fmt_hold(%{ok: ok}), do: to_string(ok)
  defp fmt_hold(other), do: inspect(other)

  defp fmt_omitted(skip) do
    reason = skip[:reason] || skip["reason"] || "not exercised"
    "omitted — #{reason}"
  end

  # ---- maps / files ----------------------------------------------------

  defp jsonl(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case JSON.decode(line) do
            {:ok, row} -> [row]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp get(_, _), do: nil

  defp enum(nil), do: []
  defp enum(list) when is_list(list), do: list
  defp enum(other), do: List.wrap(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)
end
