# Living Dictionary

**A coding agent that turns a model's proposal into a checked program, then
runs that program with the model switched off.** You give it a goal and an
acceptance contract. The model can inspect the repository through bounded
research tools, but it does not mutate the workspace one tool call at a time.
Instead it emits one inspectable plan envelope: complete artifact bodies plus
a small Forth program describing how to install and verify them.

If you already use Codex, Claude Code, or Pi, the easiest way to understand
Living Dictionary is as a different control plane around the model:

| | Typical coding-agent loop | Living Dictionary |
|---|---|---|
| Model output | The next tool call or patch | A complete, executable plan envelope |
| Before writes | Policy checked per tool call | The whole plan is statically checked by a non-LLM critic |
| Execution | Model remains in the action loop | Host executes accepted Forth with the model off |
| Completion | Agent decides it is finished, often after tests | Frozen approved claims must be discharged |
| Record | Conversation and tool transcript | Hash-sequenced ledger, receipts, and workspace snapshots |
| Learned procedure | Prompt, memory, or skill text | Typed executable words, promoted only after demonstrated reuse |

This is not a claim that interactive tool loops are inherently bad. They are
excellent for exploratory work. Living Dictionary is aimed at the boundary
where a proposed change should become inspectable, policy-checkable, and
measurably complete before it is trusted.

### What is unusual here

- **The unit of action is a program.** The model emits full file contents and
  a tiny Forth control program over a dependency graph. Independent nodes can
  run in parallel waves; declared write conflicts are rejected before
  execution.
- **Policy sees the whole proposed change.** A deterministic, non-LLM critic
  checks stack effects, filesystem effects, allowed paths, graph cycles, and
  node write scopes before any artifact is installed. A rejection becomes
  structured input to the next planning episode, and identical rejected plans
  are fingerprint-blocked.
- **Research and authority are separate.** A bounded OODA layer may list,
  search, and read repository evidence to formulate better questions. Those
  tools gather context; they cannot authorize writes. Only a critic-accepted
  plan receives host capabilities.
- **"Done" belongs to the contract, not the model.** The model may draft
  claims, but approved claims are frozen outside its workspace. Success means
  the relevant builds, tests, commands, or probes actually passed. Runs judged
  only by model-authored claims are labeled accordingly.
- **Execution has a durable, replayable account.** Episodes, critic verdicts,
  mutations, gate results, and scheduling events land in an append-only ledger
  with content-addressed snapshots and receipts. You can audit what happened
  without treating the model transcript as ground truth.
- **Reusable skills are typed code.** Successful Forth definitions can enter
  a dictionary loaded by later runs. Each word declares an
  `( ins -- outs | effects )` contract that is checked against its body.
  First persistence creates a candidate; observed reuse permits promotion.
  Contractless definitions and aliases are quarantined rather than advertised
  as learned skills.

The model can still reason, research, fail, and replan. The architectural
difference is that observation, authorization, execution, and judgment are
separate stages with different owners.

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

## Four trees

| Path | What it is |
|---|---|
| [`beam/`](beam/) | **The live body.** Elixir/OTP host: Forth VM, native typed-Shen critic (shen-erl BEAM bytecode), Linda tuple space with generation-fenced leases, Jido obligation agents, executable-contract gates, benchmark adapters. See [`beam/README.md`](beam/README.md) and [`beam/RESULTS.md`](beam/RESULTS.md). |
| [`eval/`](eval/) | Living Dictionary Eval v0.1.0. Hidden verifiers, cold/warm dictionaries, crash/resume, adapter protocol. The spec. |
| [`harness/`](harness/) | Python capability host, Forth VM, plan envelopes, Python preflight, ldeval adapters. **Frozen reference** — the semantic spec the BEAM body was ported against; nothing new calls it. |
| [`openresty/`](openresty/) | Same six words + Forth + shen-lua critic, once per nginx worker. HTTP `/think` and `livingdict-resty` adapter. |

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

## Shen: one typed critic, three shaken bodies

There is exactly **one** critic source of truth —
[`shen/critic/validate.shen`](shen/critic/) — written as **fully typed
Shen** (11 datatypes, every function signed). The types are verified at
build time by `yggdrasil check` (a `(tc +)` pass on a live kernel added
upstream for this project) and erased in the shake, so the deployed
artifacts stay eval-free. One source, three targets:

| Body | Artifact | Runtime |
|---|---|---|
| `beam/` | shen-erl compiled BEAM bytecode (`kl_kernel`/`kl_validate` in-VM) | native, 54–157µs/validate |
| `openresty/` | yggdrasil `--target lua` | LuaJIT per nginx worker |
| `browser/` | yggdrasil `--target js --web` | ES module in the tab |

Shen does not emit patches, does not call the model, and does not
replace Forth. It only answers Accept or Reject — now with contract
judgments: colon bodies are checked against their declared
stack-and-effect contracts, absent contracts are inferred, recursion is
rejected. `make critic-erl` / `make browser-shake` rebuild the
artifacts through the typecheck gate (`typechecked=true` is asserted in
the manifest). The Python preflight and per-port mirrors are frozen
legacy.

## Results so far

Same model, same sandbox, same capabilities, same budgets. Only the
control language changes (ReAct tool loop vs Forth plan-program). Live
numbers from the August 2026 campaigns, with dates and limitations, are in
[`beam/RESULTS.md`](beam/RESULTS.md):

| benchmark | ReAct baseline (grok CLI) | cold | warm |
|---|---|---|---|
| vendored eval, graph family (8) | 7/8 @ 299k tokens / 48 calls | **8/8 @ 15.8k / 9** | **8/8 @ 14.2k / 8** |
| Aider Polyglot rust+go+cpp (95) | 29/30 @ 968k / 155 *(shared 30-task subsample)* | 91/95 @ 440k / 127 | **92/95 @ 404k / 116** |
| Terminal-Bench 2.0 (curated 15, via Harbor) | — | 2/15 solved, mean 0.133 | — |

Headline: at identical-or-better correctness, the plan-as-program arms
use **~7.6–19× fewer input tokens and 4–5× fewer calls** than the same
model in a ReAct loop.

The preregistered warm-dictionary go/no-go
([`eval/docs/EVALUATION.md`](eval/docs/EVALUATION.md): ≤5pt correctness
loss, ≥25% token cut, no new violations, no negative transfer) has been
run and honestly reads **NO-GO so far**: warm wins are real (rust
30/30 fixing cold's one miss, 4–10% token cuts, zero negative
transfer) but the 25% amortization bar is unmet — cold already
one-shots most tasks, leaving little for a dictionary to amortize. The
open question is now sharp: warm needs task families that take cold
multiple episodes.

The harness has changed since those runs. Do not attribute the table above to
the newer OODA, dictionary-accounting, or cache-isolation work. The frozen
protocol for replacing these historical numbers is
[`docs/design/LATEST_BENCHMARK_CAMPAIGN.md`](docs/design/LATEST_BENCHMARK_CAMPAIGN.md).

### Caching and measurement

Provider prompt caching is treated as an execution optimization, not a source
of benchmark state. Live runs default to `--cache-scope run`: each invocation
gets a fresh private routing identity, while stable system/goal/tool prefixes
can still be reused across episodes inside that run. Headline benchmark paths
force this scope. `shared` is an explicit production mode for cross-run prefix
reuse; `off` removes Living Dictionary's provider-affinity hint, although a
provider may still cache an identical prefix opportunistically.

The OODA research layer also caches bounded, read-only evidence by workspace
content hash. It never caches planner envelopes, critic decisions, checks,
receipts, credentials, or authorization. Receipts and ledgers expose cache
scope, cached-token counts, evidence hits/misses, and timing so warm-provider
effects can be reported separately from task correctness. Detailed semantics
and the metadata-only request recorder are documented in
[`docs/HARNESS.md`](docs/HARNESS.md#cache-isolation).

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
- **BEAM body shipped** (`beam/`): full kernel loop, native typed critic,
  typed promotion gates (contract required + claims discharged), **Layer C
  open** — Linda tuple space with generation-fenced OTP-timer leases and
  Jido obligation agents; deny-by-default dispatcher. 50+ ExUnit tests.
- **Benchmarks run**: vendored eval families, Aider Polyglot (rust/go/cpp),
  Terminal-Bench 2.0 via Harbor (self-contained linux releases for both
  arches, `bench/harbor_ld_beam.py`). Results: [`beam/RESULTS.md`](beam/RESULTS.md).
- Not started: SWE-bench, python/javascript/java polyglot tracks,
  cross-process Layer B (remote wave dispatch).

## Commands

Python 3.11+, `luajit`, and a shen-lua checkout (see [`openresty/README.md`](openresty/README.md)). OpenResty only for the HTTP host.

```bash
# BEAM body (Elixir 1.18+/OTP 27+; brew install elixir)
make beam-test             # 50+ ExUnit tests
cd beam && mix ld.run --goal "..." --cwd PATH   # headless; exit 0 iff claims discharged
cd beam && mix ld.run --goal "..." --cwd PATH --cache-scope run    # isolated default
cd beam && mix ld.run --goal "..." --cwd PATH --cache-scope shared # production optimization
cd beam && mix ld.demo --tasks graph-01,graph-02            # arms race, vendored eval
cd beam && mix ld.polyglot --langs rust,go,cpp --arms cold,warm  # Aider Polyglot tracks
make critic-erl            # typed Shen -> shen-erl BEAM critic (via yggdrasil check)
make beam-release          # self-contained linux release tarball (Harbor installs)

make test                  # eval + harness + openresty + critic-suite + beam + scudcheck
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

SWE-bench, WAForth, remote Layer B wave dispatch, or the full
Terminal-Bench registry (74 tasks remain beyond the curated 15). Layer C
(shared space, obligation tuples) and promotion evidence gates — long
listed here — shipped with the BEAM body.
