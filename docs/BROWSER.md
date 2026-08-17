# Browser host (ShenScript + vanilla JS)

Same machine as OpenResty: Forth executes, Shen only admits or rejects.
The tab is the third body. This is the plan the `shenscript-browser`
workflow implements.

## Stack choice

| Option | Verdict |
|---|---|
| **Vanilla JS** (no framework) | **Use this.** Host, Forth, REPL, and panes are I/O and DOM. A framework adds nothing the ABI needs. |
| Elm | Ports to ShenScript + Forth + OPFS would be most of the app. Typed UI, untyped soul. Skip. |
| Whole app in ShenScript | `--web` forbids `eval` / `(tc +)` / `load`. A REPL, file host, and Forth VM cannot live in an eval-stripped artifact. Shen stays the critic. |

WAForth is optional story, not the V0 body. A JS Forth matching
`harness/src/livingdict/forth.py` / `openresty/lua/forth.lua` is enough.

## Dual-end critic (this is the hard part)

OpenResty’s `preflight.shen` currently `lua.call`s the Forth tokenizer and
loads under a full kernel with `(tc +)` on `contracts.shen`. That **cannot**
be shaken for the browser:

- `ratatoskr build … --target js --web` requires `needs-eval=false`.
- `(tc +)`, `eval`, `load`, `declare` (as runtime), and `lua.call` flip
  `needs-eval` or pin the critic to one host.

So the workflow must **split the critic**:

```
shen/critic/                 portable, eval-free, no lua.call / js.call
  contracts.shen             write-ok?, stack contracts (already close)
  validate.shen              named validate / validate-tokens
  tokenise.shen              Forth tokeniser in portable Shen
                             OR hosts pass a token list and skip this file
```

Hosts keep effectful glue:

| Host | Loads |
|---|---|
| OpenResty | shaken **lua** artifact *or* full kernel + same `.shen` |
| Browser | shaken **js --web** ES module (`import $ from './critic.js'`) |
| Python | may keep `livingdict.preflight` as the lab mirror |

One shake graph, two artifacts:

```bash
# deploy-path parity (Bifrost drives Ratatoskr)
bifrost --shake --suite bifrost.suite.json --impls shen-lua,ShenScript

# artifacts (Ratatoskr; bifrost build does not forward --web today)
ratatoskr build shen/critic/validate.shen browser/dist/critic --target js --web
ratatoskr build shen/critic/validate.shen openresty/dist/critic --target lua
```

`--web` emits a browser-safe ES module: no `node:fs`, no `process`. Call
shape is `import $ from './critic.js'` then `$.caller('validate')(…)`.
Confirm against the current Ratatoskr / ShenScript builder; do not invent
interop.

If `bifrost build FILE OUT --target js` grows a `--web` flag, switch to it.
Until then call `ratatoskr` for the JS web module and still use
`bifrost --shake` for agreement.

## Browser layout to create

```
browser/
  README.md
  index.html              one page, no bundler required for the UI
  css/app.css
  js/host.js              six words; in-memory Map workspace (OPFS later)
  js/forth.js             hosted Forth + USE-ARTIFACT
  js/bridge.js            boot shaken critic once; call validate
  js/agent.js             envelope → preflight → Forth → traces/receipts
  js/ui.js                REPL, stack, dictionary, files, mind/trace
  shen/                   copies or links to portable critic sources
  dist/                   generated; gitignore except a committed
                          shaken critic if the implementer can build it
  test/node-selftest.mjs  node: assert SQUARE, artifact write,
                          Shen-gated forbidden write never mutates
```

`RUN-TESTS` in the tab cannot spawn `python -m unittest`. V0: omit it from
the demo envelope, or run a tiny in-browser assertion hook. Do not pretend
to shell out.

Soul: `localStorage` or OPFS for workspace + colon-word source. Reset wipes
it. No `XAI_API_KEY` in the page. No planner.

UI: Forth REPL, goal box that runs a canned or pasted envelope, dictionary
list, stack, file tree, critic pane (accept/reject + errors). Dead simple.
Look like a small machine, not a dashboard template.

## OpenResty follow-up in the same workflow

After the portable critic exists:

1. Point `openresty/lua/bridge.lua` at the shaken lua artifact when present,
   else keep full-kernel load for development.
2. Drop `lua.call` tokenise from the live critic path.
3. `make openresty-test` still proves forbidden `WRITE-FILE` never mutates
   and `engine` is Shen (or `shaken`).

Do not rewrite the Python eval lab.

## Verification the workflow must fail-closed on

- Same six words, same envelope, same reject reasons as Python/Lua.
- Named `validate` runs **before** Forth mutates; trace has no `tool.call`
  on a forbidden write.
- `needs-eval=false` on the shaken manifest (otherwise `--web` is illegal).
- `bifrost --shake` (or `ratatoskr parity`) agrees on the critic fixture
  across shen-lua and ShenScript when those ports exist; missing tools are
  reported, not faked as pass.
- `node browser/test/node-selftest.mjs` (or equivalent) exits 0.
- No React/Vue/Svelte/Elm. No WAForth unless labeled optional.

## Commands (target)

```bash
make browser-test
make browser-shake          # ratatoskr js --web + lua
make browser-serve          # python3 -m http.server in browser/
bifrost --shake --suite bifrost.suite.json --impls shen-lua,ShenScript
```
