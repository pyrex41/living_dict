# Latest-harness benchmark campaign

Status: execution plan. This campaign replaces, rather than retroactively
updates, the August 2026 results. It measures the current planner, bounded OODA
research, critic, dictionary lifecycle, provider-cache isolation, and telemetry
as one frozen harness.

## Questions

Keep four questions separate:

1. Does the latest Living Dictionary pass the protected task?
2. How many calls, tokens, and seconds does it use?
3. Does a family-warm dictionary produce observed reuse without negative
   transfer?
4. Does run-scoped provider caching reduce cost or latency without changing
   correctness?

Provider cached tokens are not dictionary reuse. A populated dictionary is not
evidence that a word executed. Do not collapse these mechanisms into one score.

## Freeze before paid calls

Create a clean campaign commit. Archive a manifest containing:

- Living Dictionary commit and dirty-tree hash;
- model, provider, endpoint, reasoning effort, and protocol;
- BEAM/Elixir/OTP versions and release digest;
- benchmark versions, revisions, selected task IDs, and protected-file hashes;
- commands, task/arm order, episode limits, and timeouts;
- cache scope, OODA mode, dictionary path, and raw-output path;
- OpenCode/Grok/Pi versions for each baseline actually run.

Run `make test`, `make client-test`, and a manifest-only dry run before the
freeze. A failure blocks the campaign; it is not fixed after the first measured
call. Never edit `eval/` or `compare/runs/`. Write new artifacts under
`beam/runs/latest-<UTC timestamp>/` and retain every attempt.

The primary configuration is one pinned model and provider, medium reasoning,
`--ooda auto`, `--cache-scope run`, serial task arms, six eval episodes, and
four Polyglot episodes. Each invocation gets a fresh cache routing identity.
Exact-prefix caching may occur inside that invocation, but routing and local
evidence caches cannot cross task arms.

## Stage 0: instrumentation smoke

Run pristine copies of `graph-08` and `parser-02`; both must pass their
protected verifier. Every scored row and raw ledger must provide:

- task, arm, model, judge provenance, success, episodes, and failure class;
- per-call input, output, reasoning, cached, and total tokens;
- provider-call and end-to-end duration;
- cache scope/phase, routing fingerprint, prefix hash, and tool-schema hash;
- research rounds, tool calls, evidence bytes, evidence-cache hits/misses;
- `catalog_before`, `eligible_words`, `used_words`, `candidate_words`,
  `promoted_words`, `unused_eligible_words`, and covering rejections.

Unknown data stays absent, not zero. Usage after a trap is unknown unless the
VM retained direct invocation evidence.

## Stage 1: provider-cache A/B

This is a mechanism experiment, not the headline run. Use pristine workspaces
and alternate order:

```text
replicate 1: off, run
replicate 2: run, off
replicate 3: off, run
replicate 4: run, off
```

Run `graph-08` plus one task that reliably takes multiple episodes. Pin every
other setting. Score correctness first, then compare cached tokens, uncached
input (`input - cached`), output/reasoning tokens, provider-call latency, and
end-to-end latency. Publish every replicate and median/spread. Because `off`
cannot disable opportunistic provider caching, use returned usage rather than
the requested scope as evidence. Exclude `shared` caching from isolated
headline benchmarks.

## Stage 2: all 40 vendored eval tasks

Run cold and warm arms with three independent paired replicates. Cold gets a
fresh dictionary per task. Warm gets a fresh family dictionary per replicate,
carried only forward within that family. Preserve the fixed eight-task order in
each of the five families.

Extend the manifest generator to enumerate the complete task list before
running this command shape:

```bash
cd beam
mix ld.demo \
  --tasks <fixed-comma-separated-40-task-order> \
  --arms cold,warm --serial --max-episodes 6 \
  --out <campaign-root>/eval-r<replicate>
```

Run the protected verifier for every arm. Report task rows, family aggregates,
the 40-task aggregate, and replicate spread. Keep the preregistered warm
dictionary bar: no more than five percentage points of correctness loss, at
least 25% total-token reduction, no new policy violations, and no negative
transfer.

## Stage 3: same-model coding-agent baseline

Compare against the current practical baseline—OpenCode when it can be pinned
to the identical model/provider, otherwise Grok or Pi. Give every arm the same
prompt, initial tree, protected judge, wall-clock limit, and filesystem policy.
Run one complete 40-task replicate; repeat a family when pass rates differ by
more than one task.

Preserve native event streams and provider usage. The comparison unit is the
protected result, not process exit. Publish capability differences (context
files, shell freedom, approvals, network, and concurrency) rather than calling
unlike sandboxes identical. Missing baseline telemetry remains unavailable; it
must not be estimated.

## Stage 4: Aider Polyglot

Pin the `polyglot-benchmark` revision. Run complete Rust, Go, and C++ tracks
with cold and warm arms:

```bash
cd beam
mix ld.polyglot \
  --langs rust,go,cpp --arms cold,warm --max-episodes 4 \
  --bench-root <pinned-polyglot-checkout> \
  --out <campaign-root>/polyglot
```

Run the same-model baseline on all exercises or a preregistered common subset.
Never compare a 30-task baseline directly with a 95-task denominator. Before
running, verify a real serial option through the whole adapter; a silently
ignored flag blocks this stage. Offline guards and native tests remain the
judge.

## Stage 5: Terminal-Bench through Harbor

Build one immutable BEAM release and record its digest. Use the same curated
15-task set as the historical report, pinning dataset and task revisions. Run
an environment-only canary first to prove OrbStack/Docker setup, artifact copy,
teardown, and verifier execution.

Follow [`bench/README.md`](../../bench/README.md) with
`bench/harbor_ld_beam.py`. Run serially unless Harbor isolation has separately
been validated. Container build, artifact copy, teardown, and missing-receipt
errors are infrastructure failures, not task failures. A broader
Terminal-Bench run may follow as a separate exploratory table; it cannot replace
the matched 15-task denominator.

## Classification and retry policy

| Class | Meaning | Treatment |
|---|---|---|
| pass | Protected verifier passed | solved |
| task failure | Accepted execution completed; verifier failed | unsolved |
| critic/policy | Proposed plan violated a declared boundary | unsolved; separate count |
| transport | Provider timeout/reset/invalid response | incomplete pair |
| orchestration | Lease, runner, receipt, or host failure | incomplete pair |
| environment | Missing toolchain/container/artifact infrastructure | incomplete pair |
| negative transfer | Cold passes, warm fails, and warm used an eligible word | warm NO-GO |
| warm confound | Warm fails with no observed dictionary use | not dictionary harm |

Retain the original plus one identically configured retry for transport or
infrastructure failures. Never retry a protected task failure to improve the
score.

## Reporting and replacement rule

Publish raw artifacts with a SHA-256 inventory. Report correctness and
denominator; confidence interval; calls; input/output/reasoning/total tokens;
cached and uncached input separately; provider and end-to-end latency
distributions; OODA activity; dictionary eligibility/use/promotion; and every
failure class. Include task-level rows and replicate spread.

The August numbers remain labeled historical. Replace a README headline only
after its complete corresponding stage passes evidence validation. A null or
negative result is publishable; missing telemetry is not.
