# How the live harness is supposed to work

This is not a recipe for a Solid/Three landing page. It is the loop
that has to survive *any* goal without rejecting itself.

## What failed

Episode 1 of a new job emitted:

```
S" GOAL.md" READ-FILE DROP
S" PROGRESS.md" READ-FILE DROP
RUN-GATES
RECEIPT
```

`READ-FILE` traps on a missing file. `PROGRESS.md` is written *after*
an episode. The planner was following a prompt that said “read
PROGRESS.md every episode.” The harness failed the job before any
product work. That is a harness bug, not a model bug.

Pi does not die because a skill file is absent. Ralph allocates the
same stack every loop (`PROMPT.md`, specs, `fix_plan.md`) *before*
the model runs. Shen-Backpressure feeds gate failures forward; it
does not ask the model to `cat` a file that does not exist.

## Contract

```
user goal
    │
    ▼
host allocates job state in run_dir   ← not in the product tree
    │
    ▼
planner observes workspace
    emits Forth + artifacts
    │  host appends RUN-GATES RECEIPT if missing
    ▼
Shen Accept | Reject              ← policy / unknown word
    │  Reject → record errors, next episode (not halt)
    ▼
host interns artifact bodies          ← run_dir/objects; envelope stays full-body
host applies envelope.artifacts       ← each key is a graph node
    waves: out node.ready; workers take
Forth runs remaining words
    RUN-GATES measures claims/build/look
    receipts / gates.measured gain tree_* hashes
    │
    ▼
reconcile: success if claims discharged, else plan until cap
```

The model is not in the loop while words run. It is also not allowed
to be the thing that creates the job stack. The host owns that.

## Rules that keep the loop alive

1. **Job state is not a product file.** `GOAL.md` / `PROGRESS.md` are
   not written into the workspace, so they cannot be `READ-FILE`'d.
2. **Episode 1 is a new job.** Leftover product files are just files,
   not “already done.”
3. **Every goal episode runs `RUN-GATES`.** If the model forgets,
   the host inserts it. A program that only reads and receipts still
   measures.
4. **One increment per episode.** Ralph: one thing. Progress is the
   next prompt, not a 5-turn sprint.
5. **Stop on discharged claims, or halt at the cap.** Cap is 32, and
   it is a halt, not success. Structural green is not success.
   Critic reject is backpressure (see [`GRAPH.md`](design/GRAPH.md)).
   The sequential loop carries that on `events.jsonl`, not a second
   tuple copy (see [`STORE.md`](design/STORE.md)).
6. **Eval stays on six words.** Live host may grow words later
   (`READ-FILE?`, `RUN-CMD`). Missing-file traps stay for real
   product reads. There is no model-facing `TAKE` / `OUT`.
7. **Job state includes a store, not a second log.** Blobs live under
   `run_dir/objects` (or `LIVINGDICT_OBJECTS`). `as_of(seq)` rebuilds
   the workspace tree from recorded hashes. Old runs without `objects/`
    still replay.

8. **Checks may declare a shared fixture.** An approved `kind: "check"` claim
   can include `fixture: {command, ready_url, ready_timeout_seconds}`. The
   host starts that fixture once for all claims with the same fixture object,
   polls readiness instead of relying on fixed sleeps, and always tears it
   down. Claims without `fixture` retain their existing one-command behavior.
   Successful deterministic source/bundle gates are cached under
   `.livingdict-run/gates-cache.json` and invalidated by the workspace/spec
   fingerprint; check claims are never cached.

9. **Model-authored claims are audited, not trusted blindly.** Gate reports
   record `claim_quality` and `progress`. Changes limited to `claims.json`,
   `.sb/`, or `.livingdict-run/` do not count as product progress. Source/file
   claims are weak evidence; executable checks or benchmark-native verifiers
   remain the meaningful behavior signal. `--benchmark` is an explicit
   isolated auto-approval lane: model-authored check claims are executed,
   while source-only contracts remain incomplete and are fed back to the
   planner. For behavior-oriented goals, compile-only, file-size, and
   executable-presence checks are structural and cannot discharge the
   contract without a check that invokes the product and observes a result.
   Normal runs still require hidden/approved contracts for checks.

   Adapters may provide an advisory `oracle_feedback(workspace, report)`
   callback to `run_job`. Its structured result is shown to the next planner
   episode and recorded with the gate report, but it cannot approve claims,
   mutate the frozen contract, or change the core success predicate.

To score this loop against grok headless and pi headless on the same
prompt, see [`COMPARE.md`](COMPARE.md).

## Cache isolation

Live model drivers accept `--cache-scope off|run|shared` (`run` by default).
Benchmark mode always forces `run` and allocates a fresh private routing id.
`shared` is an explicit production optimization; it is never used for a
headline benchmark. `off` omits provider affinity hints but cannot promise a
cold provider cache because xAI may still reuse an exact prefix
opportunistically.

Provider caching is exact-prefix KV reuse, not response reuse. Stable system,
goal, tool schemas, assistant reasoning, tool calls, and tool results are
preserved and later turns append messages. Research and planner phases use
different hashed routing ids. Ledgers record cached tokens and routing-key
fingerprints, never routing ids or prompt text.

OODA additionally caches bounded read-only tool results. Run entries remain in
the run directory; shared entries use the platform cache directory. Keys cover
the workspace manifest, canonical tool arguments, and cache format version.
Planner envelopes, critic decisions, checks, receipts, and credentials are
never cached.

For request-shape audits, run `tools/llm_cache_recorder.py --ledger PATH` and
point `LIVINGDICT_PLANNER_ENDPOINT` (BEAM) or `LIVINGDICT_API_BASE` (Python) at
its listener. The recorder retains hashes, sizes, timing, and provider usage
only; authorization and plaintext messages are not written.

## What “works” means

You can type any goal. The first episode does not reject itself.
Later episodes see the product tree plus last discharge. The work pane
shows diffs and a live product *if this job built one*. You only
speak again to change the goal or stop.
