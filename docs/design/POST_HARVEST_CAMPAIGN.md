# Post-harvest dictionary campaign protocol

Status: preregistered protocol for the first measurement after the
2026-08-31 dictionary-correctness harvest. This document is deliberately
small: it measures whether honest warm reuse changes a task-family result;
it is not a proposal to add waves, objects, or retrieval.

## Question and scope

The question is: after aliases are quarantined, colon bodies are checked
against the catalog, INSTALL covering is bounded, and candidates are kept
separate from promoted words, does a warm family dictionary improve the same
tasks relative to a fresh dictionary?

The measured organs are A--D (alias quarantine, critic catalog checks,
bounded INSTALL covering, candidate/promotion accounting). F, H, and I are
recorded as safety/accounting behavior: obligation holds fail closed,
unsupported uniqueness axes are omitted, and retrieval cannot authorize a
load. E (interned objects), G (waves), and retrieval as a load path are out
of scope. The Polyglot 96.8% and Terminal-Bench v5 8/15 results in
`beam/RESULTS.md` predate this harvest and receive no credit here.

No benchmark lift is claimed until the campaign below is complete. A
negative or null result is a valid result.

## Freeze before running

Record the repository commit, BEAM release/build identifier, model name,
planner settings, host OS, task order, and the exact command in the run
manifest. Do not change implementation, prompts, task files, timeout
values, verdict thresholds, or the interpretation rules after the first
replicate. Keep the existing verdict thresholds: correctness loss no more
than 5 percentage points, total token reduction at least 25%, no increase in
policy violations, and no negative transfer.

Materialize the dry-run manifest before any paid planner invocation. From the
repository root, use:

```bash
cd beam && mix ld.post_harvest \
  --repo /Users/reuben/projects/living_dict \
  --out /Users/reuben/projects/living_dict/beam/runs/post-harvest \
  --run-id <fixed-id>
```

Archive that manifest beside the raw runs; it is a plan and does not itself
produce a score.

The run is invalid (reported as inconclusive, never as a pass) if any arm
silently omits a task. A planner transport failure may be repeated once with
the same command and a fresh output directory; retain and report the
original failure as well as the repeat. Do not retry a judged task failure to
make a score look better. Internal planner retries and their delays remain
part of the raw evidence.

## Required per-task evidence

The Demo and Polyglot runners now propagate measured dictionary evidence (and
non-placeholder judge provenance) when the underlying obligation summary
provides it. That propagation is not, by itself, proof that the fields have
the required semantics. Before the measured campaign, validate and
materialize the following fields for every cold and warm task row (a sidecar
assembled from the run ledger is acceptable):

```json
{
  "catalog_before": ["INSTALL"],
  "eligible_words": ["INSTALL"],
  "used_words": ["INSTALL"],
  "candidate_words": [],
  "promoted_words": ["INSTALL"],
  "unused_eligible_words": [],
  "critic_covering_rejections": 0,
  "judge": "approved contract"
}
```

Definitions are fixed:

* `catalog_before` is the catalog loaded at episode 1, before the task's
  planner runs. For cold it must be empty; for warm it is the contents of
  the family dictionary at that task's start.
* `eligible_words` is the subset of `catalog_before` with a valid persisted
  contract and critic authorization. It is not a planner mention. Check this
  explicitly: load-all prelude names and valid `Dictionary.load_vocab`
  names are not necessarily the same set.
* `used_words` contains catalog names actually admitted to execution by an
  accepted plan. A rejected plan, a duplicate plan, or a mere text mention
  is not use. If host-call tracing is available, use that stronger evidence;
  otherwise intersect the reuse event with `critic.accepted` and a
  trap-free execution and label the derivation.
* `candidate_words` are names written as `.fs` candidates during this task;
  first persistence is not promotion.
* `promoted_words` are names newly written to `promoted.txt` after clean
  reuse. A candidate that is never reused remains a candidate.
* `unused_eligible_words` is `eligible_words` minus `used_words`.
* `critic_covering_rejections` counts preflight rejections whose reason is
  the INSTALL-covering rule (`catalog has INSTALL; use it instead of
  WRITE-FILE`).
* `judge` is the provenance of the gate result and must be `approved contract`
  for these hidden-verifier rows. The runners copy this value when it is
  measured; validate it end-to-end from the obligation summary/run ledger to
  the arm row and fail validation if it is absent or says `model-authored
  claims`.

At minimum, derive `used_words`, candidates, promotions, and covering
rejections from the per-task `trace.jsonl`/`events.jsonl`; retain those raw
files. Do not infer use from `summary.md` or from a planner rationale.
Validate trap semantics before scoring: a word called during an episode that
later traps must be recorded as unknown (or recovered from host-call trace),
not as an observed empty `used_words` list. An empty list is evidence only
after a trap-free execution with the field marked known.

## Campaign arms and isolation

Use the same model, planner, task prompts, verifier, max-episode budget, and
host build in both arms. Run arms serially so credential refresh and shared
dispatcher scheduling cannot confound a pair. A separate absolute `--out`
directory is required for each replicate; never point a warm dictionary at a
prior replicate.

* **Cold:** fresh workspace and fresh dictionary for every task. No word may
  carry from one task to another.
* **Warm:** fresh workspace for every task, one family-shared dictionary for
  the ordered task sequence. The dictionary is created inside that
  replicate's output directory and is carried only from an earlier warm task
  in the same sequence.
* **Raw evidence:** preserve each output directory, orchestrator ledger,
  per-task run directory, dictionary `words/*.fs`, `promoted.txt` when
  present, planner output, receipt, and the telemetry sidecar. Add a SHA-256
  manifest and the commit/build metadata; do not copy results into
  `compare/runs/`.

The BEAM demo command currently gives each obligation a 600-second wait,
the planner HTTP client a 600-second receive timeout, and the hidden eval
claim a 120-second command timeout. Use `--max-episodes 6` for this family
campaign. A timeout, reset, HTTP error, lease/crash, or missing receipt is a
transport/orchestration observation, not a hidden-verifier failure.

## Primary campaign: parser (three paired replicates)

Run three independent paired replicates over the fixed sequence
`parser-01,parser-02,parser-03`, with no grok baseline:

```bash
cd /Users/reuben/projects/living_dict/beam
mix ld.demo \
  --tasks parser-01,parser-02,parser-03 \
  --arms cold,warm --serial --max-episodes 6 \
  --out /Users/reuben/projects/living_dict/beam/runs/postharvest-parser-01

mix ld.demo \
  --tasks parser-01,parser-02,parser-03 \
  --arms cold,warm --serial --max-episodes 6 \
  --out /Users/reuben/projects/living_dict/beam/runs/postharvest-parser-02

mix ld.demo \
  --tasks parser-01,parser-02,parser-03 \
  --arms cold,warm --serial --max-episodes 6 \
  --out /Users/reuben/projects/living_dict/beam/runs/postharvest-parser-03
```

Do not pool replicates to conceal variance. Report each pair and an
aggregate with the replicate spread. The historical parser-02 warm timeout
and INSTALL negative-transfer suspicion are hypotheses to test, not a
preselected explanation.

## Confirmation campaign: graph

Only after all three parser replicates are archived, run one paired,
family-ordered confirmation over `graph-01` through `graph-08`:

```bash
cd /Users/reuben/projects/living_dict/beam
mix ld.demo \
  --tasks graph-01,graph-02,graph-03,graph-04,graph-05,graph-06,graph-07,graph-08 \
  --arms cold,warm --serial --max-episodes 6 \
  --out /Users/reuben/projects/living_dict/beam/runs/postharvest-graph-01
```

This confirms family transfer only. It does not test waves: no wave speedup
or serial-tree-equivalence claim may be made from this run.

## Conditional Polyglot Rust confirmation

Run a Rust confirmation only if the parser/graph evidence meets this
pre-registered trigger: in at least one warm family, a non-alias catalog word
is reported in `used_words` on two different task rows, with the later row
occurring after the first candidate/promotion. If the trigger is absent,
record “Rust confirmation not triggered”; do not substitute catalog size or
planner mentions for actual reuse.

When triggered, use the existing Polyglot adapter on the Rust track only,
with cold and warm arms, max four episodes, and a new absolute output
directory. Pin the sibling benchmark checkout with `--bench-root` and
record its revision. Verify that the adapter's serial option is wired before
running; an ignored option must not be treated as isolation. The command
shape is:

```bash
cd /Users/reuben/projects/living_dict/beam
mix ld.polyglot --langs rust --arms cold,warm --max-episodes 4 \
  --sample 30 \
  --bench-root /absolute/path/to/polyglot-benchmark \
  --out /Users/reuben/projects/living_dict/beam/runs/postharvest-polyglot-rust-01
```

This is a confirmation, not a new headline Polyglot score and not a reason
to attribute the August 96.8% result to the harvest.

## Failure classification and scoring

Classify every task-arm attempt before looking at warm/cold differences:

| class | evidence | scoring treatment |
|---|---|---|
| transport | planner timeout/reset/HTTP error, missing response | retain raw attempt; exclude from judged complete-case metrics; if one arm of a pair is missing, verdict is inconclusive |
| orchestration | obligation lease loss, crash, hold/probe failure, missing run receipt | report separately; never call it a verifier failure |
| critic/policy | preflight rejection, forbidden path, ABI/policy violation | task did not discharge; count policy telemetry and covering reason |
| task failure | trap-free execution followed by the protected verifier returning non-zero | judged failure |
| negative transfer | cold judged pass, warm judged fail, and `used_words` is non-empty | fails the preregistered verdict |
| warm confound | warm fails while `used_words` is empty | report as warm-arm/planner/transport confound, not dictionary harm |

For each complete pair, apply `LdHost.Verdict.measures` exactly as shipped:
correctness is pass percentage, token cost is input plus output tokens, and
policy/negative-transfer flags are not optional. Also show input-only token
counts as descriptive sensitivity; they cannot replace the primary measure.

## Task-level report table

Publish one row per task per replicate, with cold and warm values side by
side. The interpretation column is filled only after telemetry is attached:

| replicate | task | cold result | warm result | catalog before | eligible | used | candidates | promoted | covering rejects | failure class | interpretation |
|---|---|---|---|---|---|---|---|---|---:|---|---|
| P01 | parser-02 | pass | fail/timeout | INSTALL | INSTALL | — | — | — | 1 | pending classification | do not label negative transfer until use is proven |

For a claimed mechanism, show the exact `dictionary.reuse`, critic verdict,
execution/gate, candidate, and promotion events that support it. A used word
plus a better outcome is evidence consistent with reuse, not a counterfactual
proof from one stochastic pair.

## Preregistered decision matrix

| observation | conclusion |
|---|---|
| warm correctness improves, an actually used word is present, and total tokens fall at least 25% | measured dictionary lift; report effect size and spread |
| correctness is equal and tokens fall below 25% | safe reuse, token-amortization NO-GO |
| correctness is equal and no word is actually used | no demonstrated catalog effect |
| warm regresses while an eligible word is used | negative transfer; NO-GO |
| warm regresses without word use | warm-arm/planner/transport confound; no reuse claim |
| covering rejections are followed by later successful use | rule C has demonstrated useful feedback |
| covering rejections occur without later successful use | pressure without demonstrated benefit |
| candidates appear but never promote | persistence works; promotion/transfer not demonstrated |
| words promote but later tasks never use them | promotion criterion or catalog relevance remains unvalidated |
| any required pair is incomplete after the allowed transport repeat | campaign inconclusive; no score or lift claim |

## Exact non-claims

This campaign does **not** claim that:

1. the August Polyglot or Terminal-Bench numbers were caused by A--I;
2. uniqueness axes improved a live scoreboard (unsupported axes remain
   omitted);
3. waves, interned objects, or retrieval shipped or improved throughput;
4. INSTALL covering is beneficial merely because it rejects a zipper;
5. first persistence is promotion, or promotion alone is transfer;
6. one warm/cold difference proves causality without repeated task-family
   evidence; or
7. a transport timeout is a task failure, or a model-authored claim is an
   approved hidden-judge result.
