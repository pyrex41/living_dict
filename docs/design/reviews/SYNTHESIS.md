# Consensus: how to design this harness

Three rubric reviews of the same tree and the same fizzbuzz compare
(`20260815T191456Z`). Full texts: [linus.md](linus.md), [boris.md](boris.md),
[mario.md](mario.md). This file is the overlap, not a fourth personality.

## The unique idea that survived all three

The plan is a program. A non-LLM critic Accepts or Rejects it. The model is
off while words mutate the tree. Skills persist as colon files. Done is
claim discharge, not a receipt and not compile-green.

None of the three said “become grok / pi / Claude Code.” All three said the
fizzbuzz run proved the *inner* idea (envelope + critic) and disproved the
*outer* loop (reject = job death, write = a zipper the model must recite).

## Five moves they independently ranked first

| rank | move | who |
|---|---|---|
| 1 | **Artifacts are the write.** Host applies `envelope.artifacts` (or one kernel `INSTALL`). Delete the model-facing `USE-ARTIFACT` + `WRITE-FILE` dance. | all three, all as move 1 or 2 |
| 2 | **Reject is backpressure, not halt.** Feed critic errors into the next episode. Cap still stops. Policy still refuses illegal mutations. | all three |
| 3 | **Host owns done.** Loop until `goal_discharged` or cap. Delete model `continue`. Host-owned claims (compare already does this). | all three |
| 4 | **Job state leaves the product tree.** Goal / progress / last reject live in `run_dir`. Product tree is the snapshot. Stop prompt rules that say “do not READ-FILE GOAL.md.” | Linus, Mario; Boris: persist rejects as job markdown |
| 5 | **One loop body, tiny ABI.** Freeze eval 1.0 six words. One continue policy. Live measurement is host `RUN-GATES`. | Linus freeze; Boris one CLI; Mario one critic |

Do not fix this by adding “always emit USE-ARTIFACT” to `SYSTEM`. All three
called that a special case taped over a bad representation. The host already
rewrites forgotten `RUN-GATES`. Landing files the model already wrote is the
same class of host job.

## What to keep that Claude Code and pi do not have

- Envelope as a replayable program (not a chat trace).
- Shen (or one preflight) on globs, effects, unknown words — not on stack
  sugar the model was never trained to emit.
- Model off during mutation.
- Dictionary as *executable* skills, after a word has been accepted. Seed
  the write sugar if it still exists. Do not dump 20k of `*.fs` into context.
- Hidden / host claims as the judge. Structural green is not success.

## Disagreements (real, leave open)

- **Forth as the model-facing language.** Mario: compile `{ artifacts }` to
  Forth on the host; Forth is IR. Linus: keep Forth, but make the fizzbuzz
  program legal without a zipper. Boris: keep the program; lower writes as
  IR. Consensus: the model must not have to recite `USE-ARTIFACT`.
- **How many critics.** Mario: one preflight until the live loop lands
  files; extra Shen bodies did not pay rent on fizzbuzz. Linus: critic must
  *see* colon bodies. Boris: keep Shen, make Reject non-fatal. Consensus:
  do not drop the critic to match `--always-approve`.
- **Headless shape.** Boris wants `livingdict -p --cwd` as the product and
  HTTP as a client. The others imply it (compare should call a peer of
  `grok -p`) but do not rank a CLI rewrite as high as the write/loop fix.

## What “works” means after this

Same prompt as grok/pi. Isolated workspace. Model emits artifacts + optional
Forth. Host installs the files. Critic still blocks path/effect crimes.
Reject retries until cap. `RUN-GATES` always runs. Stop when claims pass.
The 2026-08-15 envelope would have become three files and a green judge
with **zero extra model calls**.
