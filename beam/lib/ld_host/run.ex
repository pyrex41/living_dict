defmodule LdHost.Run do
  @moduledoc """
  The kernel loop: goal + observation -> planner -> critic -> model-free
  execution -> gates -> typed promotion. Each episode is fingerprinted
  (identical resubmitted plans are blocked), every verdict lands in the
  run's ledger, and "done" means the contract's checks exited 0.

  Judge provenance is explicit: with an approved/hidden contract the
  gates execute its checks; without one the model's own claims are
  measured but their checks are refused, and the report says
  "model-authored claims" loudly.
  """

  alias LdHost.{
    Critic,
    Contracts,
    Dictionary,
    Envelope,
    Forth,
    Gates,
    Host,
    Ledger,
    Policy,
    Store,
    Wave
  }

  @default_max_episodes 6

  def run(goal, opts) do
    workspace = Keyword.fetch!(opts, :workspace) |> Path.expand()

    run_dir =
      Keyword.get(opts, :run_dir, Path.join([workspace, ".livingdict-run", "beam-" <> stamp()]))

    dictionary_dir = Keyword.get(opts, :dictionary_dir, Path.join(run_dir, "dictionary"))
    max_episodes = Keyword.get(opts, :max_episodes, @default_max_episodes)
    contract = normalize_contract(Keyword.get(opts, :contract))
    planner_fn = Keyword.get(opts, :planner_fn, &default_planner/3)

    {:ok, ledger} = Ledger.start_link(run_dir)

    if contract && LdHost.Spec.approved_source?(contract.source) do
      {:ok, _} =
        Ledger.commit(ledger, "contract.approved", %{
          claims: length(contract.claims),
          source: contract.source
        })
    end

    {prelude, prelude_words} = Dictionary.load_prelude(dictionary_dir)

    state = %{
      goal: goal,
      workspace: workspace,
      run_dir: run_dir,
      dictionary_dir: dictionary_dir,
      ledger: ledger,
      contract: contract,
      allow_model_checks: Keyword.get(opts, :allow_model_checks, false),
      planner_fn: planner_fn,
      prelude: prelude,
      prelude_words: prelude_words,
      allowed_effects:
        Keyword.get(opts, :allowed_effects, list_or(contract && contract[:allowed_effects], ["read", "write", "exec"])),
      allowed_globs: Keyword.get(opts, :allowed_globs, list_or(contract && contract[:allowed_globs], ["**"])),
      forbidden_globs:
        Keyword.get(opts, :forbidden_globs, [
          ".livingdict-run/*",
          ".git/*",
          "node_modules/*",
          "dist/*"
        ]),
      seen: MapSet.new(),
      feedback: "",
      last_report: nil,
      reused_names: [],
      promoted_words: [],
      tokens: %{input_tokens: 0, output_tokens: 0},
      model_calls: 0
    }

    result = episodes(state, 1, max_episodes)

    %{
      success: match?({:ok, _}, result),
      episodes: elem(result, 1).episode,
      report: elem(result, 1).last_report,
      judge: judge_label(elem(result, 1).last_report),
      tokens: elem(result, 1).tokens,
      model_calls: elem(result, 1).model_calls,
      # Reuse-proven this run, not first persist (candidates stay off this list).
      promoted_words: elem(result, 1).promoted_words,
      run_dir: run_dir
    }
  end

  defp episodes(state, episode, max) when episode > max do
    {:failed, Map.put(state, :episode, max)}
  end

  defp episodes(state, episode, max) do
    state = Map.put(state, :episode, episode)

    case run_episode(state, episode) do
      {:success, state} -> {:ok, Map.put(state, :episode, episode)}
      {:continue, state} -> episodes(state, episode + 1, max)
      {:halt, state} -> {:failed, Map.put(state, :episode, episode)}
    end
  end

  defp run_episode(state, episode) do
    observation = observe(state)

    case plan_with_retry(state, observation, 3) do
      {:error, reason} ->
        Ledger.trace(state.ledger, "planner.error", %{reason: inspect(reason)})
        {:halt, state}

      {:ok, raw_envelope, telemetry} ->
        state = record_model_call(state, telemetry)

        case Envelope.parse(raw_envelope) do
          {:error, reason} ->
            {:continue, feedback(state, "envelope invalid: #{reason}")}

          {:ok, envelope} ->
            plan_episode(state, episode, envelope)
        end
    end
  end

  defp plan_episode(state, episode, envelope) do
    fingerprint = Envelope.fingerprint(envelope)

    if MapSet.member?(state.seen, fingerprint) do
      {:ok, _} =
        Ledger.commit(state.ledger, "episode.blocked_duplicate", %{
          episode: episode,
          fingerprint: fingerprint
        })

      {:continue,
       feedback(
         state,
         "identical plan resubmitted and blocked — change the plan, the errors stand"
       )}
    else
      reused = Dictionary.used_names(envelope.program, state.prelude_words)

      Enum.each(reused, fn name ->
        Ledger.trace(state.ledger, "dictionary.reuse", %{word: name, version: 1})
      end)

      state = %{state | seen: MapSet.put(state.seen, fingerprint), reused_names: reused}
      hashes = artifact_digests(envelope.artifacts)

      {:ok, _} =
        Ledger.commit(state.ledger, "episode.planned", %{
          episode: episode,
          fingerprint: fingerprint,
          rationale: envelope.rationale,
          used_words: reused,
          artifact_sha256: hashes
        })

      case Dictionary.catalog_pressure(state.prelude_words, envelope) do
        {:error, message} ->
          errors = [message]

          {:ok, _} =
            Ledger.commit(state.ledger, "critic.rejected", %{episode: episode, errors: errors})

          Ledger.trace(state.ledger, "preflight.rejected", %{errors: errors})
          {:continue, feedback(state, "critic rejected the plan:\n" <> message)}

        :ok ->
          composed = compose(state.prelude, envelope.program)
          artifact_keys = envelope.artifacts |> Map.keys() |> Enum.sort()

          case critic_plan(state, envelope, composed, artifact_keys) do
            {:reject, errors} ->
              {:ok, _} =
                Ledger.commit(state.ledger, "critic.rejected", %{episode: episode, errors: errors})

              Ledger.trace(state.ledger, "preflight.rejected", %{errors: errors})

              {:continue,
               feedback(state, "critic rejected the plan:\n" <> Enum.join(errors, "\n"))}

            {:accept, depth, effects} ->
              {:ok, _} =
                Ledger.commit(state.ledger, "critic.accepted", %{
                  episode: episode,
                  depth: depth,
                  effects: effects,
                  used_words: reused,
                  artifact_sha256: hashes
                })

              execute_episode(state, episode, envelope, composed)

            {:error, reason} ->
              Ledger.trace(state.ledger, "critic.unavailable", %{reason: reason})
              {:halt, state}
          end
      end
    end
  end

  defp execute_episode(state, episode, envelope, composed) do
    host =
      Host.new(state.workspace,
        allowed_effects: state.allowed_effects,
        allowed_globs: state.allowed_globs,
        forbidden_globs: state.forbidden_globs,
        run_id: Path.basename(state.run_dir),
        episode: episode,
        contract: state.contract,
        allow_model_checks: state.allow_model_checks,
        emit: Ledger.emitter(state.ledger),
        receipt_path: Path.join(state.run_dir, "receipt.json"),
        objects_dir: Store.objects_root(state.run_dir)
      )

    Enum.each(envelope.artifacts, fn
      {_key, body} when is_binary(body) -> Host.intern(host, body)
      _ -> :ok
    end)

    vocab = Dictionary.load_vocab(state.dictionary_dir)
    nodes = envelope.nodes || Wave.synthesize(envelope.artifacts)

    case dispatch_waves(state, host, nodes, envelope.artifacts, vocab, episode) do
      {:error, :overlap, errors} ->
        {:continue, feedback(state, "overlapping writes refused pre-I/O:\n" <> Enum.join(errors, "\n"))}

      {:error, :graph, reason} ->
        {:continue, feedback(state, "wave plan: #{reason}")}

      {:trap, code, message} ->
        Ledger.trace(state.ledger, "execution.trap", %{code: code, message: message})
        record_workspace_tree(state, host, %{ok: false, reason: "execution trap [#{code}]"})
        {:continue, feedback(state, "execution trap [#{code}]: #{message}")}

      {:ok, host, colon} ->
        vm =
          %Forth.VM{host: host, artifacts: envelope.artifacts}
          |> Forth.bind_vocab(vocab)

        vm = %{vm | colon: Map.merge(vm.colon, colon)}
        composed = promote_source(composed, envelope)

        if envelope.nodes do
          finish_episode(state, episode, envelope, composed, vm)
        else
          Ledger.trace(state.ledger, "execution.program", %{program: envelope.program})

          case interpret(vm, envelope.program) do
            {:trap, code, message} ->
              Ledger.trace(state.ledger, "execution.trap", %{code: code, message: message})
              record_workspace_tree(state, vm.host, %{ok: false, reason: "execution trap [#{code}]"})
              {:continue, feedback(state, "execution trap [#{code}]: #{message}")}

            {:ok, vm} ->
              finish_episode(state, episode, envelope, composed, vm)
          end
        end
    end
  end

  defp critic_plan(state, envelope, composed, artifact_keys) do
    case Critic.validate(
           composed,
           state.allowed_effects,
           state.allowed_globs,
           state.forbidden_globs,
           artifact_keys
         ) do
      {:error, reason} ->
        {:error, reason}

      {:reject, errors, _depth, _effects} ->
        {:reject, errors}

      {:accept, depth, effects} ->
        case node_preflight(state, envelope, artifact_keys) do
          [] -> {:accept, depth, effects}
          errors -> {:reject, errors}
        end
    end
  end

  defp node_preflight(state, envelope, artifact_keys) do
    nodes = envelope.nodes || Wave.synthesize(envelope.artifacts)

    graph =
      case nodes do
        [] ->
          []

        _ ->
          case Wave.plan_waves(nodes) do
            {:error, reason} -> [reason]
            {:ok, waves} -> Enum.flat_map(waves, &Wave.overlap_errors/1)
          end
      end

    critics =
      Enum.flat_map(nodes, fn node ->
        program = node.program || ""

        if String.trim(program) == "" do
          []
        else
          composed = compose(state.prelude, program)
          allowed = node_allowed_globs(node, state.allowed_globs)

          case Critic.validate(
                 composed,
                 state.allowed_effects,
                 allowed,
                 state.forbidden_globs,
                 artifact_keys
               ) do
            {:accept, _, _} -> []
            {:reject, errors, _, _} -> Enum.map(errors, &"node #{node.id}: #{&1}")
            {:error, reason} -> ["node #{node.id}: critic unavailable: #{reason}"]
          end
        end
      end)

    graph ++ critics
  end

  defp node_allowed_globs(node, fallback) do
    case Wave.write_globs(node) do
      [] -> fallback
      globs -> globs
    end
  end

  defp dispatch_waves(_state, host, [], _artifacts, _vocab, _episode), do: {:ok, host, %{}}

  defp dispatch_waves(state, host, nodes, artifacts, vocab, episode) do
    Wave.execute(host, nodes, artifacts,
      record: fn kind, payload -> Ledger.trace(state.ledger, kind, payload) end,
      run_id: host.run_id,
      episode: episode,
      vocab: vocab
    )
  end

  defp finish_episode(state, episode, envelope, composed, vm) do
    {:ok, _} =
      Ledger.commit(state.ledger, "artifacts.applied", %{
        episode: episode,
        count: map_size(envelope.artifacts),
        keys: envelope.artifacts |> Map.keys() |> Enum.sort(),
        artifact_sha256: artifact_digests(envelope.artifacts)
      })

    report =
      case vm.host.last_check do
        nil ->
          Gates.run(vm.host)

        existing ->
          persist_discharge(vm.host, existing)
          existing
      end

    record_workspace_tree(state, vm.host, %{ok: report.ok == true, reason: report[:reason]})

    state = %{state | last_report: report}
    state = promote(state, episode, vm, composed, report)

    if report.ok == true do
      {_reply, _payload, _host} = Host.receipt(vm.host)
      {:success, state}
    else
      {:continue, feedback(state, gate_feedback(report))}
    end
  end

  defp interpret(vm, source) do
    {:ok, Forth.interpret(vm, source)}
  rescue
    e in Forth.Error -> {:trap, e.code, e.message}
  end

  # ---- typed promotion --------------------------------------------------

  # Reachable only after a trap-free interpret: Harbor / report.ok must
  # not gate persistence; promotion is clean reuse of a candidate.
  defp promote(state, episode, vm, composed, _report) do
    contracts = Contracts.extract(composed)
    new_names = Forth.defined_names(vm) -- state.prelude_words

    {to_save, quarantined} =
      Enum.split_with(new_names, fn name ->
        Map.has_key?(contracts, name) and
          Contracts.canonical(contracts[name]) != nil and
          not Dictionary.tautology?(vm.colon[name])
      end)

    entries =
      Enum.map(to_save, fn name ->
        {name, Dictionary.body_source(vm.colon[name]), Contracts.canonical(contracts[name])}
      end)

    written = Dictionary.save_words(state.dictionary_dir, entries)

    Enum.each(written, fn {name, sha} ->
      Ledger.trace(state.ledger, "dictionary.candidate", %{
        word: name,
        sha256: sha,
        contract: Contracts.canonical(contracts[name])
      })
    end)

    Enum.each(quarantined, fn name ->
      # split_with already kept canonical non-tautologies in to_save.
      reasons =
        if Dictionary.tautology?(vm.colon[name]),
          do: ["host-word alias"],
          else: ["missing contract"]

      {:ok, _} =
        Ledger.commit(state.ledger, "dictionary.promotion_evidence", %{
          word: name,
          episode: episode,
          eligible: false,
          reasons: reasons
        })

      Ledger.trace(state.ledger, "dictionary.quarantined", %{word: name, reasons: reasons})
    end)

    # Skip tautologies even if a legacy .fs was seeded: alias reuse is not promotion.
    reusable =
      Enum.filter(state.reused_names, fn name ->
        case vm.colon[name] do
          nil -> false
          tokens -> not Dictionary.tautology?(tokens)
        end
      end)

    newly = Dictionary.mark_promoted(state.dictionary_dir, reusable)

    Enum.each(newly, fn {name, sha} ->
      contract = promoted_contract(state.dictionary_dir, name, contracts)

      {:ok, _} =
        Ledger.commit(state.ledger, "dictionary.promoted", %{
          word: name,
          sha256: sha,
          contract: contract,
          episode: episode
        })

      Ledger.trace(state.ledger, "dictionary.promote", %{
        word: name,
        sha256: sha,
        contract: contract
      })
    end)

    state = %{state | promoted_words: state.promoted_words ++ Enum.map(newly, &elem(&1, 0))}

    if written != [] do
      {prelude, words} = Dictionary.load_prelude(state.dictionary_dir)
      %{state | prelude: prelude, prelude_words: words}
    else
      state
    end
  end

  defp promoted_contract(dictionary_dir, name, contracts) do
    from_program =
      case contracts[name] do
        inner when is_binary(inner) -> Contracts.canonical(inner)
        _ -> nil
      end

    from_program ||
      case File.read(Path.join(Dictionary.words_dir(dictionary_dir), "#{name}.fs")) do
        {:ok, source} ->
          case Contracts.extract(source)[name] do
            inner when is_binary(inner) -> Contracts.canonical(inner)
            _ -> nil
          end

        _ ->
          nil
      end
  end

  # ---- helpers ----------------------------------------------------------

  # Traps skip finish_episode; still intern a tree so as_of/TREE does not
  # lag the workspace the planner is about to see.
  defp record_workspace_tree(state, host, extra) when is_map(extra) do
    files = Policy.snapshot(state.workspace)
    tree_after = Store.intern_snapshot(host.objects_dir, state.workspace, files)

    payload =
      Map.merge(
        %{episode: state.episode, tree_after: tree_after, files: files},
        extra
      )

    {:ok, _} = Ledger.commit(state.ledger, "gates.measured", payload)
    :ok
  end

  defp persist_discharge(host, report) do
    dir = Path.join(host.workspace, ".sb")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "discharge_report.json"), JSON.encode!(report))
  end

  defp compose("", program), do: program
  defp compose(prelude, program), do: prelude <> "\n" <> program

  defp promote_source(composed, %{nodes: nil}), do: composed

  defp promote_source(composed, %{nodes: nodes}) when is_list(nodes) do
    extra = Enum.map_join(nodes, "\n", &(&1.program || ""))
    compose(composed, extra)
  end

  defp observe(state) do
    events = Ledger.events(state.ledger)
    revision = Ledger.revision(state.ledger)

    tree =
      if state.episode <= 1 do
        Policy.snapshot(state.workspace)
      else
        Store.as_of(events, revision, Store.objects_root(state.run_dir))
      end

    used = last_used_words(events)
    used_set = MapSet.new(used)
    unused = Enum.reject(state.prelude_words, &MapSet.member?(used_set, &1))

    [
      "DICTIONARY:",
      catalog_lines(state),
      "",
      "UNUSED: " <> Enum.join(unused, " "),
      "",
      "TREE:",
      tree_lines(tree),
      "",
      gates_section(state.last_report),
      "",
      critic_section(events),
      feedback_section(state.feedback)
    ]
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n")
  end

  defp catalog_lines(state) do
    lines =
      state.dictionary_dir
      |> Dictionary.load_vocab()
      |> Enum.map(fn {name, _tokens, _sig, source} ->
        case Contracts.extract(source)[name] do
          inner when is_binary(inner) ->
            case Contracts.canonical(inner) do
              nil -> name
              contract -> "#{name} #{contract}"
            end

          _ ->
            name
        end
      end)

    if lines == [], do: "", else: Enum.join(lines, "\n")
  end

  defp tree_lines(tree) when map_size(tree) == 0, do: ""

  defp tree_lines(tree) do
    tree
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {path, hash} -> "#{path} #{hash}" end)
  end

  defp last_used_words(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value([], fn event ->
      kind = event[:kind] || event["kind"]

      if kind in ["episode.planned", "critic.accepted"] do
        payload = event[:payload] || event["payload"] || %{}
        list = payload[:used_words] || payload["used_words"] || []
        Enum.map(List.wrap(list), &to_string/1)
      end
    end)
  end

  defp gates_section(nil), do: "GATES:"

  defp gates_section(report) do
    ids =
      case report[:claims] do
        claims when is_list(claims) -> Enum.map_join(claims, ",", &to_string(&1.id))
        _ -> ""
      end

    "GATES:\nok=#{report[:ok] == true} ids=#{ids}"
  end

  defp critic_section(events) do
    errors =
      Store.facts(events)
      |> Enum.filter(fn {_e, attr, _v, _tx} -> attr == ":critic/error" end)
      |> Enum.group_by(fn {_e, _a, _v, tx} -> tx end)
      |> Enum.max_by(fn {tx, _} -> tx end, fn -> {0, []} end)
      |> elem(1)
      |> Enum.map(fn {_e, _a, value, _tx} -> to_string(value) end)

    ["CRITIC:" | errors] |> Enum.join("\n")
  end

  defp feedback_section(""), do: nil
  defp feedback_section(text), do: "\nFEEDBACK:\n" <> text

  defp artifact_digests(artifacts) when is_map(artifacts) do
    artifacts
    |> Enum.filter(fn {key, body} -> is_binary(key) and is_binary(body) end)
    |> Map.new(fn {key, body} -> {key, Policy.sha256_hex(body)} end)
  end

  defp artifact_digests(_), do: %{}

  defp gate_feedback(report) do
    failing =
      case report[:claims] do
        claims when is_list(claims) ->
          claims
          |> Enum.reject(& &1.passed)
          |> Enum.map(fn claim ->
            # Ids + reason only: check stdout can contain product file
            # bodies and must not leak into observe/FEEDBACK.
            "- #{claim.id} (#{claim[:kind]}): #{claim[:reason] || claim[:path] || "check failed"}"
          end)
          |> Enum.join("\n")

        _ ->
          ""
      end

    "gates failed: #{report[:reason]}\n#{failing}"
  end

  defp feedback(state, text), do: %{state | feedback: text}

  defp record_model_call(state, telemetry) do
    Ledger.trace(state.ledger, "llm.response", telemetry)

    {:ok, _} =
      Ledger.commit(state.ledger, "budget.consumed", Map.put(telemetry, :episode, state.episode))

    %{
      state
      | model_calls: state.model_calls + 1,
        tokens: %{
          input_tokens: state.tokens.input_tokens + (telemetry[:input_tokens] || 0),
          output_tokens: state.tokens.output_tokens + (telemetry[:output_tokens] || 0)
        }
    }
  end

  # Transient transport failures (timeouts, resets) must not kill a run:
  # retry with backoff before declaring the planner unreachable.
  defp plan_with_retry(state, observation, attempts) do
    result =
      try do
        state.planner_fn.(state.goal, observation, state.feedback)
      rescue
        # A raising planner (encoding, transport internals) must become a
        # retryable error, not instant run death.
        e -> {:error, "planner raised: #{Exception.message(e)}"}
      end

    case result do
      {:ok, _, _} = ok ->
        ok

      {:error, reason} when attempts > 1 ->
        Ledger.trace(state.ledger, "planner.retry", %{reason: inspect(reason), left: attempts - 1})

        Process.sleep((4 - attempts) * 5_000 + 5_000)
        plan_with_retry(state, observation, attempts - 1)

      {:error, _} = error ->
        error
    end
  end

  defp default_planner(goal, observation, _feedback) do
    # observe/1 already includes the FEEDBACK section; do not prepend it again.
    LdHost.Planner.plan(goal, observation)
  end

  defp normalize_contract(nil), do: nil

  defp normalize_contract(%{claims: claims} = contract) when is_list(claims) do
    %{
      claims: Enum.map(claims, &LdHost.Gates.atomize_claim/1),
      source: Map.get(contract, :source, "approved"),
      allowed_globs: Map.get(contract, :allowed_globs),
      allowed_effects: Map.get(contract, :allowed_effects),
      obligation_kinds: Map.get(contract, :obligation_kinds)
    }
  end

  defp normalize_contract(claims) when is_list(claims) do
    %{claims: Enum.map(claims, &LdHost.Gates.atomize_claim/1), source: "approved"}
  end

  defp list_or(list, _default) when is_list(list), do: list
  defp list_or(_, default), do: default

  defp judge_label(nil), do: "no gates measured"
  defp judge_label(report), do: report[:judge] || "unknown"

  defp stamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
