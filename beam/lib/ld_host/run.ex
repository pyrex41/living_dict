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
    OODA,
    Research
  }

  @default_max_episodes 6

  def run(goal, opts) do
    workspace = Keyword.fetch!(opts, :workspace) |> Path.expand()

    run_dir =
      Keyword.get(opts, :run_dir, Path.join([workspace, ".livingdict-run", "beam-" <> stamp()]))

    dictionary_dir = Keyword.get(opts, :dictionary_dir, Path.join(run_dir, "dictionary"))
    max_episodes = Keyword.get(opts, :max_episodes, @default_max_episodes)
    contract = normalize_contract(Keyword.get(opts, :contract))
    planner_fn = Keyword.get(opts, :planner_fn)
    ooda_mode = normalize_ooda(Keyword.get(opts, :ooda_mode, :off))
    reasoning_effort = normalize_effort(Keyword.get(opts, :reasoning_effort))

    if ooda_mode == :auto and reasoning_effort do
      raise ArgumentError, "ooda auto conflicts with fixed reasoning_effort"
    end

    {:ok, ledger} = Ledger.start_link(run_dir)

    if contract do
      {:ok, _} =
        Ledger.commit(ledger, "contract.approved", %{
          claims: length(contract.claims),
          source: contract.source
        })
    end

    {prelude, prelude_words} = Dictionary.load_prelude(dictionary_dir)
    # Only contract-valid rows are actually bound into the VM.  Keep this
    # separate from the source prelude names so eligibility never overstates
    # what the runtime could call.
    catalog_before = Dictionary.load_vocab(dictionary_dir) |> Enum.map(&elem(&1, 0))

    state = %{
      goal: goal,
      workspace: workspace,
      run_dir: run_dir,
      dictionary_dir: dictionary_dir,
      ledger: ledger,
      contract: contract,
      allow_model_checks: Keyword.get(opts, :allow_model_checks, false),
      planner_fn: planner_fn,
      research_fn: Keyword.get(opts, :research_fn, &default_research/3),
      ooda_mode: ooda_mode,
      current_effort: reasoning_effort,
      initial_route: if(ooda_mode == :auto, do: nil, else: :fixed),
      repair_used: false,
      research_rounds: 0,
      research_tool_calls: 0,
      research_evidence_bytes: 0,
      unresolved_questions: [],
      prelude: prelude,
      prelude_words: prelude_words,
      allowed_effects: Keyword.get(opts, :allowed_effects, ["read", "write", "exec"]),
      allowed_globs: Keyword.get(opts, :allowed_globs, ["**"]),
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
      last_plan: nil,
      reused_names: [],
      catalog_before: catalog_before,
      eligible_words: catalog_before,
      used_words: [],
      used_words_known: false,
      used_words_complete: true,
      candidate_words: [],
      covering_rejections: 0,
      promoted_words: [],
      tokens: %{
        input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        cached_tokens: 0,
        total_tokens: 0
      },
      model_calls: 0
    }

    episode_result = episodes(state, 1, max_episodes)

    result = %{
      success: match?({:ok, _}, episode_result),
      episodes: elem(episode_result, 1).episode,
      report: elem(episode_result, 1).last_report,
      judge: judge_label(elem(episode_result, 1).last_report),
      tokens: elem(episode_result, 1).tokens,
      model_calls: elem(episode_result, 1).model_calls,
      ooda_mode: elem(episode_result, 1).ooda_mode,
      initial_route: elem(episode_result, 1).initial_route,
      repair_used: elem(episode_result, 1).repair_used,
      research_rounds: elem(episode_result, 1).research_rounds,
      research_tool_calls: elem(episode_result, 1).research_tool_calls,
      research_evidence_bytes: elem(episode_result, 1).research_evidence_bytes,
      unresolved_questions: elem(episode_result, 1).unresolved_questions,
      # Reuse-proven this run, not first persist (candidates stay off this list).
      promoted_words: elem(episode_result, 1).promoted_words,
      run_dir: run_dir
    }

    evidence = %{
      catalog_before: elem(episode_result, 1).catalog_before,
      eligible_words: elem(episode_result, 1).eligible_words,
      candidate_words: elem(episode_result, 1).candidate_words,
      promoted_words: elem(episode_result, 1).promoted_words,
      critic_covering_rejections: elem(episode_result, 1).covering_rejections
    }

    evidence =
      if elem(episode_result, 1).used_words_known and elem(episode_result, 1).used_words_complete do
        used = elem(episode_result, 1).used_words

        Map.merge(evidence, %{
          used_words: used,
          unused_eligible_words: evidence.eligible_words -- used
        })
      else
        evidence
      end

    Map.merge(result, evidence)
  end

  defp episodes(state, episode, max) when episode > max do
    {:failed, Map.put(state, :episode, max)}
  end

  defp episodes(state, episode, max) do
    if state.ooda_mode == :auto and episode > 2 do
      Ledger.trace(state.ledger, "ooda.halt_blocked", %{
        reason: "semantic repair budget exhausted"
      })

      {:failed, Map.put(state, :episode, episode - 1)}
    else
      state = Map.put(state, :episode, episode)

      case run_episode(state, episode) do
        {:success, state} -> {:ok, Map.put(state, :episode, episode)}
        {:continue, state} -> episodes(state, episode + 1, max)
        {:halt, state} -> {:failed, Map.put(state, :episode, episode)}
      end
    end
  end

  defp run_episode(state, episode) do
    case prepare_observation(state, episode) do
      {:error, reason, state} ->
        Ledger.trace(state.ledger, "ooda.research_failed", %{episode: episode, reason: reason})
        {:halt, state}

      {:ok, observation, state} ->
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
  end

  defp plan_episode(state, episode, envelope) do
    state = %{
      state
      | last_plan: %{
          program: envelope.program,
          artifacts: envelope.artifacts,
          rationale: envelope.rationale
        }
    }

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
        Ledger.trace(state.ledger, "dictionary.reuse_intent", %{
          word: name,
          version: 1,
          episode: episode
        })
      end)

      state = %{state | seen: MapSet.put(state.seen, fingerprint), reused_names: reused}

      {:ok, _} =
        Ledger.commit(state.ledger, "episode.planned", %{
          episode: episode,
          fingerprint: fingerprint,
          rationale: envelope.rationale
        })

      case Dictionary.catalog_pressure(state.prelude_words, envelope) do
        {:error, message} ->
          errors = [message]

          {:ok, _} =
            Ledger.commit(state.ledger, "critic.rejected", %{episode: episode, errors: errors})

          Ledger.trace(state.ledger, "preflight.rejected", %{errors: errors})

          state =
            if covering_rejection?(message),
              do: %{state | covering_rejections: state.covering_rejections + 1},
              else: state

          {:continue, feedback(state, "critic rejected the plan:\n" <> message)}

        :ok ->
          catalog = Dictionary.load_vocab(state.dictionary_dir)
          artifact_keys = envelope.artifacts |> Map.keys() |> Enum.sort()

          Ledger.trace(state.ledger, "critic.program", %{program: envelope.program})

          case Critic.validate(
                 envelope.program,
                 state.allowed_effects,
                 state.allowed_globs,
                 state.forbidden_globs,
                 artifact_keys,
                 catalog
               ) do
            {:reject, errors, _depth, _effects} ->
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
                  effects: effects
                })

              execute_episode(state, episode, envelope)

            {:error, reason} ->
              Ledger.trace(state.ledger, "critic.unavailable", %{reason: reason})
              {:halt, state}
          end
      end
    end
  end

  defp execute_episode(state, episode, envelope) do
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
        receipt_path: Path.join(state.run_dir, "receipt.json")
      )

    vocab = Dictionary.load_vocab(state.dictionary_dir)

    vm =
      %Forth.VM{host: host, artifacts: envelope.artifacts}
      |> Forth.bind_vocab(vocab)

    Ledger.trace(state.ledger, "execution.program", %{program: envelope.program})

    case interpret(vm, envelope.program) do
      {:trap, code, message} ->
        Ledger.trace(state.ledger, "execution.trap", %{code: code, message: message})
        # The VM raises without returning its partial state.  Mark aggregate
        # invocation evidence incomplete so a later successful episode cannot
        # be mistaken for a complete run-wide trace.
        state = %{state | used_words_complete: false}
        {:continue, feedback(state, "execution trap [#{code}]: #{message}")}

      {:ok, vm} ->
        Enum.each(vm.used_words, fn name ->
          Ledger.trace(state.ledger, "dictionary.reuse", %{
            word: name,
            version: 1,
            episode: episode
          })
        end)

        {:ok, _} =
          Ledger.commit(state.ledger, "artifacts.applied", %{
            episode: episode,
            count: map_size(envelope.artifacts)
          })

        report = vm.host.last_check || Gates.run(vm.host)

        {:ok, _} =
          Ledger.commit(state.ledger, "gates.measured", %{
            episode: episode,
            ok: report.ok == true,
            reason: report[:reason]
          })

        state = %{
          state
          | last_report: report,
            used_words: Enum.uniq(state.used_words ++ vm.used_words),
            used_words_known: true
        }

        state = promote(state, episode, vm, envelope.program, report)

        if report.ok == true do
          {_reply, _payload, _host} = Host.receipt(vm.host)
          {:success, state}
        else
          {:continue, feedback(state, gate_feedback(report))}
        end
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

    {to_save, dependent} = quarantine_dependents(to_save, quarantined, vm)
    quarantined = quarantined ++ dependent
    dependent_set = MapSet.new(dependent)

    vocab = Dictionary.load_vocab(state.dictionary_dir)

    sibling_rows =
      Enum.flat_map(to_save, fn name ->
        case Dictionary.vocab_row(
               name,
               vm.colon[name],
               Contracts.canonical(contracts[name])
             ) do
          {:ok, row} -> [row]
          :error -> []
        end
      end)

    promote_catalog = vocab ++ sibling_rows

    {entries, refused} =
      Enum.reduce(to_save, {[], []}, fn name, {keep, skip} ->
        body = Dictionary.body_source(vm.colon[name])
        contract = Contracts.canonical(contracts[name])
        source = ": #{name} #{contract} #{body} ;\n"

        case Critic.validate(
               source,
               state.allowed_effects,
               state.allowed_globs,
               state.forbidden_globs,
               [],
               promote_catalog
             ) do
          {:accept, _, _} ->
            {[{name, body, contract} | keep], skip}

          {:reject, errors, _, _} ->
            {keep, [{name, errors} | skip]}

          {:error, reason} ->
            {keep, [{name, [to_string(reason)]} | skip]}
        end
      end)

    written = Dictionary.save_words(state.dictionary_dir, Enum.reverse(entries))

    state = %{
      state
      | candidate_words: Enum.uniq(state.candidate_words ++ Enum.map(written, &elem(&1, 0)))
    }

    Enum.each(written, fn {name, sha} ->
      Ledger.trace(state.ledger, "dictionary.candidate", %{
        word: name,
        sha256: sha,
        contract: Contracts.canonical(contracts[name])
      })
    end)

    Enum.each(refused, fn {name, reasons} ->
      {:ok, _} =
        Ledger.commit(state.ledger, "dictionary.promotion_evidence", %{
          word: name,
          episode: episode,
          eligible: false,
          reasons: reasons
        })

      Ledger.trace(state.ledger, "dictionary.quarantined", %{word: name, reasons: reasons})
    end)

    Enum.each(quarantined, fn name ->
      reasons =
        cond do
          Dictionary.tautology?(vm.colon[name]) ->
            ["host-word alias"]

          MapSet.member?(dependent_set, name) ->
            ["depends on host-word alias"]

          true ->
            ["missing contract"]
        end

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
    # Promotion requires an actual invocation of the currently bound
    # persisted body.  Planner-text mentions (including a local definition
    # that shadows a catalog name) are not reuse evidence.
    reusable =
      Enum.filter(vm.used_words, fn name ->
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

  defp quarantine_dependents(promotable, quarantined, vm) do
    close_quarantine(promotable, [], MapSet.new(quarantined), vm)
  end

  defp close_quarantine(remaining, extra, banned, vm) do
    {hit, rest} =
      Enum.split_with(remaining, fn name ->
        refers_to_banned?(vm.colon[name], banned)
      end)

    if hit == [] do
      {remaining, extra}
    else
      close_quarantine(rest, extra ++ hit, MapSet.union(banned, MapSet.new(hit)), vm)
    end
  end

  defp refers_to_banned?(tokens, banned) when is_list(tokens) do
    Enum.any?(tokens, fn
      %{kind: :word, value: value} -> MapSet.member?(banned, String.upcase(to_string(value)))
      _ -> false
    end)
  end

  defp refers_to_banned?(_, _), do: false

  @observe_file_cap 8_000
  @observe_total_cap 60_000

  defp prepare_observation(%{ooda_mode: :off} = state, _episode),
    do: {:ok, observe(state), state}

  defp prepare_observation(%{ooda_mode: :auto} = state, episode) do
    manifest =
      OODA.manifest(state.workspace,
        allowed_globs: state.allowed_globs,
        approved_contract: state.contract != nil
      )

    if episode == 1 do
      decision = OODA.orient(manifest)

      Ledger.trace(state.ledger, "ooda.oriented", %{
        episode: episode,
        route: decision.route,
        reasoning_effort: decision.effort,
        reasons: decision.reasons,
        file_count: manifest.file_count,
        total_bytes: manifest.total_bytes
      })

      state = %{state | initial_route: decision.route, current_effort: decision.effort}

      case decision.route do
        :direct -> {:ok, append_harness_context(OODA.direct_context(manifest), state), state}
        _ -> research_observation(state, manifest, episode, state.goal)
      end
    else
      effort = escalate(state.current_effort)
      state = %{state | repair_used: true, current_effort: effort}

      Ledger.trace(state.ledger, "ooda.repair", %{
        episode: episode,
        reasoning_effort: effort,
        failure: state.feedback
      })

      if state.initial_route == :direct and plan_failure?(state.feedback) do
        observation =
          OODA.direct_context(manifest) <>
            "\nREPAIR PACKET:\n" <> repair_packet(state)

        Ledger.trace(state.ledger, "ooda.repair_context", %{
          episode: episode,
          source: "prior bounded source pack",
          research_skipped: true
        })

        {:ok, append_harness_context(observation, state), state}
      else
        research_observation(
          state,
          manifest,
          episode,
          state.goal <> "\n\nREPAIR PACKET:\n" <> repair_packet(state)
        )
      end
    end
  end

  defp research_observation(state, manifest, episode, research_goal) do
    case state.research_fn.(research_goal, manifest,
           run_id: Path.basename(state.run_dir),
           emit: fn type, data ->
             Ledger.trace(state.ledger, type, Map.put(data, :episode, episode))
           end
         ) do
      {:ok, brief, budget, telemetry} ->
        state = record_model_call(state, telemetry)
        entries = OODA.selected_sources(manifest, brief)
        unresolved = brief["uncertainties"] || []
        limits = OODA.limits()
        calls = limits.tool_calls - budget.calls_left
        bytes = limits.evidence_bytes - budget.bytes_left

        Ledger.trace(state.ledger, "ooda.research_brief", %{
          episode: episode,
          questions: brief["questions"] || [],
          findings: length(brief["findings"] || []),
          uncertainties: unresolved,
          tool_calls: calls,
          evidence_bytes: bytes
        })

        state = %{
          state
          | research_rounds: state.research_rounds + 1,
            research_tool_calls: state.research_tool_calls + calls,
            research_evidence_bytes: state.research_evidence_bytes + bytes,
            unresolved_questions: Enum.uniq(state.unresolved_questions ++ unresolved)
        }

        {:ok, append_harness_context(OODA.context(manifest, brief, entries), state), state}

      {:error, reason} ->
        {:error, to_string(reason), state}
    end
  end

  defp escalate("low"), do: "medium"
  defp escalate("medium"), do: "high"
  defp escalate("high"), do: "xhigh"
  defp escalate(_), do: "high"

  defp plan_failure?(feedback) do
    String.starts_with?(feedback, [
      "critic rejected the plan:",
      "envelope invalid:",
      "identical plan resubmitted"
    ])
  end

  defp append_harness_context(observation, state) do
    dictionary = Dictionary.load_vocab(state.dictionary_dir) |> Enum.map(&elem(&1, 0))

    observation <>
      "\nHARNESS CONTEXT:\n" <>
      JSON.encode!(%{
        approved_contract: state.contract != nil,
        dictionary: dictionary,
        feedback: state.feedback
      })
  end

  defp repair_packet(state) do
    encoded =
      JSON.encode!(%{
        failure: state.feedback,
        prior_plan: state.last_plan,
        last_gates: state.last_report && scrub(state.last_report)
      })

    if byte_size(encoded) <= 32_000,
      do: encoded,
      else:
        String.replace_invalid(binary_part(encoded, 0, 32_000)) <>
          "\n<<repair packet truncated>>"
  end

  defp observe(state) do
    names =
      state.workspace
      |> LdHost.Policy.snapshot()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.take(200)

    {files, _budget} =
      Enum.map_reduce(names, @observe_total_cap, fn rel, budget ->
        content =
          case File.read(Path.join(state.workspace, rel)) do
            {:ok, text} when byte_size(text) <= @observe_file_cap ->
              if String.valid?(text) and budget - byte_size(text) > 0, do: text, else: nil

            _ ->
              nil
          end

        case content do
          nil -> {"#{rel} (contents omitted)", budget}
          text -> {"#{rel}:\n```\n#{text}```", budget - byte_size(text)}
        end
      end)

    dictionary =
      case Dictionary.load_vocab(state.dictionary_dir) do
        [] ->
          ""

        rows ->
          lines =
            Enum.map(rows, fn {name, _tokens, _sig, source} ->
              contract =
                case Contracts.extract(source)[name] do
                  inner when is_binary(inner) -> Contracts.canonical(inner) || ""
                  _ -> ""
                end

              String.trim("#{name} #{contract}")
            end)

          "\nHARNESS DICTIONARY (callable colon words):\n" <> Enum.join(lines, "\n")
      end

    gates =
      case state.last_report do
        nil -> ""
        report -> "\nLAST GATES: " <> JSON.encode!(scrub(report))
      end

    feedback =
      case state.feedback do
        "" -> ""
        text -> "\nFEEDBACK:\n" <> text
      end

    "WORKSPACE FILES:\n" <> Enum.join(files, "\n") <> dictionary <> gates <> feedback
  end

  defp scrub(report), do: Map.take(report, [:ok, :reason, :judge, :name])

  defp gate_feedback(report) do
    failing =
      case report[:claims] do
        claims when is_list(claims) ->
          claims
          |> Enum.reject(& &1.passed)
          |> Enum.map(fn claim ->
            # Never echo check COMMANDS back to the model: a hidden
            # verifier's location must not leak. The id and the check's
            # output tail are the backpressure.
            "- #{claim.id} (#{claim[:kind]}): #{claim[:reason] || claim[:path] || "check failed"}" <>
              if(claim[:output], do: "\n  output: #{claim[:output]}", else: "")
          end)
          |> Enum.join("\n")

        _ ->
          ""
      end

    "gates failed: #{report[:reason]}\n#{failing}"
  end

  defp feedback(state, text), do: %{state | feedback: text}

  defp covering_rejection?(message),
    do:
      is_binary(message) and
        String.contains?(message, "catalog has INSTALL; use it instead of WRITE-FILE")

  defp record_model_call(state, telemetry) do
    Ledger.trace(state.ledger, "llm.response", telemetry)

    calls = Map.get(telemetry, :model_calls, Map.get(telemetry, "model_calls", 1))

    if calls == 0 do
      state
    else
      {:ok, _} =
        Ledger.commit(
          state.ledger,
          "budget.consumed",
          Map.put(telemetry, :episode, state.episode)
        )

      %{
        state
        | model_calls: state.model_calls + calls,
          tokens: add_token_usage(state.tokens, telemetry)
      }
    end
  end

  defp add_token_usage(tokens, telemetry) do
    input = telemetry[:input_tokens] || 0
    output = telemetry[:output_tokens] || 0
    reasoning = telemetry[:reasoning_tokens] || 0
    total = telemetry[:total_tokens] || input + output + reasoning

    %{
      input_tokens: tokens.input_tokens + input,
      output_tokens: tokens.output_tokens + output,
      reasoning_tokens: tokens.reasoning_tokens + reasoning,
      cached_tokens: tokens.cached_tokens + (telemetry[:cached_tokens] || 0),
      total_tokens: tokens.total_tokens + total
    }
  end

  # Transient transport failures (timeouts, resets) must not kill a run:
  # retry with backoff before declaring the planner unreachable.
  defp plan_with_retry(state, observation, attempts) do
    result =
      try do
        invoke_planner(state, observation)
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

  defp invoke_planner(%{planner_fn: planner} = state, observation) when is_function(planner, 3),
    do: planner.(state.goal, observation, state.feedback)

  defp invoke_planner(state, observation) do
    observation =
      if state.feedback == "",
        do: observation,
        else: observation <> "\nFEEDBACK:\n" <> state.feedback

    LdHost.Planner.plan(state.goal, observation,
      reasoning_effort: state.current_effort,
      cache_key: Path.basename(state.run_dir)
    )
  end

  defp default_research(goal, manifest, opts), do: Research.run(goal, manifest, opts)

  defp normalize_ooda(value) when value in [:auto, "auto"], do: :auto
  defp normalize_ooda(value) when value in [:off, "off", nil], do: :off
  defp normalize_ooda(value), do: raise(ArgumentError, "invalid ooda mode: #{inspect(value)}")

  defp normalize_effort(value) when value in ~w(low medium high xhigh), do: value

  defp normalize_effort(value) when value in [:low, :medium, :high, :xhigh],
    do: Atom.to_string(value)

  defp normalize_effort(nil), do: nil

  defp normalize_effort(value),
    do: raise(ArgumentError, "invalid reasoning effort: #{inspect(value)}")

  defp normalize_contract(nil), do: nil

  defp normalize_contract(%{claims: claims} = contract) when is_list(claims) do
    %{
      claims: Enum.map(claims, &LdHost.Gates.atomize_claim/1),
      source: Map.get(contract, :source, "approved")
    }
  end

  defp normalize_contract(claims) when is_list(claims) do
    %{claims: Enum.map(claims, &LdHost.Gates.atomize_claim/1), source: "approved"}
  end

  defp judge_label(nil), do: "no gates measured"
  defp judge_label(report), do: report[:judge] || "unknown"

  defp stamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
