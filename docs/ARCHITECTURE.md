# Architecture

Living Dictionary treats the **plan as a program**. The model (when present)
emits a Forth episode plus file artifacts. A critic accepts or rejects that
episode. Only then do capability words mutate the workspace. The model is not
in the loop while words run.

## Components

```
                    ┌─────────────────────────────────────┐
  goal + observe    │  Planner (not shipped)              │
 ──────────────────►│  emits a plan envelope              │
                    └─────────────────┬───────────────────┘
                                      │ { language, program, artifacts }
                                      ▼
                    ┌─────────────────────────────────────┐
                    │  Critic  validate → Accept | Reject │
                    │  Python preflight  or  shen-lua     │
                    └─────────────────┬───────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │  Capability host (only I/O)         │
                    │  Forth VM runs READ / WRITE / …     │
                    │  policy + JSONL traces + receipts   │
                    └─────────────────┬───────────────────┘
                                      ▼
                         ldeval protected verifier
```

Two bodies share that ABI:

| | Python (`harness/`) | OpenResty (`openresty/`) |
|---|---|---|
| Host | `livingdict.host.CapabilityHost` | `lua/host.lua` |
| Forth | `livingdict.forth.ForthVM` | `lua/forth.lua` |
| Critic | `livingdict.preflight.validate` | `shen/preflight.shen` via shen-lua |
| Adapter | `adapters/forth.py`, `forth_shen.py` | `bin/livingdict-resty` |
| HTTP | — | `GET /health`, `POST /think` |

Eval (`eval/`) is not a body. It is the laboratory: tasks, hidden verifiers,
policy after the fact, traces, scoring.

## Plan envelope

```json
{
  "language": "forth",
  "program": "S\" app/config.py\" USE-ARTIFACT S\" app/config.py\" WRITE-FILE RUN-TESTS RECEIPT",
  "artifacts": { "app/config.py": "<full file>" },
  "rationale": "never executed"
}
```

`USE-ARTIFACT` pushes artifact text. It is not filesystem I/O. This keeps Forth
as control flow so JSON-plan and Python-plan arms can share the same payloads
later.

How an adapter finds the envelope, in order:

1. `request.resume` → `checkpoint.json` beside `receipt_path`
2. `LIVINGDICT_ENVELOPE`
3. `dictionary_dir/envelope.json`

## Critic

`validate(program, allowed_effects, allowed_globs, forbidden_globs, artifact_keys)`
returns Accept or Reject. Reject reasons include unknown word, stack underflow,
disallowed effects, write path outside globs, missing artifact.

On OpenResty:

- `contracts.shen` is the typed core (`(tc +)`): stack contracts, `write-ok?`
  (fnmatch, including `*` across `/`, matching Python `fnmatch`).
- `preflight.shen` is the named `validate` (untyped shell, may `lua.call` the
  Forth tokenizer).
- `bridge.lua` boots shen-lua **once** (`init_worker_by_lua` or adapter
  startup). The live path does not fall back to Lua `forth.validate`.
- Kernel and fasl caches are pinned under `openresty/var/` so they never appear
  as workspace mutations.

Shen does not write files, does not call an LLM, and does not execute the plan.

## Host policy

Writes must match `allowed_globs` and must not match `forbidden_globs`. Paths
must stay inside the workspace. `RUN-TESTS` sets `PYTHONDONTWRITEBYTECODE=1`.
Identical `WRITE-FILE` bytes are idempotent (no second `mutation.applied`).

ldeval snapshots the workspace after the adapter exits. Sidecar files
(checkpoints, traces, Shen caches, `.pyc`) must not land in the task tree
unless the task allows them.

## ldeval adapter

The runner starts the command with cwd = task workspace and appends
`request.json`. Exit 0 means the adapter finished; the protected verifier
decides success. See [`eval/docs/ADAPTER_PROTOCOL.md`](../eval/docs/ADAPTER_PROTOCOL.md).

Canned check already run in this repo:

```bash
make eval-resty-config-01
```

That uses [`openresty/examples/config-01.envelope.json`](../openresty/examples/config-01.envelope.json)
(the protected oracle as an artifact) and `openresty/bin/livingdict-resty`.

## HTTP

`make openresty-serve` listens on `:8080`.

| | |
|---|---|
| `GET /health` | `{ ok, shen, critic, workspace, dictionary }` |
| `POST /think` | envelope, full `request.json`, `{ request, envelope }`, or `{ goal }` |

Default product workspace for a live turn is `apps/studio` (nginx
`$livingdict_workspace`). Forth is the harness, not the product: the GOAL
names arbitrary software. Traces, receipts, and the colon-word dictionary
stay **outside** the product tree (`openresty/var/run/think/`).

`RUN-TESTS` / `RUN-GATES` under nginx use `ngx.pipe`. Gates write a
schema v1 discharge report (sources, build, bundle; `sb gates` when a
Shen spec exists) and that report is the success measure.

## Planner

`POST /think` with `{ "goal": "..." }` runs `client/planner.py` (grok-4.6).
Auth: SpaceXAI OAuth in `~/.grok/auth.json` (`grok login --oauth`), else
`XAI_API_KEY`. The browser never sees a key. The model only writes the
envelope; Shen still Accept/Rejects before Forth mutates.

See [`HARNESS.md`](HARNESS.md) for the live loop contract. Job state
lives in the run dir, not the product tree. The host appends
`RUN-GATES` if the program forgot. Structural green is not success.
Cap (32) is a halt. `POST /think` is one episode; a reject is 200.

## What stays out

ReAct / JSON-plan / Python-plan arms, promotion evidence gates, Forth `PAR` /
`FORK` words, Harbor, SWE-bench. Graph *events* (`graph.node.start` /
`finish`) fire when the host applies `envelope.artifacts`. See
[`design/GRAPH.md`](design/GRAPH.md).

The browser body is specified in [`BROWSER.md`](BROWSER.md) and built by
the `shenscript-browser` workflow: vanilla JS + a Ratatoskr-shaken
ShenScript critic (`--target js --web`), same sources shaken `--target lua`
for OpenResty.
