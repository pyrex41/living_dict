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

  alias LdHost.{Critic, Contracts, Dictionary, Envelope, Forth, Gates, Host, Ledger, Policy, Store}

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

    if contract do
      {:ok, _} =
        Ledger.commit(ledger, "contract.approved", %{
          claims: length(contract.claims),
          source: contract.source
        })
    end

    {prelude, prelude_words} = Dictionary.load_prelude(dictionary_dir)
    store = Store.open(Path.join(run_dir, "objects"))

    state = %{
      goal: goal,
      workspace: workspace,
      run_dir: run_dir,
      dictionary_dir: dictionary_dir,
      ledger: ledger,
      store: store,
      contract: contract,
      allow_model_checks: Keyword.get(opts, :allow_model_checks, false),
      planner_fn: planner_fn,
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
      last_used_words: [],
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

      state = %{
        state
        | seen: MapSet.put(state.seen, fingerprint),
          reused_names: reused,
          last_used_words: reused
      }

      artifact_sha256 = artifact_digests(envelope.artifacts)
      persist_envelope(state, envelope, artifact_sha256)

      {:ok, _} =
        Ledger.commit(state.ledger, "episode.planned", %{
          episode: episode,
          fingerprint: fingerprint,
          rationale: envelope.rationale,
          used_words: reused,
          artifact_sha256: artifact_sha256
        })

      composed = compose(state.prelude, envelope.program)
      artifact_keys = envelope.artifacts |> Map.keys() |> Enum.sort()

      case Critic.validate(
             composed,
             state.allowed_effects,
             state.allowed_globs,
             state.forbidden_globs,
             artifact_keys
           ) do
        {:reject, errors, _depth, _effects} ->
          {:ok, _} =
            Ledger.commit(state.ledger, "critic.rejected", %{episode: episode, errors: errors})

          Ledger.trace(state.ledger, "preflight.rejected", %{errors: errors})
          {:continue, feedback(state, "critic rejected the plan:\n" <> Enum.join(errors, "\n"))}

        {:accept, depth, effects} ->
          intern_artifacts(state, envelope.artifacts)

          {:ok, _} =
            Ledger.commit(state.ledger, "critic.accepted", %{
              episode: episode,
              depth: depth,
              effects: effects,
              artifact_sha256: artifact_sha256
            })

          execute_episode(state, episode, envelope, composed)

        {:error, reason} ->
          Ledger.trace(state.ledger, "critic.unavailable", %{reason: reason})
          {:halt, state}
      end
    end
  end

  defp execute_episode(state, episode, envelope, composed) do
    objects_dir = Path.join(state.run_dir, "objects")

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
        objects_dir: objects_dir,
        receipt_path: Path.join(state.run_dir, "receipt.json")
      )

    vm =
      %Forth.VM{host: host, artifacts: envelope.artifacts}
      |> Forth.bind_vocab(Dictionary.load_vocab(state.dictionary_dir))

    Ledger.trace(state.ledger, "execution.program", %{program: envelope.program})

    case interpret(vm, envelope.program) do
      {:trap, code, message} ->
        Ledger.trace(state.ledger, "execution.trap", %{code: code, message: message})
        {:continue, feedback(state, "execution trap [#{code}]: #{message}")}

      {:ok, vm} ->
        {:ok, _} =
          Ledger.commit(state.ledger, "artifacts.applied", %{
            episode: episode,
            count: map_size(envelope.artifacts),
            keys: envelope.artifacts |> Map.keys() |> Enum.sort(),
            artifact_sha256: artifact_digests(envelope.artifacts)
          })

        report = vm.host.last_check || Gates.run(vm.host)

        {:ok, _} =
          Ledger.commit(state.ledger, "gates.measured", %{
            episode: episode,
            ok: report.ok == true,
            reason: report[:reason],
            tree_after: Policy.snapshot(state.workspace)
          })

        state = %{state | last_report: report}
        state = promote(state, episode, vm, composed, report)

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

  defp compose("", program), do: program
  defp compose(prelude, program), do: prelude <> "\n" <> program

  defp intern_artifacts(state, artifacts) when is_map(artifacts) do
    Enum.each(artifacts, fn {_key, body} ->
      if is_binary(body) do
        Store.intern(state.store, body)
      end
    end)
  end

  defp artifact_digests(artifacts) when is_map(artifacts) do
    Map.new(artifacts, fn {key, body} -> {key, Policy.sha256_hex(to_string(body))} end)
  end

  defp artifact_digests(_), do: %{}

  defp persist_envelope(state, envelope, artifact_sha256) do
    payload = %{
      "language" => "forth",
      "program" => envelope.program,
      "artifacts" => artifact_sha256,
      "rationale" => envelope.rationale
    }

    File.write!(Path.join(state.run_dir, "envelope.json"), JSON.encode!(payload))
  end

  defp observe(state) do
    events = Ledger.events(state.ledger)
    revision = Ledger.revision(state.ledger)
    tree = Store.as_of(events, revision)
    tree = if tree == %{}, do: Policy.snapshot(state.workspace), else: tree

    unused =
      MapSet.new(state.prelude_words)
      |> MapSet.difference(MapSet.new(state.last_used_words))
      |> Enum.sort()

    tree_lines =
      tree
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {rel, sha} -> "#{rel}  #{sha}" end)

    dictionary =
      case state.prelude_words do
        [] ->
          ""

        words ->
          "\nHARNESS DICTIONARY (callable colon words):\n" <> Enum.join(words, " ")
      end

    unused_s =
      case unused do
        [] -> ""
        names -> "\nUNUSED: " <> Enum.join(names, " ")
      end

    gates =
      case state.last_report do
        nil -> ""
        report -> "\nGATES: " <> JSON.encode!(scrub(report))
      end

    hashes =
      case tree_lines do
        [] -> "\nWORKSPACE TREE:\n(empty)"
        lines -> "\nWORKSPACE TREE:\n" <> Enum.join(lines, "\n")
      end

    install_hint =
      if tree == %{} do
        ""
      else
        "\nUnchanged files may be reinstalled by hash: S\" <sha256>\" USE-OBJECT S\" path\" WRITE-FILE"
      end

    feedback =
      case state.feedback do
        "" -> ""
        text -> "\nFEEDBACK:\n" <> text
      end

    hashes <> dictionary <> unused_s <> gates <> install_hint <> feedback
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

  defp default_planner(goal, observation, feedback) do
    observation =
      if feedback == "", do: observation, else: observation <> "\nFEEDBACK:\n" <> feedback

    LdHost.Planner.plan(goal, observation)
  end

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
