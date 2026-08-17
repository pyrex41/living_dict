# Living Dictionary

A coding agent whose plan is a Forth program. Skills are colon definitions.
The model writes (or rewrites) the program; it is not in the loop while words
run. Shen (or a Shen-shaped critic) rejects a bad plan before it touches the
repo.

This repository is the experiment: a 40-task lab, a Python harness, and an
OpenResty host that runs the same ABI on shen-lua.

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
  planner (not shipped)          ← only this may call a model
        │  plan envelope
        ▼
  critic  validate → Accept | Reject
        │  Python livingdict.preflight    (harness/adapters/forth_shen.py)
        │  or shen-lua named validate     (openresty/)
        ▼
  Forth body runs tool words     ← no model in the loop
        │
        ▼
  protected verifier (ldeval)
```

The envelope is `{ language, program, artifacts, rationale }`. Patches are
artifact files. Forth says `S" app/config.py" USE-ARTIFACT … WRITE-FILE`, not a
multiline string of Python.

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
- OpenResty host with a real shen-lua critic (selftest requires the kernel).
- Canned `config-01` through `livingdict-resty` + ldeval succeeds (hidden verifier + policy).
- `GET /health` and `POST /think` serve that same path.
- Browser body specified in [`docs/BROWSER.md`](docs/BROWSER.md); built by `/shenscript-browser` (vanilla JS + `ratatoskr --target js --web`, same critic shaken `--target lua`).
- Planner: grok-4.6 via SpaceXAI OAuth (`~/.grok/auth.json`) or `XAI_API_KEY`. Client default turn is a goal.
- Live `/think` persists colon words under `dictionary_dir/words/` and reloads them next turn.
- Live loop contract: [`docs/HARNESS.md`](docs/HARNESS.md). Host allocates job files before plan; every episode runs `RUN-GATES`.
- Side-by-side compare (grok headless / pi headless / this host): [`docs/COMPARE.md`](docs/COMPARE.md).
- Not started: promotion evidence gates, ReAct/JSON/Python arms, Harbor / SWE-bench.

## Commands

Python 3.11+, `luajit`, and a shen-lua checkout (see [`openresty/README.md`](openresty/README.md)). OpenResty only for the HTTP host.

```bash
make test                  # eval + harness + openresty + client
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
harness/src/livingdict/       Python ABI
harness/adapters/             forth, forth-shen
harness/shen/                 portable spec + port decision
openresty/lua/                host, Forth, shen-lua bridge, agent
openresty/shen/               contracts.shen + preflight.shen
openresty/bin/livingdict-resty
openresty/examples/           canned envelopes
docs/ARCHITECTURE.md
shen/critic/              portable eval-free critic (shake entry: validate.shen)
bifrost.suite.json        critic fixture (marker ALL PASS)
browser/                  vanilla JS host + shaken ShenScript critic
```

## What this is not (yet)

A planner, automatic word promotion, WAForth, multi-agent dictionaries, Harbor,
or SWE-bench. The IR and the OpenResty critic are in-tree; those next pieces
are not.
