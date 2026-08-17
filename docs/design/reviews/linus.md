# Linus review (rubric, not impersonation)

Rubric, applied to this repo as a coding harness (not a chat UI, not a Forth
hobby): good taste is a representation that deletes special cases; published
ABI does not silently grow; talk is cheap, show the data; data structures
first; model the snapshot, not the deltas; two implementations of a tiny ABI
is fine; a special case in the prompt is a bug in the host.

This is not a personality piece. It is a design review of Living Dictionary
against that rubric, using the live three-way on the same grok-4.6 fizzbuzz
prompt.

## What is actually unique (keep / kill)

The unique claim is real, and it is small.

Keep:

- **The plan is a program.** The model emits a Forth episode. The model is
  not in the loop while words run. Grok headless and pi headless keep the
  model in a tool loop (`client/compare.py` `run_grok` / `run_pi`). That is
  the whole difference worth having.
- **Shen Accept | Reject before I/O.** `openresty/lua/agent.lua` `run_forth`
  calls `bridge.validate` and only then `vm:interpret`. Shen does not write
  files, does not call an LLM, and does not execute the plan. That is a
  critic, not a second agent.
- **The envelope is the interesting object.** `{ language, program, artifacts,
  rationale }`. Patches are files. Forth is control flow. That split is
  correct. `docs/ARCHITECTURE.md` already says it: Forth is not a payload
  language.
- **The workspace after the episode is the product.** Receipts, traces, and
  the colon dictionary belong outside the product tree. `RUN-GATES` plus
  goal `claims` is the success measure. Structural green is not success.
  Cap is a halt. Those sentences in `docs/HARNESS.md` are the right
  contract.
- **Colon words persist as files.** `dictionary_dir/words/*.fs` is a
  snapshot of skills, not a chat memory. Two bodies (Python
  `harness/`, OpenResty `openresty/`) of one tiny ABI is fine. A browser
  body of the *same* ABI is fine. Eval (`eval/`) is the laboratory, not a
  third language.

Kill:

- **`USE-ARTIFACT` as a user-facing zipper.** The envelope already has the
  file bytes. The program then has to remember
  `S" path" USE-ARTIFACT S" path" WRITE-FILE`. That is two representations
  of one write. The critic punishes the model for using only one of them.
- **Job theater in the product tree.** `GOAL.md` / `PROGRESS.md` allocated
  into the workspace, then a system-prompt rule “do not `READ-FILE` them.”
  Progress files the model must remember not to touch are not a snapshot.
  They are a trap with a comment taped to it.
- **The model `continue` flag, and the policy that interprets it.**
  `client/continue_policy.py`, `openresty/lua/continue.lua`, and
  `client/web/src/continue.js` are the same thicket copied three times.
  Success is claims discharge. Everything else in that function is an `if`
  that exists because the host does not own the loop.
- **`eval/ldeval/forthcheck.py` and `eval/examples/forth-plan.fs`.**
  `TASK OBSERVE PROPOSE-PATCH CHECK-PATCH APPLY-PATCH REQUIRE-PASS` is the
  “Forth is a tool language that can emit any product” story. It is not
  the live ABI. It is not the eval adapter ABI. Delete it from the mental
  model. Do not grow words toward it.
- **Growing the live word set to paper over traps.** `docs/HARNESS.md`
  rule 7 already wants `READ-FILE?` and `RUN-CMD`. That is how a six-word
  eval ABI becomes a shell. Eval protocol 1.0 (`eval/docs/ADAPTER_PROTOCOL.md`)
  is published. Keep it.

Versus grok headless and pi headless, on
`compare/runs/20260815T191456Z/`:

| arm | ms | what landed | hidden claims |
|---|---|---|---|
| grok | 18742 | `fizzbuzz.py` `test_fizzbuzz.py` `README.md` | pass (5/5 unittest in the grok log) |
| pi | 12436 | same three files | pass |
| livingdict | 9372 | `GOAL.md` `PROGRESS.md` | fail; product never touched disk |

Living Dictionary was *faster than both* and the planner *already had the
product*. The unique machinery then refused to apply it.

## Special cases that prove the representation is wrong

Show the data. Episode 1 of the fizzbuzz compare
(`compare/runs/20260815T191456Z/livingdict/_episodes.json`):

```
program:
  S" claims.json" WRITE-FILE
  S" fizzbuzz.py" WRITE-FILE
  S" test_fizzbuzz.py" WRITE-FILE
  S" README.md" WRITE-FILE
  RUN-GATES
  RECEIPT
error: preflight rejected program
```

`compare/runs/20260815T191456Z/summary.md`:

```
livingdict | False | 9372 | GOAL.md, PROGRESS.md | fail
  preflight rejected: stack underflow at WRITE-FILE (forgot USE-ARTIFACT)
```

The same episode’s envelope (also left in
`openresty/var/run/think/dictionary/envelope.json` because
`request_from_env` writes the host run dir even when compare passes a
private `.dictionary`) contains complete, correct artifacts:
`claims.json`, `fizzbuzz.py`, `test_fizzbuzz.py`, `README.md`. The
`fizzbuzz.py` text matches what grok wrote to disk. Shen rejected
`stack underflow at WRITE-FILE`. `continue_policy.should_continue`
returns false when `ok` is false
(`client/test_livingdict.py` asserts that). The loop stopped. The
workspace is a seed `README.md` plus host-owned job files.

That is not a model failure. It is a linked-list-delete moment.

`WRITE-FILE` is specified `( content path -- receipt )`
(`openresty/shen/contracts.shen`, `harness/src/livingdict/forth.py`
`_write_file`). Content does not live on the Forth stack. It lives in
`envelope.artifacts`. The zipper word is `USE-ARTIFACT`. The natural
program for “here are four files, write them” is exactly what the model
emitted. The representation makes that program illegal.

The repo already found the better word and then hid it:

```
: INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;
```

That definition is in `openresty/selftest.lua`, persisted as
`openresty/var/run/think/dictionary/words/INSTALL.fs`, reused in
`harness/tests/test_dictionary.py`, and assumed by continue-policy tests
(`S" src/App.jsx" INSTALL`). It is **not** a kernel word. It is **not**
in the planner `SYSTEM` host-word list (`client/planner.py`). Compare
creates an empty `livingdict/.dictionary/words/`. So the one word that
makes `S" fizzbuzz.py" …` a write is absent on the path that is supposed
to prove the harness.

Special cases piled on top of that wrong write representation:

1. **“Do not `READ-FILE` `GOAL.md` / `PROGRESS.md`.”**
   `docs/HARNESS.md` records the previous self-kill:

   ```
   S" GOAL.md" READ-FILE DROP
   S" PROGRESS.md" READ-FILE DROP
   RUN-GATES
   RECEIPT
   ```

   `READ-FILE` traps on a missing file. `PROGRESS.md` was written after
   the episode. The prompt said to read it every episode. Episode 1
   died before any product work. The fix was: host allocates the files
   first (`client/job.py` `ensure_job_files`, Lua `persist_job`), *and*
   a prompt rule forbidding `READ-FILE` of those paths. The host now
   makes the files exist. The prompt still has to say “do not read
   them.” Observation already dumps them. The trap remains for any
   other missing path the prompt might invent. A special case in the
   system prompt is a state the host still allows.

2. **Host string-rewrites the program.** `ensure_run_gates` inserts
   `RUN-GATES` if the model forgot. That is an `if` on token text
   because the loop does not own measurement. If every live episode
   measures, the word is not part of the plan. It is part of the host.

3. **`claims.json` is a product file the model must Forth-write.**
   Planner `SYSTEM` says: first episode, write `claims.json`, each
   feature claim must name a source path that is not `index.html`, a
   title tag is not a product, never weaken claims. That is five
   prompt `if`s around a success predicate that should be a field on
   the envelope. Compare already treats hidden `--claims` as
   host-owned (`measure_hidden_claims`). Live pretends the model
   invents the judge *through the same zipper that just rejected
   fizzbuzz*.

4. **`infer_gates` is a layout detector.**
   `harness/src/livingdict/gates.py`: if `tests/test_*.py` exists,
   return only a `test`/`build` gate and **drop claims**; if
   `package.json` exists, assume a Solid/vite studio (`sources` wants
   `index.html` + `src/*.{js,jsx,ts,tsx}`, `bundle` wants
   `dist/index.html`, `look` serves it); else claims only. Fizzbuzz
   survived this only because `test_fizzbuzz.py` is at repo root, so
   `python_test_files` (which looks only under `tests/`) misses it.
   A Python package that follows eval’s own `tests/` layout would
   discharge no claims, and `goal_discharged` would stay false until
   the cap. The studio leftover is still steering the general
   harness.

5. **Colon words are invisible to the critic.**
   `preflight.py` / `forth.lua` `validate` / Shen `bind-word` all do
   `Contract(0, 0)` and skip the body. `INSTALL` in a prelude does not
   consume a path as far as Shen can see. The critic that exists to
   make stack errors unexecutable cannot see the one word that would
   have made this episode legal.

6. **`continue_policy` is the special-case museum.**
   Tests encode the history: “studio App.jsx only must not stop,”
   “structural pass is not done,” “`continue=false` but wrote files →
   keep going,” “`ok=false` → halt.” The last rule is why a zipper
   reject ends the job while grok and pi retry inside their own
   loops. Reject is treated like a fatal ABI break. It is a
   well-typed “this program is not a write.”

7. **Unicode goals crashed `ensure_job_files`.** Lua `decode_json`
   treated `\uXXXX` as `byte % 256`. JSON is not Latin-1. That is the
   same class of bug: the data structure (a Unicode goal string) was
   not the representation the host used. There is now a selftest for
   `\u2192`. The fizzbuzz prompt contains `→`. The decoder had to
   become a real decoder before the host could even allocate
   `GOAL.md`.

8. **Dual writers, leaked sidecars.** Python `ensure_job_files` and
   Lua `persist_job` both write the same two files. `persist_job` is
   declared in the middle of `M.dispatch` after several early
   returns. `request_from_env(envelope)` writes
   `var/run/think/dictionary/envelope.json` even when the client sent
   an isolated dictionary. Compare is not isolated at the host.

None of these is fixed by another sentence in `SYSTEM`. Each one exists
because a piece of state is in the wrong object.

## The ABI I would freeze

Freeze the objects. Do not freeze the zipper dance.

**Eval protocol 1.0 stays 1.0.** Request, trace events, receipt,
`allowed_effects` / `allowed_globs` / `forbidden_globs`, crash/resume
via `checkpoint.json`, idempotent identical `WRITE-FILE`. Words the
eval envelopes already use:

| word | stack | meaning |
|---|---|---|
| `READ-FILE` | `( path -- text )` | missing file is a typed trap |
| `LIST-DIR` | `( path -- listing )` | |
| `SEARCH` | `( query -- hits )` | |
| `WRITE-FILE` | `( content path -- receipt )` | eval keeps 2-arity; canned envelopes keep working |
| `RUN-TESTS` | `( -- test-receipt )` | eval measurer |
| `RECEIPT` | `( -- receipt )` | |

`USE-ARTIFACT` stays an *implementation* of “content lives in the
envelope,” not a capability and not something a live planner must
say. Do not add `READ-FILE?`, `RUN-CMD`, `TASK`, `OBSERVE`,
`PROPOSE-PATCH`. `RUN-GATES` is the live measurer; it is an alias of
“host runs `gates.py` and writes `.sb/discharge_report.json`,” not a
reason to edit eval oracles.

**Live envelope (the object the planner actually emits):**

```json
{
  "language": "forth",
  "program": "RUN-GATES RECEIPT",
  "artifacts": { "fizzbuzz.py": "…", "test_fizzbuzz.py": "…", "README.md": "…" },
  "claims": [
    {"id": "fn", "kind": "source", "path": "fizzbuzz.py", "any": ["def fizzbuzz"]}
  ],
  "rationale": "never executed"
}
```

Rules that make the fizzbuzz program legal without prompt text:

- `artifacts` *is* the write set. After Shen accepts, the host applies
  every key through the same policy `WRITE-FILE` uses (`write-ok?`,
  workspace confinement, idempotent identical bytes). The critic
  already receives `artifact_keys`; it must reject a key outside
  globs *whether or not* the program mentions it.
- A live program that says `S" fizzbuzz.py" WRITE-FILE` is normalized
  by the host *before* Shen sees it, using the artifact map. The
  zipper is not a planner skill. It is not a warm-dictionary skill.
  It is not in the system prompt.
- If a kernel sugar word exists, it is `INSTALL` with a real contract
  `( path -- receipt )`, in `HOST_DICTIONARY`, not in
  `words/INSTALL.fs`. Compare’s empty dictionary then still works.
- `claims` is a field (or a host sidecar). The host writes the
  discharge input. The model does not have to `WRITE-FILE` the judge.
- Job state (`GOAL`, `PROGRESS`, last reject, last discharge) lives
  in `run_dir`, next to traces and receipts. The product tree
  contains product. Observation is a host dump of the product
  snapshot plus that sidecar. `READ-FILE GOAL.md` is unrepresentable
  because the file is not in the workspace.
- Colon words keep real stack contracts, or the critic walks their
  bodies. `bind-word` → `[Name 0 0 []]` is how a critic goes blind.

Two implementations of that ABI remain correct. A third body
(browser) is correct only if it does not add words. Promotion
evidence gates can wait; persisting every colon snapshot is closer
to git than a graph of unearned skills, and it is not the bug that
lost fizzbuzz.

## The loop I would allow

One loop. No `continue` hint. No “one increment” versus “sprint”
policy.

```
host opens run_dir (goal text, empty progress, no product files)
for episode in 1..cap:
    observe: product snapshot + last discharge + last reject + dictionary
    planner emits envelope (artifacts + optional Forth + claims)
    host normalizes (apply-artifacts is implicit; zipper not required)
    Shen: Accept | Reject
    if Reject:
        record errors in run_dir          # backpressure, not a halt
        continue
    host materializes artifacts           # snapshot gets the files
    Forth runs remaining words            # reads, extra writes, RUN-GATES
    host writes discharge + progress sidecar
    if claims discharged: stop            # success
stop                                      # cap is a halt, not success
```

The model is not in the loop while words run. That sentence stays.
What changes: a reject is an episode result, the same way a failed
`RUN-GATES` is. Grok and pi do not exit their process because one
tool call was malformed. This harness should not either — and if the
write representation is right, the fizzbuzz reject cannot happen.

`RUN-GATES` is host-owned at the end of every accepted episode. The
planner does not have to remember it. `ensure_run_gates` goes away.

Leftover product from another job is just files in *that* workspace.
Compare already isolates trees. The default `/think` workspace
(`apps/studio`) plus `var/run/think/checkpoint.json` still contains
an old ocean/beach plan that `READ-FILE`s `GOAL.md` and declares the
job done. That checkpoint is why leftover product keeps leaking into
the live host. Isolation is a property of the workspace object, not
a prompt line about “do not assume a stack (Python, Solid, Three).”

## Verdict: 5 concrete design moves, ranked

1. **Make `artifacts` the write.** Host applies the map after policy
   check. Normalize or delete the user-facing `USE-ARTIFACT` zipper.
   Put `INSTALL` in the kernel if you still want a one-token write;
   do not leave it in a warm dictionary that compare deliberately
   empties. This is the fizzbuzz fix. It is also the linked-list
   lesson. Do not add “always emit `USE-ARTIFACT`” to
   `client/planner.py` `SYSTEM`.

2. **Move claims and job state off the Forth trap surface.** Claims
   on the envelope (or a host sidecar). Goal/progress/reject in
   `run_dir`. Product tree is the snapshot. Then delete the prompt
   rules “do not `READ-FILE` `GOAL.md`,” “first write `claims.json`,”
   “not `index.html`,” and delete `ensure_job_files` /
   `persist_job` writing into the workspace. The earlier
   `PROGRESS.md` reject and the unicode `ensure_job_files` crash
   were the same bug: job state was a product file.

3. **Replace `continue_policy` with discharge-or-cap.** One
   implementation, in the host, not three (Python / Lua / JS).
   Reject feeds the next observation. `ok=false` is not a job kill.
   Delete the model `continue` field. The studio “wrote App.jsx and
   set continue=false” test is evidence the flag is a bug.

4. **Freeze eval 1.0 and stop growing words.** Keep 2-arity
   `WRITE-FILE` for existing envelopes. Keep `RUN-TESTS` as the eval
   name. Live measurement is `RUN-GATES` on the host side. Do not
   add `READ-FILE?` or `RUN-CMD`. Delete or quarantine
   `eval/ldeval/forthcheck.py`’s `TASK`/`PROPOSE-PATCH` dictionary
   so it cannot be mistaken for the ABI. Two (or three) bodies, one
   tiny word set. Forth does not need to become a shell to write
   fizzbuzz.

5. **Make the critic see the program that will run.** Walk colon
   bodies or give kernel words real contracts. Infer gates from
   `claims` plus an explicit manifest, not from “has `package.json`
   so this must be the ocean studio” / “has `tests/` so drop
   claims.” `measure_sources` requiring `index.html` is leftover
   product steering a general harness. The snapshot after a Python
   episode should not be judged as a vite app.

Until (1) lands, this is not a coding harness in the grok/pi sense.
It is a critic that can reject a complete product because the
control language and the file map were not zipped. The 2026-08-15
compare is the receipt: 9 seconds, artifacts in the envelope, Shen
right about the stack, workspace empty of product. Taste is changing
the write so that stack error cannot be expressed. Everything else
on this list is the same move applied to claims, job files, and the
loop.
