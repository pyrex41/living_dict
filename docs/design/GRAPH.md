# Graph engineering through the Forth loop

Anthropic’s name for this (2025–2026, “Building effective agents” plus
Claude Code orchestrator-workers) is **graph engineering**: nodes do
work, edges are dependencies or handoffs, shared state is the repo, a
verifier sits on the merge. Loop engineering is one agent until a check
is green. Graph engineering is several such loops wired together.

`pyrex41/scud` was an early attempt at that wiring. Living Dictionary’s
bet is the same graph, with a different runtime: **the Forth program is
the graph**, not a DAG of ReAct agents.

## What Anthropic actually shipped

Not a new framework. Five composable patterns, later run as Claude Code
subagents:

| pattern | graph reading |
|---|---|
| prompt chaining | a line of nodes |
| routing | a conditional edge |
| parallelization | a fan-out / fan-in |
| orchestrator-workers | a hub that writes the graph and runs the workers |
| evaluator-optimizer | a verify node that can send work back |

Claude Code’s “dynamic workflow” is the lead agent writing a *program*
that spawns subagents. The program is usually JavaScript. Each node is
still a model in a tool loop.

## What SCUD actually built

Local tree: `/Users/reuben/projects/scud`. Public face:
[github.com/pyrex41/scud](https://github.com/pyrex41/scud). Spec: `go.md`.

SCUD **externalized** the graph as data, then ran a coding agent on each
node:

```
PRD → parse/expand → tasks.scg (DAG)
                    → wave planner (Kahn)
                    → swarm: one Rho agent per ready task
                    → wave-boundary backpressure (cargo test / npm test)
                    → git-blame attribution + repair agents
```

What worked (keep these laws):

1. **Host owns the graph before any model runs.** `tasks.scg` exists the
   way `GOAL.md` must exist. The agent does not create the stack it
   needs.
2. **Ready means every dependency is done.** Waves are dependency
   layers, not “the model felt like doing three things.”
3. **Backpressure sits on the wave, not inside the worker.** Rho runs to
   completion; `cargo test` happens after the dust settles. That is the
   same sentence as “model off while words run,” then `RUN-GATES`.
4. **A failed check is repair, not halt.** Up to N repair agents, then
   mark Failed and continue the rest of the DAG.
5. **Agent type ⊥ model tier.** What the node *does* is not how smart
   the model is.

What did not work as the *Forth* idea:

- Every node is still a Rho/Claude tool loop. You paid graph-of-agents
  cost (context per worker, 16-agent `heavy`, attractor DOT, MCP, a
  transcript DB).
- The graph is a sidecar the model does not execute. Forth never ran.
- Attractor (`pkg/attractor`) is a second graph language (DOT +
  handlers) beside the task DAG. Two graphs, still ReAct in the
  `codergen` handler.
- Eval in this repo already knew the cheaper graph: `task_graph.json`
  plus `graph.node.start` / `graph.node.finish` events. Those words
  were listed under “What stays out.”

SCUD is a good **scheduler**. It is not a plan language.

## The Forth loop as the same graph

| graph engineering | SCUD | Living Dictionary |
|---|---|---|
| node | task + Rho agent | artifact write, or a colon word |
| edge | `@edges` / `depends_on` | Forth sequence, `IF`, later a wave over write-sets |
| orchestrator | `scud swarm` | planner emits one envelope, then is off |
| worker | model in a tool loop | host word / VM, no model |
| shared state | git working tree | workspace snapshot |
| verify node | wave-level `cargo test` | `RUN-GATES` / claims |
| reusable subgraph | copy a task template | `dictionary_dir/words/*.fs` |
| repair | spawn another Rho | next episode, reject is backpressure |
| inspect | `scud.db` transcripts | envelope + JSONL + receipt |

The novel compression: **Anthropic’s lead agent writes a program that
spawns models. This lead agent writes a program that does not spawn
models.** Execution compression (eval hypothesis 1) and graph
scheduling (hypothesis 6) are the same object if the program *is* the
graph.

Colon words are the only unique node type SCUD does not have. A
promoted word is a verified subgraph you run without another model
call. That is why the dictionary is not `CLAUDE.md`.

## How we get there (do not rebuild SCUD)

Do not import `tasks.scg`, attractor DOT, `scud heavy`, or Rho. Those
are the early attempt’s *weight*. Steal the laws, implement them as
Forth + host.

**Step 0 — the program can land files.** Already required by the
persona reviews. Artifacts *are* the write set. `USE-ARTIFACT` is IR.
Reject is backpressure. Until fizzbuzz lands, there is no graph, only
a critic.

**Step 1 — the envelope is a sequential graph.** Each artifact key is
a node. The host applies them (Kahn width 1, or in parallel when
write-sets are disjoint). Emit `graph.node.start` / `graph.node.finish`
on every write. `RUN-GATES` is the verify node after the wave.

**Step 2 — reuse is a named subgraph.** Colon words that survive
Accept persist. The next episode calls `NORMALIZE-CONFIG`, not
“spawn a builder agent.” Critic walks colon bodies. Cold start seeds
only host prelude, not a warm session’s folklore.

**Step 3 — eval `graph_coordination` becomes live.** `task_graph.json`
is the SCUD DAG in miniature (independent modules, then a shared
hotspot). The host may run disjoint write-sets in one wave. Registry
waits. Verify last. Parallelism is a scheduler fact, not a new Forth
dialect. Do not add `PAR` / `FORK` until a compare shows sequential
artifact apply losing to grok/pi on `graph-01`.

**Step 4 — wave-boundary backpressure.** After a wave, `RUN-GATES`.
Failed claims schedule a repair episode with the discharge report,
the way SCUD injects `cargo test` stderr into a repair agent. Cap is
a halt. The model never sits inside the verify node.

Stop condition for this whole path: same prompt as grok/pi/scud-swarm
on a `graph-0x` style goal, hidden claims pass, and livingdict emits
`graph.node.*` with no conflicting writes on the hotspot.

## What “works” means

SCUD works today as: *parse a PRD, don’t run dependents early, test
after a wave, repair instead of dying.*

Living Dictionary works when: *the model writes the graph once, the
host executes it, Shen only rejects policy, the dictionary keeps
subgraphs, claims discharge the job.*

The 2026-08-15 fizzbuzz run failed before step 0. That is why this
file is a map, not a new word list.
