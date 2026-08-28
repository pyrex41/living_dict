# Arms race results

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

*warm parser-02 is an infrastructure casualty, not a dictionary
failure: its episode-2 repair planning legitimately reasoned past the
client's then-180s receive_timeout, three attempts in a row, in two
separate runs (trivial episodes returned in seconds). The summary's
"negative transfer detected" flag is noise from that. Timeout raised
to 10 minutes (559c4ed); a clean warm parser-02 rerun is pending.

## config_migration family (config-01..05 partial), 2026-08-26

Partial (run stopped early). cold 4/4, warm 3/3, grok 5/5; same shape:
~1.6k tokens/1 call per ld task vs 6-22k/6 calls for grok.
