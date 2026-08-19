# Living Dictionary

**A coding agent that plans, then proves it.** You give it a goal. It
negotiates the acceptance criteria with you, writes the entire change as
one inspectable program, gets that program past a non-LLM safety critic
before a single file is touched, executes it with the model switched off,
and only claims success when *your* approved checks actually pass — build
it, test it, run it, curl it.

Every other coding agent is a model in a tool loop: it acts one call at a
time, "done" means the model stopped talking, and the transcript is the
only record. Living Dictionary inverts all three:

- **The plan is a program, not a conversation.** The model emits one
  envelope — full file contents plus a tiny Forth control program over a
  dependency graph of nodes. Independent nodes run in parallel waves;
  write conflicts are impossible by construction, not detected after.
- **A critic gates every plan before any I/O.** A deterministic,
  non-LLM validator (Python, or Shen on the OpenResty/browser bodies)
  rejects bad stack effects, forbidden paths, cycles, and out-of-node
  writes. Rejection is backpressure — the errors feed the next attempt —
  and an identical resubmitted plan is fingerprint-blocked, so the loop
  cannot thrash.
- **"Done" is a contract you signed, not a vibe.** Before work starts,
  the model drafts acceptance claims — including executable `check`
  commands — and you approve, amend, or iterate. After sign-off the
  contract is frozen outside the model's reach. Success means those
  checks exited 0. A run judged only by claims the model wrote itself is
  loudly labeled as such.
- **Every run is a replayable ledger.** Episodes, critic verdicts,
  installs, gate results, and scheduling land in an append-only,
  hash-sequenced event log with content-addressed snapshots. You can
  reconstruct the workspace at any step and replay a run without a model.
- **Skills persist as code.** Accepted colon definitions live in a
  dictionary the next run loads and the critic re-checks — executable
  memory, not advice in a markdown file.

## Try it

```bash
ln -s "$PWD/bin/livingdict" ~/.local/bin/ldh   # or call bin/livingdict directly

mkdir /tmp/demo && cd /tmp/demo
ldh tui                    # type a goal; approve/amend the drafted claims; watch it work
ldh -p "goal" --cwd .      # headless: exit 0 iff the claims discharged
```

The TUI streams everything live: the model's reasoning, each episode's
plan and rationale, per-node wave execution, gate verdicts with the
exact failing claim, and the provenance of the judge
(`[approved contract]` vs `[model-authored claims]`).

It also embeds: `livingdict run` speaks a bounded-runner protocol
([SCUD](docs/SCUD.md) `rho.run/v1` — stdin request, JSONL events, signed
grants), and `livingdict policy` is a deny-by-default policy evaluator.

**See it happen:** [examples/shen-todo](examples/shen-todo/) is one real,
unedited session — a five-round contract negotiation, an honest red on
episode 1, a working HTTP todo service on episode 2, and the model caught
planting strings to game the one weak claim in the contract.

The rest of this README is the reference: the lab, the bodies, the ABI.

## Three trees

| Path | What it is |
|---|---|
| [`eval/`](eval/) | Living Dictionary Eval v0.1.0. Hidden verifiers, cold/warm dictionaries, crash/resume, adapter protocol. The spec. |
| [`harness/`](harness/) | Python capability host, Forth VM, plan envelopes, Python preflight, ldeval adapters. |
| [`openresty/`](openresty/) | Same six words + Forth + **shen-lua** critic, once per nginx worker. HTTP `/think` and `livingdict-resty` adapter. |

The eval suite must not have its oracles or protected tests edited to flatter an agent.

## How a turn works

```
goal + observation
        │
        ▼
  planner                        ← only this may call a model
        │  plan envelope (full artifact bodies)
        ▼
  critic  validate → Accept | Reject
        │  Python livingdict.preflight    (harness/adapters/forth_shen.py)
        │  or shen-lua named validate     (openresty/)
        ▼
  host intern + wave take        ← CAS store; Linda space; not model-facing
        │
        ▼
  Forth body runs tool words     ← no model in the loop
        │
        ▼
  protected verifier (ldeval)
```

The envelope is `{ language, program, artifacts, rationale }`. Patches are
artifact files. Forth says `S" app/config.py" USE-ARTIFACT … WRITE-FILE`, not a
multiline string of Python. Interning is the host's job on receipt; the
model still emits bytes. Spec: [`docs/design/STORE.md`](docs/design/STORE.md).

## Capabilities

Every arm calls the same host words:

| Word | Effect | Role |
|---|---|---|
| `READ-FILE` | read | File text. Missing file is a typed trap. |
| `LIST-DIR` | read | Paths under a directory. |
| `SEARCH` | read | Workspace hits (path, line, text). |
| `WRITE-FILE` | write | Replace one file, after glob/effect checks. |
| `RUN-TESTS` | exec | Same runner as `RUN-GATES` (kept for eval envelopes). |
| `RUN-GATES` | exec | Success gates. Structural (sources/build/bundle) plus goal `claims` / `look`. Writes `.sb/discharge_report.json`. |
| `RECEIPT` | — | Write `receipt.json` (hashes, effects, changed files). |

Stack sugar: `DUP` `DROP` `SWAP` `OVER`, `S"`, `: ;`, `IF ELSE THEN`.

## Shen

**Not shen-go.** The intended pair is pyrex41’s dual-end:

- **shen-lua** — this repo’s live critic on OpenResty (kernel 41.2, pin v0.10.1).
- **ShenScript** — later, same `.shen` ideas in the browser.

Shen does not emit patches, does not call the model, and does not replace Forth.
It only answers Accept or Reject.

| Surface | Critic |
|---|---|
| `harness/adapters/forth.py` | none |
| `harness/adapters/forth_shen.py` | `livingdict.preflight` (Python) |
| `openresty/bin/livingdict-resty` and `POST /think` | `openresty/shen/preflight.shen` via shen-lua |

Portable contracts: [`harness/shen/`](harness/shen/) and
[`openresty/shen/contracts.shen`](openresty/shen/contracts.shen). See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Claim (still the experiment)

Same model, same sandbox, same six capabilities, same budgets. Only the control
language changes (ReAct vs JSON plan vs restricted Python vs Forth).

Go / no-go, from [`eval/docs/EVALUATION.md`](eval/docs/EVALUATION.md):

- Forth + preflight stays within 5 percentage points of the strongest internal baseline.
- It cuts median model calls or total tokens by at least 25% on routine multi-step families.
- A warm dictionary may not buy that cost cut with more than 5 points of correctness loss, extra policy violations, or material negative transfer on sequence-8 false friends.

## Status

- Eval suite vendored; oracle 40/40, suite tests green.
- Python host, Forth VM, envelopes, Python preflight, two ldeval adapters.
- Event-sourced loop kernel; graph critic (declared `writes` / `depends_on`); Kahn waves.
- Layer A store: `run_dir/objects/<aa>/<sha256>`, derived `facts()` / `as_of(seq)`, additive `tree_before` / `tree_after` on receipts and `gates.measured`. `LIVINGDICT_OBJECTS` may share one store across runs. Old events replay without a store.
- Layer B space: in-process `out` / `rd` / `take` + leases behind wave dispatch. Scheduling records (`space.out` / `space.take` / `space.lease_expired`) are trace-only. Linda is the executor, never the planner. Layer C (cross-process) stays shut.
- OpenResty host with a real shen-lua critic (selftest requires the kernel). Lua/JS intern the same blobs; OpenResty waves stay serial.
- Canned `config-01` through `livingdict-resty` + ldeval succeeds (hidden verifier + policy).
- `GET /health` and `POST /think` serve that same path.
- Browser body specified in [`docs/BROWSER.md`](docs/BROWSER.md); built by `/shenscript-browser` (vanilla JS + `ratatoskr --target js --web`, same critic shaken `--target lua`).
- Planner: grok-4.6 via SpaceXAI OAuth (`~/.grok/auth.json`) or `XAI_API_KEY`. Client default turn is a goal.
- Live `/think` persists colon words under `dictionary_dir/words/` and reloads them next turn.
- Live loop contract: [`docs/HARNESS.md`](docs/HARNESS.md). Host allocates job files before plan; every episode runs `RUN-GATES`.
- SCUD child: `livingdict run` speaks `rho.run/v1` (`docs/SCUD.md`).
- Side-by-side compare (grok headless / pi headless / this host): [`docs/COMPARE.md`](docs/COMPARE.md).
- Not started: Layer C, promotion evidence gates, ReAct/JSON/Python arms, Harbor / SWE-bench.

## Commands

Python 3.11+, `luajit`, and a shen-lua checkout (see [`openresty/README.md`](openresty/README.md)). OpenResty only for the HTTP host.

```bash
make test                  # eval + harness + openresty + scudcheck
make eval-oracle           # 40/40 expected
make eval-resty-config-01  # ldeval config-01 via livingdict-resty
make openresty-serve       # http://127.0.0.1:8080  (blocks)
make think-config-01       # POST canned envelope to /think
make livingdict            # headless livingdict -p loop
make compare-dry           # grok / pi / livingdict argv present?
make compare PROMPT='…'    # same prompt, three isolated arms
make browser-shake         # ratatoskr js --web + lua critic
make browser-test          # node browser/test/node-selftest.mjs
make browser-serve         # python3 -m http.server in browser/
```

With the host up, the same turns are in the browser at
<http://127.0.0.1:8080/> (`client/README.md`).

```bash
# Python adapter, no Shen kernel
export LIVINGDICT_ENVELOPE="$PWD/openresty/examples/config-01.envelope.json"
python3 harness/adapters/forth_shen.py /path/to/request.json
```

## Layout

```
eval/                         benchmark (do not edit oracles)
harness/src/livingdict/       Python ABI (host, Forth, kernel, store, space)
harness/adapters/             forth, forth-shen
harness/shen/                 portable spec + port decision
openresty/lua/                host, Forth, shen-lua bridge, agent
openresty/shen/               contracts.shen + preflight.shen
openresty/bin/livingdict-resty
openresty/examples/           canned envelopes
docs/ARCHITECTURE.md
docs/design/STORE.md          Layer A/B spec of record (C deferred)
docs/design/GRAPH.md          envelope nodes + Kahn waves
docs/SCUD.md                  rho.run/v1 child
shen/critic/                  portable eval-free critic (shake entry: validate.shen)
bifrost.suite.json            critic fixture (marker ALL PASS)
browser/                      vanilla JS host + shaken ShenScript critic
```

## What this is not (yet)

Layer C (shared space, obligation tuples), automatic promotion evidence gates,
WAForth, Harbor, or SWE-bench. The planner, IR, store, in-process space, and
OpenResty critic are in-tree; those next pieces are not.
