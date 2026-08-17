# Evaluation design

## Questions

The suite evaluates six separable hypotheses:

1. **Execution compression:** a complete executable plan reduces model calls,
   tokens, and repeated tools relative to stepwise ReAct.
2. **Representation:** Forth improves or preserves plan generation and
   execution relative to JSON and restricted Python.
3. **Preflight:** stack, effect, and contract checks prevent invalid or unsafe
   mutations before execution. In this repo that is either Python
   `livingdict.preflight` or shen-lua named `validate` on the OpenResty host;
   both implement the same Accept / Reject interface.
4. **Recovery:** structured traps and receipts reduce the cost of replanning and
   permit deterministic crash recovery.
5. **Procedural learning:** promoted words reduce cost on later family members.
6. **Graph scheduling:** explicit dependencies expose safe parallelism without
   increasing conflicting writes.

## Families

| Family | Main stressor |
|---|---|
| `config_migration` | repetitive mechanical workflow and precedence |
| `parser_repair` | edge cases, assumptions, and structured failure |
| `validation_ladder` | visible-test insufficiency and hidden invariants |
| `safety_boundary` | repository prompt injection and mutation authority |
| `graph_coordination` | independent nodes followed by a shared hotspot |

Sequence 1–3 are early/cold tasks, 4–7 are reuse opportunities, sequence 5
adds crash/resume, and sequence 8 is a false friend.

## Required controls

- Pin the exact model identifier and provider.
- Use the same model sampling configuration in every arm.
- Use the same task prompt and capability implementations.
- Apply equal wall-time, token, and model-call budgets.
- Run arms in randomized order.
- Use at least three repetitions per task for stochastic models.
- Report cold and warm runs separately.
- Keep protected verifiers and traces inaccessible to agents.
- Retain failed runs and partial receipts.

## Primary endpoint

Success rate under a fixed budget. Success requires protected behavioral checks,
change-policy compliance, and no timeout.

## Secondary endpoints

- input, output, and total tokens;
- model calls and tool calls;
- wall-clock time;
- policy violations;
- preflight rejection, trap, and replan counts;
- crash recovery rate;
- dictionary retrieval/reuse/promotion;
- false-friend negative transfer;
- graph concurrency and conflict rate when timestamped graph events exist.

## Suggested go/no-go rules

Before public benchmarks, require Forth+preflight to remain within five
percentage points of the strongest internal baseline while reducing median
model calls or total tokens by at least 25% on the first four families.

For the living dictionary, require a warm-run cost reduction with no more than
five points of correctness loss, no increased policy-violation rate, and no
material negative transfer on sequence-8 tasks.

These are suggested thresholds, not universal truths. Record chosen thresholds
in `docs/PREREGISTRATION_TEMPLATE.md` before running models.

## Analysis

`ldeval compare LEFT RIGHT` performs a paired task comparison and reports a
deterministic 2,000-sample bootstrap confidence interval for the success-rate
difference. With stochastic repetitions, aggregate each task/arm first or use a
mixed-effects analysis outside this lightweight tool.

