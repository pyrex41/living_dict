# Arms race results

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
