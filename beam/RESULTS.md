# Arms race results

The published campaign numbers below are pre-harvest results: these runs
landed 2026-08-26--28, while the dictionary-correctness harvest landed
2026-08-31. They therefore do **not** measure, or receive credit for, the
harvested A--I ideas. In particular, do not attribute the Polyglot 96.8%
or Terminal-Bench v5 8/15 figures to those changes.

Uniqueness axes (family-transfer, contract-first, replay-without-model,
wave-speedup, obligation-hold) remain observational instrumentation, not a
headline score: historical summaries do not carry the required
`used_words`/`promoted` fields, and waves or interned objects are not on
main. Terminal-Bench remains Harbor hygiene, not the go/no-go.

## Bounded OODA canary, 2026-09-01

Same `grok-4.6`, cold isolated workspaces, approved hidden verifiers, three
serial replicates per arm on parser-02 and graph-08. Auto results are from
`f1de811`; two fixed-high replicates are from that revision and the first is
from `368452a` before two auto-only routing fixes. Raw artifacts are under
`/tmp/ooda-canary-f1de811` and `/tmp/ooda-canary-368452a`.

| task | fixed-high pass | auto pass | median wall, fixed -> auto | median total tokens, fixed -> auto |
|---|---:|---:|---:|---:|
| parser-02 | 3/3 | 3/3 | 160.2s -> 30.8s (-80.8%) | 9,823 -> 2,312 (-76.5%) |
| graph-08 | 3/3 | 3/3 | 78.8s -> 21.0s (-73.4%) | 6,909 -> 3,095 (-55.2%) |

Every final auto row routed direct/low, passed in one model call, and used no
repair or research. Two discarded tuning canaries were informative rather
than credited: a five-file graph crossed the initial four-file threshold and
paid for unnecessary research; after widening that count guard, a low-effort
plan hit a critic-only Forth error and the repair unnecessarily researched the
workspace again. The fixes keep small graphs direct under the byte cap and
reuse the bounded source pack for plan-only repairs.

One investigator-specific Rust `macros` probe used a deliberately broad scope
over a fresh 14-file exercise. OODA deep research passed the approved Cargo
contract on its first envelope (4 calls, 6 tools, 7,636 evidence bytes,
38,690 total tokens, 201.4s). Fixed-high passed after a second episode (2
calls, 18,523 tokens, 236.6s). Same-model OpenCode passed in 6 steps and 18
tools (71,418 processed tokens including 37,632 cache reads, 57.8s). Thus the
research loop is operational and improves first-shot convergence here, but it
is not a token-efficiency win over fixed-high and remains opt-in.

## Post-harvest measurement (not yet run)

The 2026-08-31 harvest is a correctness/accounting change, not a claimed
benchmark lift. The measured scope is deliberately limited to the
fail-closed dictionary organs that have evidence behind them: alias
quarantine (A), critic catalog checks (B), bounded INSTALL covering (C),
candidate-versus-promoted accounting (D), obligation holds (F), omission of
unsupported uniqueness axes (H), and the retrieve authorization fence (I).
Interned objects (E), waves (G), and retrieval as a load path are excluded
from any effectiveness claim.

Before collecting new scores, record per task `catalog_before`,
`eligible_words`, `used_words`, `candidate_words`, `promoted_words`,
`unused_eligible_words`, and `critic_covering_rejections`. Run three paired
parser-family replicates (cold versus a fresh warm family dictionary), then
one paired graph-family confirmation; keep transport failures separate from
task failures. A Polyglot-Rust confirmation is warranted only if those runs
show actual repeated word use.

Preregistered interpretation:

- A warm arm is a measured lift only if an actually used word accompanies
  correctness improvement and at least a 25% input-token reduction.
- Equal correctness with a reduction below 25% is safe reuse but a token
  amortization **NO-GO**; no observed word use means no demonstrated catalog
  effect.
- A regression while an eligible word is used is negative transfer; a
  regression without word use is a warm-arm/planner or transport confound.
- Covering rejections count as useful only when they are followed by later
  successful use; otherwise they are pressure without demonstrated benefit.
- First persistence is a candidate, not promotion; promotion without later
  use is not evidence of transfer.

No post-harvest scores are available yet, so this section intentionally makes
no effectiveness claim.

## Aider Polyglot (rust + go + cpp full tracks), 2026-08-27

Tasks from the published Aider Polyglot benchmark (Exercism exercises,
hidden judge = each exercise's full test suite, rust with
`--include-ignored`). Raw runs: `beam/runs/polyglot-3` (cold/warm full
tracks) and `beam/runs/polyglot-3-grok` (baseline on the first 10 per
language). Protocol differs from Aider's (episodes with gate feedback vs
2 attempts with test output) — reported alongside, not as leaderboard
equivalence.

Full tracks (95 exercises):

| arm | rust (30) | go (39) | cpp (26) | total | input tokens | calls |
|---|---|---|---|---|---|---|
| cold | 29 | 38 | 24 | **91/95 (95.8%)** | 440,407 | 127 |
| warm | **30** | 38 | 24 | **92/95 (96.8%)** | 404,153 | 116 |

Same-model baseline on the identical first-10 subsample per language
(30 exercises):

| arm | solved | input tokens | calls |
|---|---|---|---|
| grok ReAct CLI | 29/30 | 967,836 | 155 |
| cold | 29/30 | 128,219 | 39 |
| warm | 29/30 | 127,469 | 37 |

- **Same model, same exercises, identical correctness — ~7.6× fewer
  input tokens and 4× fewer calls** for plan-as-program vs the ReAct
  tool loop.
- Warm's rust track went 30/30, fixing the one exercise (`react`) cold
  missed, at 10.1% fewer tokens — positive on both axes, still a
  preregistered **NO-GO** (go: 6.8%, cpp: 4.0% reductions; the 25%
  amortization bar stays unmet when cold already averages ~1.4 calls
  per exercise). No negative transfer in any track.
- Rust crates for gigasecond/grep/simple-cipher were prefetched into the
  cargo cache; all three passed offline.

## Terminal-Bench v5: the effectiveness bundle, 2026-08-28

Same 15 tasks, same model, four fixes: (1) **advisory model-checks** —
the agent's self-drafted `check` claims now execute in-container as
backpressure (judge provenance stays `model-authored claims`; Harbor's
hidden verifier remains the only real judge); (2) binary READ-FILE
returns a summary instead of trapping; (3) the planner prompt asks for
`claims.json` with a behavioral check on episode 1 and mandates
relative paths; (4) real wall clock via `--agent-timeout-multiplier 2`.
Raw run: `bench/results/beam/beam-tb15-v5`, release `beam-v0.1.1`.

| campaign | mean reward | solved |
|---|---|---|
| v4 (blind) | 0.133 | 2/15 |
| **v5 (bundle)** | **0.533** | **8/15** — extract-elf, regex-log, db-wal-recovery, git-leak-recovery, git-multibranch, nginx-request-logging, openssl-selfsigned-cert, overfull-hbox |

**4× in one iteration**, zero errors, zero timeouts (both v4 timeout
casualties now solve). Receipt-level evidence of the mechanism:
git-multibranch's model-authored check (`advisory: true, returncode 0`)
drove self-judged convergence in 3 episodes; the hidden verifier
agreed. Executable backpressure was the missing organ, exactly as the
v4 autopsy predicted.

## Terminal-Bench 2.0 via Harbor (curated 15-task subset), 2026-08-27

First-ever completed Terminal-Bench campaign for this project (every
pre-BEAM attempt died on the adapter's exit-code bug). Agent = the
self-contained BEAM release (native shen-erl critic, `engine: beam` in
every container), 8-episode budget, 1h cap, judged by each task's hidden
verifier. Raw run: `bench/results/beam/beam-tb15-v4`.

| result | tasks |
|---|---|
| **solved (1.0)** | extract-elf, regex-log |
| failed (0.0) | fix-git, git-multibranch, git-leak-recovery, sanitize-git-repo, log-summary-date-ranges, openssl-selfsigned-cert, nginx-request-logging, filter-js-from-html, fix-code-vulnerability |
| timed out (1h) | db-wal-recovery, overfull-hbox, schemelike-metacircular-eval, sqlite-db-truncate (regex-log solved on retry after one timeout) |

Mean reward **0.133** (2/15). Telemetry: ~602k input / 30k output
tokens, 54 model calls across judged trials. Four trials self-judged
success on model-authored claims but only two survived the hidden
verifier — the judge-provenance gap the architecture is explicit about.
Levers for the next campaign: longer wall clock for build-heavy tasks,
approved-contract drafting from the task instruction, and the remaining
74 tasks of the registry.


Live runs on the vendored eval, three arms per task, hidden judges =
each task's actual protected verifier. Arms: `grok` (ReAct-style CLI
baseline, never told the contract exists, scored after exit), `cold`
(BEAM host, fresh dictionary per task), `warm` (BEAM host, family-shared
dictionary across the sequence). Planner for all ld runs: grok-4.6 —
same model as the baseline, only the control language differs.

## graph_coordination family (graph-01..08), 2026-08-26

Raw run: `beam/runs/demo-graph` (+ `demo-graph06-retry`: both ld arms'
original graph-06 failures were a single xAI transport timeout hitting
both arms in the same minute — retried post-fix, both pass in 1 call;
grok's graph-06 failure was genuine: max turns without discharging the
verifier).

| arm | solved | input tokens | output tokens | model calls |
|---|---|---|---|---|
| grok baseline | 7/8 | 299,424 (+579k cache reads) | 10,557 | 48 |
| cold | **8/8** | 15,770 | 2,686 | 9 |
| warm | **8/8** | 14,165 | 2,512 | 8 |

- Same model, same goals: the plan-as-program arms solved MORE tasks on
  **~19× fewer input tokens** and ~5× fewer calls than the ReAct
  baseline. One envelope per task (two on graph-08 cold) versus six
  tool-loop turns per task.
- Warm vs cold: 10.2% input-token reduction, driven by graph-08 where
  cold needed a second episode and warm's promoted words one-shot it.
  Preregistered verdict: **NO-GO** (threshold is >=25% reduction) —
  honest and expected: when cold already one-shots 7/8 tasks, there is
  almost nothing for a dictionary to amortize. The warm hypothesis
  needs task families hard enough to take cold multiple episodes.
- Zero policy violations on any arm; the ld arms' one attempted
  out-of-workspace read (episode feedback leak probe in an early pilot)
  was stopped by the capability fence pre-I/O.

## parser_repair family (parser-01..03), 2026-08-26

Raw run: `beam/runs/demo-parser`.

| arm | solved | input tokens | output tokens | model calls |
|---|---|---|---|---|
| grok baseline | 3/3 | 108,982 | 4,617 | 18 |
| cold | **3/3** | 4,366 | 1,731 | 3 |
| warm | 2/3* | 4,436 | 1,441 | 3 |

*warm parser-02 remains unresolved.* Its episode-2 repair planning ran past
the client's then-180s `receive_timeout` three attempts in a row, in two
separate runs (trivial episodes returned in seconds). The carried INSTALL
entry also makes negative transfer a live alternative, so the summary's
"negative transfer detected" flag cannot be dismissed as infrastructure
noise yet. Timeout was raised to 10 minutes (559c4ed); a clean post-harvest
warm parser-02 rerun is pending.

## config_migration family (config-01..05 partial), 2026-08-26

Partial (run stopped early). cold 4/4, warm 3/3, grok 5/5; same shape:
~1.6k tokens/1 call per ld task vs 6-22k/6 calls for grok.
