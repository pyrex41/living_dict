# Browser host

Same machine as OpenResty: Forth executes, Shen only admits or rejects.
Vanilla JS. No bundler, no React/Vue/Svelte/Elm, no planner, no `XAI_API_KEY`.

## Layout

| Path | Role |
|---|---|
| `index.html` | one page |
| `css/app.css` | small machine, not a dashboard |
| `js/host.js` | six words; in-memory Map (localStorage soul) |
| `js/forth.js` | hosted Forth + `USE-ARTIFACT` |
| `js/bridge.js` | boot shaken critic; call `validate` |
| `js/agent.js` | envelope → preflight → Forth |
| `js/ui.js` | REPL, stack, dictionary, files, critic |
| `shen/` | copies of portable critic sources |
| `dist/` | generated; `make browser-shake` rebuilds |
| `test/node-selftest.mjs` | SQUARE, artifact write, gated forbidden write |

`RUN-TESTS` cannot spawn `python -m unittest` in the tab. The demo envelope omits it. An optional in-tab `runTestsHook` may be attached on the host.

## Shake the critic

Needs `ratatoskr` on `PATH` (or `$HOME/go/bin/ratatoskr`) and a stage-1 Shen host.
`make browser-shake` uses `node ../ShenScript/bin/shen.js` when that sibling exists
(`shen-cl` default heap OOMs on this program). Override with `$RATATOSKR_HOST`.
Sibling `../ShenScript` and `../shen-lua` provide stage-2 builders.

```bash
# from the repo root
make browser-shake

# exact commands (BROWSER.md). Add --host if the default shen-cl heap is too small:
ratatoskr build shen/critic/validate.shen browser/dist/critic --target js --web \
  --host "node ../ShenScript/bin/shen.js"
ratatoskr build shen/critic/validate.shen openresty/dist/critic --target lua \
  --host "node ../ShenScript/bin/shen.js"

# deploy-path parity (Bifrost; missing toolchains SKIP)
# RATATOSKR_HOST is the stage-1 shaker; bifrost --shake does not pass --web.
RATATOSKR_HOST="node ../ShenScript/bin/shen.js" \
  bifrost --shake --suite bifrost.suite.json --impls shen-lua,ShenScript
```

`--web` writes `browser/dist/critic/app.js` (browser-safe ES module). Call shape:

```js
import $ from './dist/critic/app.js';
const result = await $.caller('validate')(program, effects, allowed, forbidden, keys);
```

`needs-eval` must be `false` on `browser/dist/critic/ratatoskr.manifest.txt`. `bifrost build` does not forward `--web`; use `ratatoskr` for the browser module.

`dist/` is gitignored. Rebuild with `make browser-shake`.

## Run

```bash
make browser-test          # node browser/test/node-selftest.mjs
make browser-serve         # python3 -m http.server in browser/
```

Then open http://127.0.0.1:8000/. Without a shaken critic the page uses a JS mirror of the same Accept/Reject rules so the host still works; the live mind is the shaken Shen module when `dist/critic/app.js` exists.
