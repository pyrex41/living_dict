# Boris / Claude Code review (rubric, not impersonation)

Reviewer stance: apply the published Claude Code design theses (Latent Space 2025 with Cat Wu; “do the simple thing first”; later remarks on loops) to Living Dictionary as a coding harness. Not a product teardown of Grok or Pi. Not a request to become Claude Code.

Rubric used:

- A coding agent is a Unix utility, not a product. Composable, text I/O, terminal-native, raw model access.
- Do the simple thing first. Memory is a markdown file that gets auto-loaded. Summarization is “ask the model to summarize.” Features that survive get simpler, not richer.
- Build for where models will be in three months: more autonomous, better at composing tools, more thorough — not a nicer IDE for today’s model.
- The job is writing loops, not writing prompts. An unattended loop without a verifier ships bugs confidently.
- Project markdown (`CLAUDE.md`) is how corrections persist across sessions.
- Permissions: pre-allow the safe set; do not make the whole loop die on the first denied call; do not make “skip all permissions” the only mode.
- Non-interactive / headless is a first-class Unix mode, not a bolted-on chat export.
- Verify. Tests, not vibes. The loop is done when something measured is green.

Living Dictionary’s unique thesis, evaluated rather than discarded:

- The plan is a Forth program.
- Shen answers Accept | Reject before any mutation.
- The model is not in the loop while words run.
- Colon words persist in a dictionary (skills as code).
- Success is claim discharge (`RUN-GATES` / `claims.json`), not `RECEIPT` and not compile-green.
- The host owns `GOAL.md` + `PROGRESS.md` before the planner runs.

The question that actually matters: can “model out of the mutation loop” survive as a Unix utility, or does that idea only work if the host writes the outer loop (retry, repair, discharge) so the user never prompts the reject?

## Unix-utility test: is this composable or a chapel?

Claude Code’s shape is a process you can put in a pipe: cwd, prompt, tools, exit. Grok and Pi, in the 2026-08-15 compare, are that shape. `compare.py` invokes them as:

```text
grok -p <prompt> --cwd <arm> --output-format json --always-approve --max-turns N
pi -p --no-session --no-approve --no-context-files --mode json <prompt>
```

Living Dictionary is not that process. The live path is `POST /think` against OpenResty. The planner is `client/planner.py` spawned from Lua. The critic is shen-lua pinned in the worker. Continue policy exists three times (`client/continue_policy.py`, `openresty/lua/continue.lua`, `client/web/src/continue.js`). Forth exists twice (Python VM, Lua VM). The browser and the leftover `apps/studio` tree sit next to the harness. To write `fizzbuzz.py` you currently need nginx up, a Shen kernel, a planner credential, and a JSON envelope dialect.

That is a chapel. A chapel can contain a utility. This one does.

The composable kernel is real, and it is text:

| object | what it is |
|---|---|
| plan envelope | `{ language, program, artifacts, rationale }` on stdin / in a file |
| `GOAL.md` / `PROGRESS.md` | host-owned job stack, allocated before the model |
| `claims.json` | goal-shaped success measure |
| `.sb/discharge_report.json` | measured gates, not a vibe |
| `dictionary_dir/words/*.fs` | persisted colon words |
| `gates.py WORKSPACE` | a CLI measurer |
| `planner.py --stdin` | goal + observation → envelope |
| `livingdict-resty REQUEST.json` | envelope → critic → Forth, no HTTP |

`compare.py` is the most honest Unix object in the tree. Same prompt, isolated trees, hidden `--claims` as a shared judge. That is how you tell a harness from a chat UI around leftover product. The livingdict arm of that compare is not yet a peer of `grok -p`. It is an HTTP client of a chapel that happens to speak JSON.

Two Unix mistakes make the unique thesis look like ceremony:

1. **Reject is an HTTP 400.** Accept | Reject is a *value*. `agent.lua` raises `"preflight rejected program"` and `/think` maps that to status 400 / `ok: false`. In a pipe, 400 is transport failure. In Claude Code terms, it is “the denied call killed the process.” A utility would write a receipt `{ critic: "reject", errors: [...] }` and exit in a way the outer loop can consume.

2. **The write ABI is a puzzle the model must recite.** `WRITE-FILE` is `( content path -- )`. Content is not on the filesystem; it lives in `artifacts`. The only legal landing is `S" path" USE-ARTIFACT S" path" WRITE-FILE`. Architecture, README, eval envelopes, and `openresty/selftest.lua` all know this. The planner SYSTEM lists `USE-ARTIFACT` among host words and never states the stack effect. Tests already know the simpler word:

   ```forth
   : INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;
   S" hello.txt" INSTALL
   ```

   That word is folklore in the test suite. It is not seeded into a live dictionary. Compare starts with `cwd/.dictionary/words` empty.

HARNESS.md already records the previous chapel death: episode 1 did `READ-FILE` of `PROGRESS.md` before the host had written it, trapped, and the job ended before any product work. The fix was not a longer prompt. The host started allocating `GOAL.md` + `PROGRESS.md` first. That was the right Unix move: make the files exist, then let the program run. The 2026-08-15 fizzbuzz run is the same class of bug with a different word.

## The loop vs the prompt

Claude Code’s claim is that you do not win by writing a better SYSTEM. You win by writing a loop that keeps going until a verifier is green, with the model still present as the thing that proposes the next action.

Living Dictionary’s claim is sharper, and worth keeping: the model proposes a *program*, a non-LLM critic accepts or rejects that program, and then a VM mutates the tree with the model turned off. That is not ReAct. It is also not “one model call and halt.”

The live contract in HARNESS.md is already an outer loop:

```text
host allocates job files
    → planner emits Forth + artifacts
    → host appends RUN-GATES if missing
    → Shen Accept | Reject
    → Forth mutates
    → RUN-GATES measures
    → host appends PROGRESS.md
    → continue if claims not discharged
```

The diagram has no edge from Reject back to the planner. `continue_policy.should_continue` makes that absence law:

```python
if not body.get("ok"):
    return False
```

The same clause is in `continue.lua` and `continue.js`. `client/test_livingdict.py` freezes it: `should_continue({"ok": False, "plan": {"continue": True}}, 1, 5)` is false. So a critic reject is not backpressure. It is a terminal halt. The model is out of the mutation loop *and* out of the repair loop.

That is how the last live compare died. Same model (`grok-4.6`), same fizzbuzz prompt.

| arm | what the loop did | on disk | hidden claims |
|---|---|---|---|
| grok | 4 turns, `--always-approve`, ran `python3 -m unittest`, stop=`end_turn` | `fizzbuzz.py`, `test_fizzbuzz.py`, `README.md` | pass (4/4) |
| pi | 5 tool calls, `--no-approve`, unittest green | same three files | pass (4/4) |
| livingdict | 1 episode, Shen reject, `should_continue` → stop | `GOAL.md`, `PROGRESS.md` only | fail (missing product) |

The livingdict program was:

```forth
S" claims.json" WRITE-FILE
S" fizzbuzz.py" WRITE-FILE
S" test_fizzbuzz.py" WRITE-FILE
S" README.md" WRITE-FILE
RUN-GATES
RECEIPT
```

Rationale: “First increment: claims plus fizzbuzz sources, tests, and README.” The artifacts in the envelope were the product. The Forth omitted `USE-ARTIFACT`. Shen did its job: stack underflow at `WRITE-FILE`. Zero product files. `PROGRESS.md` recorded:

```text
## episode 1
First increment: claims plus fizzbuzz sources, tests, and README.
changed: none
```

No reject reason. `append_progress` only knows `receipt.changed_files` and `receipt.check`. A reject has neither. `next_episode_extra` would not have named the underflow either — it only says “write claims.json if missing, then RUN-GATES.” Even if someone flipped `should_continue` tomorrow, episode 2 would see an empty tree, an empty dictionary, no discharge report, and a progress note that says “changed: none.” It would emit the same program.

Two host behaviors make the asymmetry obvious:

- `job.ensure_run_gates` *does* rewrite the program when the model forgets verification. That is the host owning the loop’s stop condition.
- Nothing equivalent rewrites `S" path" WRITE-FILE` into `S" path" USE-ARTIFACT S" path" WRITE-FILE` when `path` is an artifact key. The host does not insert `USE-ARTIFACT`. It does not retry after reject.

So the unique thesis was over-read. “Model is not in the loop while words run” is a claim about the *inner* VM. It was implemented as “Reject means stop talking to the model.” Those are different claims. The outer episode loop already exists. It is used for failed *gates* (`should_continue` stays true when claims fail). It is forbidden for failed *plans*. A gate failure is treated as work. A stack error is treated as death.

Claude Code’s permission thesis maps onto this exactly. Pre-allow the safe set (live `/think` already sets `allowed_globs = **`, `allowed_effects = read/write/exec` — the critic on the live path is a stack checker, not a tight sandbox). Do not skip the critic; Living Dictionary is better than the compare’s grok/pi flags here (`--always-approve`, `--no-approve`). Do not make the first denied call kill the job. Living Dictionary does that, and the tests require it.

A longer SYSTEM will not fix this. The word `USE-ARTIFACT` is already in the word list. Grok, in the grok arm, did not need to be taught `cat`. It stayed in a bash loop until unittest was green. The livingdict arm asked the same model to compile a dialect, then treated a compile error as job completion. That is writing a prompt and skipping the loop.

## Verifier: what should "done" be?

The unique success measure is the right one. Keep it.

`gates.measure_claims` / `infer_gates` already distinguish layers. Structural gates (`sources` / `build` / `bundle`) are not success. Goal layer is `claims` (and `look` if it actually ran). `goal_discharged` requires a claims gate that passed. HARNESS.md: cap 32 is a halt, not success. COMPARE.md: a green `ok` means the process finished; discharge is hidden `--claims` or the last episode’s `RUN-GATES`. `continue_policy` refuses to stop on compile-green without claims. All of that is the verify-app thesis applied to arbitrary goals, not just “pytest exited 0.”

What “done” is *not*:

- `RECEIPT` written. The host will insert `RECEIPT` if missing. A receipt is a trace, not a verdict.
- HTTP 200 / `body.ok`. That means the *episode* ran. On 2026-08-15, livingdict `ok` was false and the job stopped; if the host had auto-inserted `USE-ARTIFACT` and gates had failed, `ok` would have been true and the loop would have continued. `ok` is the wrong bit.
- The model’s `continue` hint. Policy already overrides `continue: false` when writes landed and nothing was measured. Good. It should also ignore `continue` when the critic rejected.
- Structural green. Already encoded. Do not regress this when you fix reject-as-halt, or the studio leftover will look “done.”

What “done” should be, for an unattended Unix invocation:

1. Hidden or goal `claims.json` measured by `RUN-GATES` (and `look` if a viewable build exists).
2. If Python tests exist, `infer_gates` already adds a build/test measure. After fizzbuzz files land, that is the unittest. Grok and Pi ran it themselves; Living Dictionary should run it as a gate, not as a model-chosen shell command.
3. Cap reached ⇒ halt, exit non-zero, print the last discharge. Never report halt as success.

The 2026-08-15 judge used `compare/fixtures/fizzbuzz/claims.json` (`def fizzbuzz`, `FizzBuzz`, unittest file, README). Grok and Pi discharged it after the fact without writing `claims.json` themselves. That is the correct shared oracle. Living Dictionary also asks the planner to invent `claims.json` on episode 1. Fine as backpressure *inside* the livingdict loop. Do not confuse the agent’s claims with the hidden judge. On this run the agent *did* put `claims.json` in the envelope; it never reached disk, so the agent never measured anything, and the hidden judge scored the empty tree.

A verifier the model cannot reach is a trophy case. `RUN-GATES` is inserted by the host, then never executed, because Shen rejected first. The measure is correct. The path to the measure is not.

## What I would steal from Claude Code without becoming Claude Code

None of these require ReAct, bash-as-the-plan, or putting the model inside `WRITE-FILE`.

1. **Denied / rejected is an event in the loop, not the end of the process.** Feed critic errors into `PROGRESS.md` and into the next planner `extra`, the way discharge already feeds failed claims. The model is still not in the VM.

2. **Headless is the product.** A single argv, a cwd, a turn cap, a measured exit. `compare.py` should call that argv, not `POST /think`. nginx and the Svelte page become clients of the same binary Grok already is (`-p`). Today `client/livingdict.py -g` is a REPL that talks to a server.

3. **Do the simple thing first, as a host rewrite, not as another paragraph of SYSTEM.** You already rewrote “forgot `RUN-GATES`.” The sibling rewrite is “`WRITE-FILE` of an artifact key implies `USE-ARTIFACT`,” or seed `INSTALL` in every empty dictionary. The 2026-08-15 envelope already said what to write. Compiling that intent is IR lowering, not “the model is in the loop.”

4. **Persist corrections as markdown the next episode cannot avoid.** `PROGRESS.md` is supposed to be that file. It currently cannot record a reject. Claude Code’s `CLAUDE.md` is boring on purpose. A host line `critic: stack underflow at WRITE-FILE (need USE-ARTIFACT before each artifact write)` is worth more than the current SYSTEM essay.

5. **Do not die on the first permission failure; do not make skip-all the only mode.** Keep Shen always on. Change the continue tests that require reject ⇒ stop. Grok’s `--always-approve` is the mode the rubric warns against. Do not copy it. Copy the part where a denied tool does not exit the process.

6. **One continue policy.** Three copies of `should_continue` is the opposite of a Unix utility. One module, imported or generated once. The loop is the product; it should have one body.

Stealing “model stays in the mutation loop” would erase the thesis. Do not. Steal the *outer* loop discipline: unattended, measured, reject-tolerant.

## What I would keep that Claude Code does not have

These are the reasons not to become Claude Code.

1. **The plan is a program.** An envelope is inspectable, replayable, and diffable. Canned `config-01` through `livingdict-resty` plus a hidden verifier is a real lab result. Claude Code’s plan is a chat trace. You cannot replay a chat trace without the model.

2. **A non-LLM critic before mutation.** Shen does not write files, does not call a model, and does not execute the plan. That is a sharper permission story than a human clicking “allow” or a flag that allows everything. Stack contracts, globs, unknown words, missing artifacts — typed Reject. Keep it. Just stop treating Reject as process death.

3. **Model off during mutation.** Once the program is accepted, the tree changes because words ran, not because a later token decided to `rm`. That is the safety property. It survives as long as the *outer* loop can propose another program after Reject or after failed claims.

4. **Colon dictionary as executable skills.** `CLAUDE.md` is advice. `words/INSTALL.fs` is code the next episode actually runs. This is the better memory, *after* a word has been accepted once. It is unused on the live compare path because no episode has accepted a write program yet.

5. **Claim discharge as done.** Claude Code’s default “done” is “the model stopped, and maybe tests ran if it thought to.” Living Dictionary’s default is supposed to be measured claims. For goals that are not “make pytest green,” that is the more adult verifier. Keep structural green ≠ success. Keep the hidden compare judge.

6. **Host-owned job files.** HARNESS.md already absorbed the Ralph lesson: do not ask the model to create the stack the loop needs. `ensure_job_files` is the correct primitive. Extend that ownership to the write ABI and to reject records. Do not give it back to the SYSTEM prompt.

7. **Six host words, artifacts as full files.** Forth is control flow, not a payload language. That split is why JSON-plan / Python-plan arms can share envelopes later. It is also why `USE-ARTIFACT` exists. Keep the split; make the default write word hide it.

`USE-ARTIFACT` as a *required recitation* is not a unique thesis. It is an implementation detail of keeping Forth off the payload. The unique thesis is “the model emits a program, a critic gates it, a VM runs it, claims decide done.” The recitation can go away without the thesis going away.

## Verdict: 5 concrete design moves, ranked

“Model out of the mutation loop” survives as a Unix utility **if and only if the host writes the outer loop**. Retry, mechanical repair, and claim discharge have to happen without the user typing “please add USE-ARTIFACT.” If those stay in the prompt, or if Reject is terminal, the idea only works for canned envelopes. That is a laboratory, not a harness. The 2026-08-15 run is the existence proof of the second branch.

Ranked by leverage on that sentence. Not by how much they resemble Claude Code.

1. **Reject is backpressure. Stop encoding it as halt.**  
   Change the one continue policy so `ok: false` with critic errors schedules another episode until the cap. Write the errors into `PROGRESS.md` and into `next_episode_extra`. HTTP 200/400 stops being the job’s truth; it is only whether this episode accepted. Flip the tests that require reject ⇒ stop — they are locking in the chapel door. Without this edge, the HARNESS.md picture is a lie: “continue if claims not discharged” never sees a reject, because the job is already dead. This is the loop. It does not put the model inside Forth.

2. **Host-repair the write ABI next to `ensure_run_gates`.**  
   If the program says `S" path" WRITE-FILE` and `path` is a key in `artifacts`, insert `USE-ARTIFACT`. Or, simpler: seed `: INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;` into every empty dictionary and accept `S" path" INSTALL`. Do not add a paragraph to SYSTEM first. The 2026-08-15 envelope would have landed four files and `RUN-GATES` would have run, with zero extra model calls. That is “do the simple thing first.” Forgetting `USE-ARTIFACT` is the same class of harness bug HARNESS.md already claimed for missing `PROGRESS.md`. The host already decided verification is too important to leave to the model. Landing the artifacts the model already wrote is more important than verification, because verification without files is a fail you already know.

3. **`done` = `goal_discharged`, never `body.ok`, never `RECEIPT`, never structural green.**  
   Compare already scores hidden claims after each arm. Make the live loop stop on that same predicate. Cap ⇒ non-zero halt. A reject is not discharged. A compile-only `RUN-GATES` is not discharged. The planner’s `continue` hint is advisory after discharge, as it is today. Align `COMPARE.md`’s words with `should_continue`. Today they disagree on reject.

4. **One Unix CLI owns the loop. HTTP becomes a client.**  
   `livingdict -p GOAL --cwd DIR --max-turns N --claims FILE` should: allocate job files, plan, critic, repair, Forth, measure, continue, print a receipt, exit 0 iff claims discharged. `compare.py` calls that binary the way it calls `grok -p`. Collapse `continue_policy.py` / `continue.lua` / `continue.js`. Keep OpenResty and the browser if you want a chapel *on top*. The harness is the CLI. Until that exists, “non-interactive is first-class” is a compare script wrapped around a 400.

5. **Seed one write skill; persist critic failures as job markdown.**  
   Colon words only save after Accept (`dictionary.save_colon`). That is why `INSTALL` never appears in a cold compare dictionary. Seed it. And write a host-owned `PROGRESS.md` (or a small `HARNESS.md` in the job) that records critic errors the way `CLAUDE.md` records corrections. Skills-as-code and markdown-as-memory are complementary: code is what to run; markdown is what not to emit again. Right now you have neither on the path that failed.

Do not do, if the goal is to stay a distinct harness:

- Put the model inside `WRITE-FILE` / `RUN-GATES`. That is becoming Claude Code.
- Fix this by growing SYSTEM. The word list already names `USE-ARTIFACT`. The last failure was a missing loop, not a missing noun.
- Drop Shen to match grok’s `--always-approve`. The critic is the unique permission story. Make it non-fatal instead.
- Build more product (another browser body, another VM, promotion graphs) before this loop writes three files unattended. Features here have been getting richer. The live harness has not been getting simpler. The rubric says the opposite direction.

If moves 1–3 ship, “model out of the mutation loop” is a Unix utility with a typed critic and a measured stop. If they do not, it is a one-shot Forth compiler that the user debugs by hand, and Grok/Pi will keep winning the same prompt with the same model.
