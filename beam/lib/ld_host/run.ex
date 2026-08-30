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

  alias LdHost.{Critic, Contracts, Dictionary, Envelope, Extract, Forth, Gates, Host, Ledger, Policy, Retrieve, Store}

  @default_max_episodes 6

  def run(goal, opts) do
    workspace = Keyword.fetch!(opts, :workspace) |> Path.expand()
    run_dir = Keyword.get(opts, :run_dir, Path.join([workspace, ".livingdict-run", "beam-" <> stamp()]))
    dictionary_dir = Keyword.get(opts, :dictionary_dir, Path.join(run_dir, "dictionary"))
    max_episodes = Keyword.get(opts, :max_episodes, @default_max_episodes)
    contract = normalize_contract(Keyword.get(opts, :contract))
    planner_fn = Keyword.get(opts, :planner_fn, &default_planner/3)

    {:ok, ledger} = Ledger.start_link(run_dir)

    if contract do
      {:ok, _} = Ledger.commit(ledger, "contract.approved", %{claims: length(contract.claims), source: contract.source})
    end

    store = Store.new(Path.join(run_dir, "objects"))
    freeze = freeze_from_dir(run_dir)

    {dictionary_hash, _display, _hex} =
      case freeze do
        :empty ->
          Dictionary.intern_from_dir(store, dictionary_dir)

        %{dictionary_hash: hex} ->
          {hex, Dictionary.hash_display(hex), hex}
      end

    allowed_effects = Keyword.get(opts, :allowed_effects, ["read", "write", "exec"])
    allowed_globs = Keyword.get(opts, :allowed_globs, ["**"])

    forbidden_globs =
      Keyword.get(opts, :forbidden_globs, [".livingdict-run/*", ".git/*", "node_modules/*", "dist/*"])

    dict_mode = Retrieve.mode(opts)
    retrieve_query = Retrieve.host_query(allowed_effects, allowed_globs, forbidden_globs)
    identity = identity_blob(store, dictionary_hash)
    facts = Store.facts(load_events(run_dir))

    {prelude, prelude_words} =
      Dictionary.load_prelude(dictionary_dir,
        dict_mode: dict_mode,
        query: retrieve_query,
        facts: facts,
        identity: identity
      )

    state = %{
      goal: goal,
      workspace: workspace,
      run_dir: run_dir,
      dictionary_dir: dictionary_dir,
      ledger: ledger,
      store: store,
      freeze: freeze,
      dictionary_hash: dictionary_hash,
      contract: contract,
      allow_model_checks: Keyword.get(opts, :allow_model_checks, false),
      planner_fn: planner_fn,
      prelude: prelude,
      prelude_words: prelude_words,
      dict_mode: dict_mode,
      retrieve_query: retrieve_query,
      used_prelude_words: MapSet.new(),
      allowed_effects: allowed_effects,
      allowed_globs: allowed_globs,
      forbidden_globs: forbidden_globs,
      extract?: Extract.enabled?(opts),
      seen: MapSet.new(),
      feedback: "",
      last_report: nil,
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
      promoted_words: elem(result, 1).promoted_words,
      run_dir: run_dir,
      dict_mode: elem(result, 1).dict_mode,
      retrieve_query: retrieve_query_for_trace(elem(result, 1)),
      prelude_words: elem(result, 1).prelude_words,
      prelude_bytes: byte_size(elem(result, 1).prelude),
      used_prelude_words: Enum.sort(elem(result, 1).used_prelude_words),
      unused_loaded_words:
        elem(result, 1).prelude_words -- Enum.sort(elem(result, 1).used_prelude_words)
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
        Ledger.commit(state.ledger, "episode.blocked_duplicate", %{episode: episode, fingerprint: fingerprint})

      {:continue,
       feedback(state, "identical plan resubmitted and blocked — change the plan, the errors stand")}
    else
      state = %{state | seen: MapSet.put(state.seen, fingerprint)}

      {:ok, _} =
        Ledger.commit(state.ledger, "episode.planned", %{
          episode: episode,
          fingerprint: fingerprint,
          rationale: envelope.rationale
        })

      # Nested cartridge is parse/fingerprint material. Overlay execute is
      # PR 6 (`LD_CARTRIDGE=1`); default 0 interprets envelope.program.
      composed = compose(state.prelude, envelope.program)
      artifact_keys = envelope.artifacts |> Map.keys() |> Enum.sort()

      case Critic.validate(composed, state.allowed_effects, state.allowed_globs, state.forbidden_globs, artifact_keys) do
        {:reject, errors, _depth, _effects} ->
          {:ok, _} = Ledger.commit(state.ledger, "critic.rejected", %{episode: episode, errors: errors})
          Ledger.trace(state.ledger, "preflight.rejected", %{errors: errors})
          {:continue, feedback(state, "critic rejected the plan:\n" <> Enum.join(errors, "\n"))}

        {:accept, depth, effects} ->
          {:ok, _} =
            Ledger.commit(state.ledger, "critic.accepted", %{episode: episode, depth: depth, effects: effects})

          state = record_reuse(state, envelope.program)
          execute_episode(state, episode, envelope, composed)

        {:error, reason} ->
          Ledger.trace(state.ledger, "critic.unavailable", %{reason: reason})
          {:halt, state}
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
        receipt_path: Path.join(state.run_dir, "receipt.json")
      )

    vm = %Forth.VM{host: host, artifacts: envelope.artifacts}

    case interpret(vm, composed) do
      {:trap, code, message} ->
        Ledger.trace(state.ledger, "execution.trap", %{code: code, message: message})
        {:continue, feedback(state, "execution trap [#{code}]: #{message}")}

      {:ok, vm} ->
        {:ok, _} =
          Ledger.commit(state.ledger, "artifacts.applied", %{
            episode: episode,
            count: map_size(envelope.artifacts)
          })

        report = vm.host.last_check || Gates.run(vm.host)
        {:ok, _} = Ledger.commit(state.ledger, "gates.measured", %{episode: episode, ok: report.ok == true, reason: report[:reason]})

        state = %{state | last_report: report}
        state = promote(state, episode, vm, composed, report, envelope.program)

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

  defp promote(state, episode, vm, composed, report, program) do
    contracts = Contracts.extract(composed)
    candidates = Forth.defined_names(vm) -- state.prelude_words

    eligible? = report.ok == true

    {promotable, quarantined} =
      Enum.split_with(candidates, fn name ->
        eligible? and Map.has_key?(contracts, name) and
          Contracts.canonical(contracts[name]) != nil
      end)

    entries =
      Enum.map(promotable, fn name ->
        {name, Dictionary.body_source(vm.colon[name]), Contracts.canonical(contracts[name])}
      end)

    written = Dictionary.save_words(state.dictionary_dir, entries, allowed_globs: state.allowed_globs)

    Enum.each(written, fn {name, sha} ->
      contract = Contracts.canonical(contracts[name])
      body = Dictionary.body_source(vm.colon[name])
      identity = Dictionary.persist_identity(body, contract, state.allowed_globs)
      record_promoted(state, episode, name, sha, contract, identity)
    end)

    Enum.each(quarantined, fn name ->
      reasons =
        [] ++
          if(not Map.has_key?(contracts, name), do: ["missing contract"], else: []) ++
          if(report.ok != true, do: ["claims not discharged"], else: [])

      record_evidence(state, episode, name, reasons)
    end)

    {state, extract_written} = maybe_extract(state, episode, vm, report, program, candidates)
    written = written ++ extract_written
    state = %{state | promoted_words: state.promoted_words ++ Enum.map(written, &elem(&1, 0))}

    if written != [] do
      parent = state.dictionary_hash
      {hex, _display, _h} = Dictionary.intern_from_dir(state.store, state.dictionary_dir, parent: parent)
      {prelude, words} = load_current_prelude(%{state | dictionary_hash: hex})
      %{state | prelude: prelude, prelude_words: words, dictionary_hash: hex}
    else
      state
    end
  end

  # Fallback only: no new planner colon names after gates.ok.
  defp maybe_extract(state, episode, vm, report, program, planner_names) do
    if report.ok == true and planner_names == [] and state.extract? do
      extract_and_admit(state, episode, vm, program)
    else
      {state, []}
    end
  end

  defp extract_and_admit(state, episode, vm, program) do
    mutations = host_mutations(vm)

    case Extract.candidate(program, mutations: mutations) do
      :none ->
        {state, []}

      {:refuse, cand, reasons} ->
        record_evidence(state, episode, cand.name, reasons)
        {state, []}

      {:ok, cand} ->
        if Extract.identical_source?(state.dictionary_dir, cand) do
          {state, []}
        else
          grant = [
            prelude: state.prelude,
            allowed_effects: state.allowed_effects,
            allowed_globs: state.allowed_globs,
            forbidden_globs: state.forbidden_globs,
            artifact_keys: cand.path_region
          ]

          case Extract.admit(cand, grant) do
            {:accept, _depth, _effects} ->
              written = Extract.persist(state.dictionary_dir, cand)

              Enum.each(written, fn {name, sha} ->
                identity = Dictionary.persist_identity(cand.body, cand.contract, cand.path_region)
                record_promoted(state, episode, name, sha, cand.contract, identity)
              end)

              {state, written}

            {:reject, errors} ->
              record_evidence(state, episode, cand.name, errors)
              {state, []}
          end
        end
    end
  end

  defp host_mutations(vm) do
    host = vm.host

    if host && host.workspace && File.dir?(host.workspace) do
      Policy.changed_files(host.before, Policy.snapshot(host.workspace))
    else
      []
    end
  end

  defp record_promoted(state, episode, name, sha, contract, identity) do
    {:ok, _} =
      Ledger.commit(state.ledger, "dictionary.promoted", %{
        word: name,
        sha256: sha,
        contract: contract,
        episode: episode,
        effects: identity["effects"],
        path_region: identity["path_region"],
        task_families: identity["task_families"],
        parent_dict: state.dictionary_hash,
        primitive_contract: Forth.primitive_contract()
      })

    Ledger.trace(state.ledger, "dictionary.promote", %{
      word: name,
      sha256: sha,
      contract: contract,
      effects: identity["effects"],
      path_region: identity["path_region"],
      task_families: identity["task_families"]
    })
  end

  defp record_evidence(state, episode, name, reasons) do
    {:ok, _} =
      Ledger.commit(state.ledger, "dictionary.promotion_evidence", %{
        word: name,
        episode: episode,
        eligible: false,
        reasons: reasons
      })

    Ledger.trace(state.ledger, "dictionary.quarantined", %{word: name, reasons: reasons})
  end

  @doc """
  Host freeze pointer: last `dictionary.overlay.admitted` in event order.
  Proposed/rejected/discarded/promoted/narrowed do not move it.
  """
  def freeze_of(events) when is_list(events) do
    Enum.reduce(events, :empty, fn event, last ->
      if field(event, "kind") == "dictionary.overlay.admitted" do
        payload = field(event, "payload") || %{}

        %{
          dictionary_hash: Dictionary.digest_hex(field(payload, "dictionary_hash")),
          overlay_hash: Dictionary.digest_hex(field(payload, "overlay_hash")),
          primitive_contract: Dictionary.digest_hex(field(payload, "primitive_contract"))
        }
      else
        last
      end
    end)
  end

  def freeze_from_dir(run_dir), do: freeze_of(load_events(run_dir))

  def load_events(run_dir) do
    path = Path.join(run_dir, "events.jsonl")

    case File.read(path) do
      {:ok, bin} ->
        bin
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      _ ->
        []
    end
  end

  @doc "Overlay execute flag. Default 0: parse/fingerprint only (PR 3)."
  def cartridge_enabled? do
    System.get_env("LD_CARTRIDGE", "0") in ["1", "true"]
  end

  @doc "Extract-after-success. Default 1; `LD_EXTRACT=0` disables."
  def extract_enabled?(opts \\ []), do: Extract.enabled?(opts)

  defp load_current_prelude(state) do
    Dictionary.load_prelude(state.dictionary_dir,
      dict_mode: state.dict_mode,
      query: state.retrieve_query,
      facts: Store.facts(load_events(state.run_dir)),
      identity: identity_blob(state.store, state.dictionary_hash)
    )
  end

  defp identity_blob(_store, nil), do: %{}

  defp identity_blob(store, hex) do
    case Store.get(store, hex) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{} = blob} -> blob
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp record_reuse(state, program) do
    used = Dictionary.used_names(program, state.prelude_words)

    Enum.each(used, fn name ->
      Ledger.trace(state.ledger, "dictionary.reuse", %{word: name, version: 1})
    end)

    %{state | used_prelude_words: MapSet.union(state.used_prelude_words, MapSet.new(used))}
  end

  defp retrieve_query_for_trace(state) do
    if state.dict_mode == :retrieved, do: state.retrieve_query, else: Retrieve.load_all_query()
  end

  defp field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom, do: Map.get(map, atom)
    end
  end

  # ---- helpers ----------------------------------------------------------

  defp compose("", program), do: program
  defp compose(prelude, program), do: prelude <> "\n" <> program

  @observe_file_cap 8_000
  @observe_total_cap 60_000

  defp observe(state) do
    Ledger.trace(state.ledger, "dictionary.retrieve", %{
      query: retrieve_query_for_trace(state),
      candidates: state.prelude_words,
      mode: Atom.to_string(state.dict_mode)
    })

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
      case state.prelude_words do
        [] -> ""
        words -> "\nHARNESS DICTIONARY (callable colon words):\n" <> Enum.join(words, " ") <> "\n" <> state.prelude
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

  defp record_model_call(state, telemetry) do
    Ledger.trace(state.ledger, "llm.response", telemetry)

    {:ok, _} = Ledger.commit(state.ledger, "budget.consumed", Map.put(telemetry, :episode, state.episode))

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
    observation = if feedback == "", do: observation, else: observation <> "\nFEEDBACK:\n" <> feedback
    LdHost.Planner.plan(goal, observation)
  end

  defp normalize_contract(nil), do: nil

  defp normalize_contract(%{claims: claims} = contract) when is_list(claims) do
    %{claims: Enum.map(claims, &LdHost.Gates.atomize_claim/1), source: Map.get(contract, :source, "approved")}
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
