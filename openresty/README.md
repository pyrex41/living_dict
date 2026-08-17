# Living Dictionary OpenResty host

The same six host words as [`harness/src/livingdict/host.py`](../harness/src/livingdict/host.py), a hosted Forth VM, and a **shen-lua** critic (`validate` → Accept | Reject). Shen does not emit patches, does not call a model, and does not replace Forth.

System context: [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

Patches travel as envelope artifacts:

```
S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE
```

## Layout

| Path | Role |
|---|---|
| `lua/host.lua` | `READ-FILE` `LIST-DIR` `SEARCH` `WRITE-FILE` `RUN-TESTS` `RECEIPT` |
| `lua/forth.lua` | `S"` integers `: ;` `IF ELSE THEN` `USE-ARTIFACT` + host words; Lua `validate` mirror for comparison only |
| `lua/bridge.lua` | boot shaken lua critic when `dist/critic/app.lua` exists; else full kernel + portable `shen/critic/validate.shen` |
| `lua/agent.lua` | envelope → preflight → Forth → traces / receipts / checkpoint; HTTP `handle` |
| `shen/contracts.shen` | typed portable contracts (no `lua.call`) |
| `shen/preflight.shen` | named `validate` (stack, effects, globs, artifacts) |
| `bin/livingdict-resty` | ldeval adapter (`REQUEST.json`, exit 0 or 2) |
| `examples/config-01.envelope.json` | canned oracle envelope for eval task `config-01` |
| `scripts/think-config-01.sh` | copy `config-01` into `var/think` and `POST /think` |
| `selftest.lua` | luajit, no nginx; **requires** shen-lua |
| `nginx.conf` | boot once per worker; `/health` and `/think` |
| `var/` | kernel cache, fasl, think workspace (gitignored) |

`USE-ARTIFACT` is envelope-only. It is not host I/O.

## Graph waves stay serial here

Stage 2 wave parallelism (`--wave-workers`, `--serial`) lives in the Python
CLI body (`livingdict.execute.execute_waves`). OpenResty `install_artifacts`
in `lua/agent.lua` remains Kahn width 1: one node after another, worker
always `"host"`. That is intentional. Do not port ThreadPool-style waves
into Lua until a compare shows the serial apply losing on `graph-01`.

Wave-boundary `RUN-GATES` after each Python wave is also Python-only.
This host still applies artifacts, then interprets the concatenated
program, then measures once.

## shen-lua (not vendored)

Pin **v0.10.1** (kernel 41.2). Do not commit the ~6 MB bundle.

`bridge.lua` / `nginx.conf` look for, in order: `SHEN_LUA_DIR`,
`openresty/vendor/shen-lua`, `vendor/shen-lua`, `../shen-lua`, `../../shen-lua`,
then `require("shen")` on the existing `package.path`.

```bash
git clone --branch v0.10.1 https://github.com/pyrex41/shen-lua.git ../shen-lua
```

Or vendor without committing:

```bash
git clone --branch v0.10.1 https://github.com/pyrex41/shen-lua.git vendor/shen-lua
```

luarocks (LuaJIT 5.1 tree) copies **klambda only** on 0.10.x rocks — set
`SHEN_STDLIB_DIR` at the checkout’s `lib/StLib` if you use a rock:

```bash
luarocks --lua-dir="$(brew --prefix luajit)" --lua-version=5.1 install shen 0.10.1-1
export SHEN_STDLIB_DIR=/path/to/shen-lua/lib/StLib
```

`package.path` must let `boot.lua` see `klambda/` and `lib/StLib`. Prefer a
checkout on `package.path`.

On old **aarch64** OpenResty LuaJIT 2.1.0-beta3, kernel boot can SIGSEGV
(shen-lua #43). Set `SHEN_JIT=off`. That is **not** `SHEN_JIT_OPT=off`. Prefer
**LuaJIT 2.1.ROLLING**.

`make browser-shake` writes `openresty/dist/critic/app.lua`. `bridge.lua` loads
that artifact when present (`engine=shaken`); otherwise it boots the full kernel
and loads portable `shen/critic/validate.shen` (no `lua.call`).

`make openresty-test` and `livingdict-resty` preflight **require** shen-lua (or the shaken artifact).
They do not fall back to `forth.validate`. That mirror is only for unit
comparison.

Sidecar caches are forced under `openresty/var/` (`SHEN_KERNEL_CACHE`,
`SHEN_FASL_DIR`) so a warm boot does not drop `.shen-kernel-cache.*` into an
ldeval workspace.

## Commands

```bash
# no nginx (needs ../shen-lua or SHEN_LUA_DIR)
luajit openresty/selftest.lua
make openresty-test

# ldeval + canned config-01 (oracle artifact, Shen preflight, Forth write)
make eval-resty-config-01

# adapter by hand (cwd is the task workspace; runner appends request.json)
export LIVINGDICT_ENVELOPE="$PWD/openresty/examples/config-01.envelope.json"
openresty/bin/livingdict-resty /path/to/request.json

# HTTP host
make openresty-serve
curl -s localhost:8080/health
make think-config-01
```

## HTTP

`GET /` — turn-based web client (static files in `public/`). Same protocol as
[`client/livingdict.py`](../client/livingdict.py).

`GET /health` — `{ ok, shen, critic, workspace, dictionary }` when the worker
booted the kernel.

`POST /think` accepts:

1. `{ "goal": "..." }` — planner writes a Forth program; product workspace is
   `apps/studio` (`$livingdict_workspace`);
2. a plan envelope `{ language, program, artifacts }`;
3. a full ldeval `request.json`;
4. `{ "request": {…}, "envelope": {…} }`.

`POST /think` is one kernel episode. A critic reject is HTTP 200 with
`{ critic: "reject", errors: [...], plan: { artifacts, program, rationale } }`.
400 is invalid JSON, a planner miss, or a trap after Accept. The adapter
`livingdict-resty` still exits 2 on preflight reject.

Never put `XAI_API_KEY` in Lua served to a browser. The planner runs
server-side.

Keep traces, receipts, and `dictionary_dir` **outside** the task workspace when
you POST a full request (see `scripts/think-config-01.sh`). Otherwise they show
up as extra `changed_files`.

`RUN-TESTS` on this path uses `ngx.pipe` so the worker is not stuck in
`io.popen`.

## Resume

`checkpoint.json` is written beside `receipt_path` after a successful preflight
when `resume` is false. A later `resume=true` reloads that envelope and re-runs
the program. `WRITE-FILE` of identical bytes is idempotent (no second
`mutation.applied`).
