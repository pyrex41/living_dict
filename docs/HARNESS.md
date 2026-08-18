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

To score this loop against grok headless and pi headless on the same
prompt, see [`COMPARE.md`](COMPARE.md).

## What “works” means

You can type any goal. The first episode does not reject itself.
Later episodes see the product tree plus last discharge. The work pane
shows diffs and a live product *if this job built one*. You only
speak again to change the goal or stop.
