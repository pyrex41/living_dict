# Mario / pi review (rubric, not impersonation)

This is a design review of Living Dictionary as a coding harness, scored against the published theses in [What I learned building an opinionated and minimal coding agent](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/) and the shape pi actually ships. It is not an instruction to become pi. The question is whether the unique pieces — Forth as the plan, Shen as the critic, a persistent dictionary, claims/backpressure — earn their complexity against a four-tool loop the model is already RL-trained to run.

Rubric, applied as written:

- If I don't need it, it won't be built.
- Four tools are enough: read, write, edit, bash. Extra tools are usually context pollution.
- Tiny system prompt. Context engineering is paramount. Do not inject stuff behind the user's back that isn't surfaced.
- Inspectability: documented session format, every event visible, alternative UIs on a small core.
- YOLO by default on a local machine. Project trust is about loading project-local extensions, not sandboxing the model.
- No list that paid rent: no built-in todos, no plan mode, no MCP, no background bash, no sub-agents.
- Models are RL-trained to use bash/read/write/edit. Fighting that with a custom plan language has a tax. Name the tax and say when it is worth paying.
- Extensions exist so the core stays small.

Evidence from this repo, not from a vibe. Same model (grok-4.6), same fizzbuzz prompt, run `compare/runs/20260815T191456Z`:

| arm | wall | product on disk | hidden claims |
|---|---|---|---|
| pi | 12.4s, 5 tool calls | `fizzbuzz.py`, `test_fizzbuzz.py`, `README.md` | pass |
| grok | 18.7s | same three files | pass |
| livingdict | 9.4s, 1 episode | `GOAL.md`, `PROGRESS.md` only | fail: missing `fizzbuzz.py` |

The model wrote the right files. They are in `openresty/var/run/think/dictionary/envelope.json` as artifacts (`fizzbuzz.py`, `test_fizzbuzz.py`, `README.md`, `claims.json`). The Forth it emitted was:

```
S" claims.json" WRITE-FILE
S" fizzbuzz.py" WRITE-FILE
S" test_fizzbuzz.py" WRITE-FILE
S" README.md" WRITE-FILE
RUN-GATES
RECEIPT
```

That is the write the model is trained to do. `WRITE-FILE` is contracted as arity 2 (`content`, `path`). Without `USE-ARTIFACT` the stack underflows. Shen rejected. `should_continue` in `client/continue_policy.py` returns `False` on `ok: False`, even if `continue` is true — the client test `test_studio_app_jsx_only_must_not_stop` encodes that halt. Loop stopped. User-visible result: nothing.

That is not a model failure. It is the harness charging a language tax and then treating non-payment as a terminal critic event.

## Complexity that paid rent vs complexity that did not

**Paid rent, barely, and only as scar tissue.**

`client/job.py` allocating `GOAL.md` / `PROGRESS.md` *before* the planner is the right kind of complexity. [`docs/HARNESS.md`](../../HARNESS.md) already names the previous death: episode 1 did `READ-FILE` on a file the host had not created. Pi does not die because a skill file is absent. Ralph allocates the stack first. That lesson is real. Keep the host-owned job files.

`ensure_run_gates` is the same instinct: if the model forgets `RUN-GATES`, the host inserts it. The host already rewrites the program when the program is a protocol detail. That is the one local pattern that matches "if I don't need it, it won't be built" — the model does not need to remember to measure.

`harness/src/livingdict/gates.py` measuring *something other than a receipt* is also real. Structural green (sources/build/bundle) is not success. Hidden `--claims` in `client/compare.py` is the honest judge: applied after the arm finishes, restored, not invented by the agent. Pi and grok passed that judge without knowing it existed. That is how a harness should score.

JSONL traces (`livingdict.trace.emit`), receipts, `envelope.json`, `_episodes.json`, and a compare that isolates workspaces are the inspectability core. Dual UIs (CLI, `POST /think`, browser) on a shared envelope ABI is the "alternative UIs on a small core" thesis — *if* the core stayed small.

**Did not pay rent.**

The `USE-ARTIFACT` / `WRITE-FILE` split did not pay rent. [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) says the split exists so Forth stays control flow "so JSON-plan and Python-plan arms can share the same payloads later." Those arms are listed under "What stays out" / "Not started." You are paying, on every live turn, for a future that is not built. The compare run is the invoice.

Shen as a second (and third, and fourth) Accept/Reject of the same stack walk did not pay rent on this task. The live critic is `openresty/shen/preflight.shen` via shen-lua. The same contracts exist in `harness/src/livingdict/preflight.py`, `openresty/lua/forth.lua` `validate`, `shen/critic/validate.shen`, `browser/shen/validate.shen`, and `eval/ldeval/forthcheck.py`. Six implementations of "unknown word / underflow / write glob / missing artifact." The critic's only live act on fizzbuzz was to throw away a correct product because the model used one word instead of two.

`continue` as a model-emitted hint plus `should_continue`'s flag/tested/wrote/discharged lattice did not pay rent. It is a built-in plan-mode / todo machine. The client tests document a previous studio failure: the planner wrote `src/App.jsx` and set `continue=false`. The policy grew another branch. That is a list paying rent.

Model-authored `claims.json` as a required first increment did not pay rent. The planner SYSTEM forces a claims schema, forbids weakening it, forbids `index.html` as a source path, and calls a title tag "not a product." That is leftover product-shape (Solid/Three studio) leaking into a general harness. Compare already has the right claims: host-owned, hidden, applied after. The model spent tokens inventing an exam the critic never let it sit.

Colon-word persistence did not pay rent on the compare, because compare correctly gives livingdict a *cold* private `.dictionary/`. The shared think dictionary already contains the word the host knows it needs:

```
: INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;
```

That file is `openresty/var/run/think/dictionary/words/INSTALL.fs`. Selftest and `harness/tests/test_dictionary.py` treat `INSTALL` as the intended user-facing write. The planner SYSTEM does not mention `INSTALL`. A cold job cannot use a word that only exists after a previous warm session. The unique mechanism is disabled on the run that was supposed to prove the harness.

Dumping the world into the planner did not pay rent. `observe_workspace` will send up to 80 000 characters of every product file, `observe_dictionary` 20 000, `observe_discharge` 12 000, then the SYSTEM says do not `READ-FILE` `GOAL.md` / `PROGRESS.md` because they are already in the dump. That is the opposite of context engineering: inject a file, then spend prompt tokens forbidding the model to open it.

Three bodies (Python harness, OpenResty, browser/ShenScript) plus an eval suite of canned envelopes did not pay rent as a *live* harness. Canned `config-01` uses the correct `USE-ARTIFACT` dance. Eval can be green while the planner cannot land fizzbuzz. The 40-task lab is measuring the VM, not the loop a user types into.

**The critic vs YOLO.**

Pi's default on a local machine is YOLO: four tools, no permission theater, trust the user. Living Dictionary's default is the opposite: the plan is untrusted until Shen says Accept. That is a reasonable eval hypothesis (family `safety_boundary`). It is the wrong default for "write fizzbuzz in this directory." Project trust in this repo is supposed to be `dictionary_dir` — loading project-local extensions. That is the pi-shaped part. The critic then treats the model's *syntax* as the threat. Stack underflow is not an exfiltration. It is a word the model was never trained to emit.

## The tax of a plan language models were not trained on

Name the tax.

Frontier models are RL-trained to call `read` / `write` / `edit` / `bash` (or grok's equivalent). Pi's system prompt plus those four tool schemas is under 1 000 tokens and mostly says "use them." Living Dictionary asks the same model to emit, in one shot:

1. A JSON object (no markdown) with five keys.
2. A Forth program using a closed word list, stack order, `S"` strings, and colon definitions.
3. A separate `artifacts` map of full file bodies.
4. A pairing ritual: `S" path" USE-ARTIFACT S" path" WRITE-FILE`.
5. A `claims.json` schema with `kind`, `any`, `path`, `min_bytes`.
6. A `continue` hint whose meaning is overridden by the host.
7. `RECEIPT` at the end, which the host will also insert.

`USE-ARTIFACT` is documented as *not* filesystem I/O. `WRITE-FILE` pops content then path. The model did what write-trained models do: name the path and write. The critic scored the dance, not the files.

That tax is paid three times:

- **Generation tax.** The model must emit a language it was not trained on. Prompting harder does not cancel RL. The SYSTEM already lists `USE-ARTIFACT`. The model still omitted it. More "do not" will not install the files.
- **Rejection tax.** A static critic that rejects *syntax of the untrained language* converts a correct artifact set into a 400 and an empty workspace. A tool-loop write that failed would at least leave a stack trace the model could retry.
- **Continuation tax.** `should_continue` treats critic reject as halt. Pi's loop treats a failed tool as another observation. You built the more expensive plan language *and* removed the recovery the cheap language gets for free.

When is the tax worth paying?

Worth it if, and only if, three things are true at once:

1. The plan is executed with the model *out of the loop*, and that batching actually cuts median model calls or tokens by the 25% the eval spec claims (`eval/docs/EVALUATION.md`, hypothesis 1).
2. Preflight rejects *policy* — writes outside globs, unknown effects, prompt-injected paths — not *stack arithmetic the model cannot see*.
3. Promoted words reduce cost on later family members (hypothesis 5) by enough to cover cold-start failures.

None of those are demonstrated on the live compare. The canned eval envelopes already know the dance; they cannot prove (1) or (3) for a planner. The critic on fizzbuzz demonstrated the opposite of (2): it blocked a write that pi performed in five trained tool calls.

A cheaper way to keep the interesting part: Forth can remain the *host IR*. The model-facing surface can be `{ artifacts, optional reads/commands }`. The host compiles that to words. Then the model stays in the distribution it was trained on, and you still get a reviewable program, a critic on globs/effects, and a dictionary of host-owned skills. That pays the tax on the side where it is cheap (deterministic code), not on the side where it is expensive (next-token prediction of `USE-ARTIFACT`).

If you refuse that, the minimum payment is: **one write word**. `INSTALL` already exists. It is one line. Making the model emit `DUP USE-ARTIFACT SWAP WRITE-FILE DROP` is the tax. Shipping `INSTALL` as a host word, or auto-installing every artifact key, is declining to collect it.

## Context: what the model should see, and what the host should never ask it to remember

**Planner SYSTEM** (`client/planner.py` lines 31–69): 39 source lines, about 2 020 characters, about 310 words, about 450–500 tokens. That is smaller than Claude Code's prompt and in the same *order of magnitude* as pi's system prompt *before* tools. It is not the size that is wrong. It is what the tokens are spent on, and what is then stapled underneath.

Every explicit prohibition in that SYSTEM:

1. Emit one JSON object only (**no markdown**).
2. **Never** substitute an eval fixture (`app/config.py`) or assume a stack (Python, Solid, Three, a game engine).
3. **Do not** `READ-FILE` `GOAL.md` / `PROGRESS.md`.
4. **Do not** emit a program that only reads files and writes a `RECEIPT`.
5. **Never** weaken claims to make them pass.
6. **Do not** write `.livingdict-run/**`, `.git/**`, `node_modules/**`, `dist/**`.

`next_episode_extra` adds a seventh: **Do not** ask the user.

Each "do not" is a previous harness bug compiled into the prompt. The host already owns job files, already inserts `RUN-GATES`, already forbids those globs in policy. Repeating them to the model is asking it to remember the harness. Pi's thesis is that the model should see tools and the user's project, not a changelog of how the harness used to break.

**What the model should see**

- The goal, once. Not also as `GOAL.md` in the dump and also as the `GOAL:` header.
- A file list, or the few files that matter. Not up to 80 kB of every text file in the tree.
- The last discharge report if a previous episode ran gates. That is backpressure. That is useful.
- Names of host words that actually exist *in this job's dictionary*, if any. Not a lecture on words it must not call.

**What the host should never ask it to remember**

- The arity of `WRITE-FILE` and the existence of `USE-ARTIFACT`. If artifacts are in the envelope, the host installs them. Same move as `ensure_run_gates`.
- That `GOAL.md` / `PROGRESS.md` exist, must not be `READ-FILE`'d, and will trap if missing. Put job files outside the product tree (traces already live under `openresty/var/run/think/` or `.livingdict-run/`). Then stop mentioning them.
- The `claims.json` shape, `min_bytes: 200`, and "not `index.html`." That is studio scar tissue. Host-owned claims, or tests the user already has.
- `continue`. The host loops until claims discharge or the cap. Cap is a halt, as `HARNESS.md` already says. The model does not vote.
- `RECEIPT`. The host already writes one if the program forgot (`agent.lua` `run_request`).
- "Leftover product from an earlier job is not this goal being done." Episode 1 already resets `PROGRESS.md`. If leftover files confuse measurement, the host wipes or ignores them. Do not narrate the job lifecycle into the weights.

**Injection that is not surfaced.**

The planner user message is assembled in `plan()`: goal, full workspace dump, dictionary dump, discharge dump, optional `CONSTRAINTS`. The browser user does not see that packet. The compare summary does not show it. `_episodes.json` on the failing run stored the program and `error: "preflight rejected program"` and omitted critic details. The artifacts that *were* the work sat in `envelope.json` beside the product tree. That fails inspectability: the successful files existed, the UI showed an empty workspace, and the session format is not one documented conversation — it is an envelope plus a receipt plus a JSONL trace in a run dir the compare user does not open.

Pi's insistence on a documented session format and "every event visible" is the part to steal. Not the four tools. You already emit events. Surface the envelope artifacts in the work pane *even on reject*. Surface the critic errors in `_episodes.json`. If the model wrote `fizzbuzz.py` as an artifact, the user should see `fizzbuzz.py`, reject or not.

## Dictionary / extensions: the one unique thing that might be worth it

The dictionary is the only unique bet that is not a restatement of a tool loop.

Hypothesis, from the eval spec: promoted colon words reduce cost on later family members without much correctness loss or negative transfer. Mechanism, from `dictionary.py` / `dictionary.lua`: `: NAME ... ;` saved under `dictionary_dir/words/*.fs`, prepended as prelude, visible to critic and VM, traced as `dictionary.promote` / `dictionary.reuse`. That is "extensions exist so the core stays small," implemented as Forth instead of pi's "CLI + README, read on demand."

What would make it worth it:

- The *host* ships a tiny prelude of words that cancel the plan-language tax. `INSTALL` is the first and maybe only required word. Better: there is no `INSTALL` because artifacts auto-install, and the dictionary is for *domain* skills (`NORMALIZE-CONFIG`, `RUN-PYTEST`), not for stack sugar around writes.
- Words are retrieved, not dumped. `observe_dictionary` concatenates every `*.fs` up to 20 kB. Progressive disclosure — name list now, body when the model names the word — is the MCP lesson from the same author. Dumping the dictionary is MCP with a Forth accent.
- Cold start is defined. Compare isolates `.dictionary/`. That is fair. It also means episode 1 of a new job has no extensions. If the unique value only appears on episode 4 of a warm family, say so, and do not claim to be a general coding harness until cold start lands files.
- Project trust is the dictionary directory, not Shen. Loading `words/*.fs` from the project is the extension surface. The critic should assume those words, not assign them `Contract(0, 0)` and skip their bodies (`preflight.shen`: "Colon bodies are not checked"). An unchecked prelude plus a pedantic check of `WRITE-FILE` arity is the wrong split: you trust user extensions less than you police trained write syntax.

What would make it a museum piece:

- Using the dictionary to store `INSTALL` after a human or a previous session discovered the tax, then running the public compare with an empty private dictionary.
- Asking the model, on fizzbuzz episode 1, to "define colon words (skills) that persist." That is a research prompt, not a coding turn.
- Growing graph words, promotion evidence gates, and a warm/cold eval matrix before the cold path can write `hello.txt`.

Keep the dictionary. Narrow it. It is the one piece that is not "pi plus a worse plan language." It is also not free: every prelude word is context, every unchecked colon body is a hole in the critic you are otherwise proud of, and every compare that cold-starts will not see it unless the host owns the first words.

## Verdict: 5 concrete design moves, ranked (including at least one "delete this")

1. **Delete the model-facing `USE-ARTIFACT` + `WRITE-FILE` dance. Auto-install envelope artifacts.**  
   If the envelope contains `"fizzbuzz.py": "..."`, the host writes `fizzbuzz.py`. Optionally keep one host word `INSTALL` for explicit control flow. Do not keep two words whose only purpose is to share payloads with JSON-plan and Python-plan arms that do not exist. This is the same move as `ensure_run_gates` and `ensure_job_files`: protocol is host-owned. It matches "if I don't need it, it won't be built" because you do not need a two-word write to test the dictionary, the critic's glob policy, or claims. The 2026-08-15 compare is the proof. Collapsing the pair is not a nicety. It is declining to collect a tax the model will not pay.

2. **Delete halt-on-reject.**  
   In `should_continue`, `if not body.get("ok"): return False` is the user-visible "nothing." A critic error is a tool result. Feed `details` (stack underflow, missing artifact, forbidden glob) into the next episode the way a failed `write` comes back in pi. Cap still halts. Policy violations can still refuse to mutate. Syntax of an untrained language must not end the job. If you auto-install (move 1), most of these rejects disappear; the rest should retry.

3. **Delete `continue` and delete required model-authored `claims.json`.**  
   Host loop: run until `goal_discharged(check)` or `episode == cap`. Cap is a halt, not success. Claims are host-owned (user file, hidden compare claims, or inferred from the prompt). `continue_policy.py`'s flag/tested/wrote lattice is a built-in todo list that exists because the planner once set `continue=false` after writing `App.jsx`. That is the list that paid rent. `RUN-GATES` stays. Structural green stays insufficient. The model stops inventing the exam and hinting whether to go on.

4. **Shrink what the model sees to the goal, a file list, and the last discharge.**  
   Cut the SYSTEM to: you implement the GOAL; put file bodies in `artifacts`; the host installs and measures. Remove every "do not" that the host already enforces. Stop dumping 80k+20k+12k. Stop writing `GOAL.md` / `PROGRESS.md` into the product tree; keep them in the run dir with traces. Surface envelope + critic + receipt in one documented session object so a reject is inspectable. This is the context-engineering thesis applied to *this* loop, not a request to paste pi's prompt.

5. **Keep the dictionary; delete the extra critics until the live loop lands files.**  
   One preflight is enough to reject unknown words, disallowed effects, and writes outside globs. Python `livingdict.preflight` already does that. Shen-lua, the Lua `validate` mirror, the portable `shen/critic`, and the shaken browser critic are three more copies of a check that just deleted fizzbuzz. "If I don't need it, it won't be built." You need one critic and one dictionary. You do not need six Accept/Reject implementations and three bodies to learn whether colon words save tokens. Seed the host prelude with whatever write word remains after move 1, or with nothing if artifacts auto-install. Then, and only then, let the model promote *domain* words and measure reuse on a warm family. If that measurement never beats four trained tools by 25% on routine work, the dictionary is still allowed to exist as an extension surface — but Forth as the *model-facing* plan language should be demoted to a host IR.

Do not become pi. Become a harness whose unique pieces survive contact with `write fizzbuzz`. Right now the unique pieces explain a 9-second reject, and the four-tool loop leaves three files on disk.
