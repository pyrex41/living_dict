// One-shot elaborator host: loads the yggdrasil-shaken ShenScript artifact
// (browser/dist/elaborate/app.js), reads one JSON request on stdin (the
// flattened manifest produced by LdHost.Elaborate.shen_request/1), calls the
// typed Shen `elaborate`, and prints one JSON derivation. Used by the
// Elixir/Shen conformance test; BEAM's executing elaborator stays in Elixir
// until the shen-erl target is rebuilt.
//   -> {"system":"orders","components":[[name,contract,substrate,[[port,dir,type]],[[k,v]]]],
//       "channels":[[name,from,to,delivery,ordering]],"effects":[[name,owner,protocol,identity,target]],
//       "externals":[...],"invariants":[[id,kind,[about]]],"failures":[...],
//       "profiles":[[name,claims,[[k,v]],[faults]]],"orders":[[dim,[values]]]}
//   <- {"verdict":"accepted","steps":[[rule,subject,ok,detail]],"failed":[...],"obligations":[...]}
import { pathToFileURL } from "node:url";

const artifact = process.argv[2];
const mod = await import(pathToFileURL(artifact).href);
const $ = mod.default;
const elaborate = $.caller("elaborate");

// Shen booleans are the symbols `true` / `false` in ShenScript.
const shenBool = (b) => Symbol.for(b ? "true" : "false");
function name(x) {
  if (typeof x === "symbol") {
    const k = Symbol.keyFor(x) || String(x);
    if (k === "true") return true;
    if (k === "false") return false;
    return k;
  }
  return x;
}
function deep(v) {
  if (Array.isArray(v)) return v.map(deep);
  return name(v);
}

let input = "";
for await (const chunk of process.stdin) input += chunk;
const req = JSON.parse(input);
const raw = await elaborate(
  req.system,
  $.toListTree(req.components),
  $.toListTree(req.channels),
  $.toListTree(req.effects),
  $.toListTree(req.externals),
  $.toListTree(req.invariants),
  $.toListTree(req.failures),
  $.toListTree(req.profiles.map(([n, claims, vec, faults]) => [n, shenBool(claims), vec, faults])),
  $.toListTree(req.orders),
);
const tree = deep($.toArrayTree(raw));
process.stdout.write(
  JSON.stringify({ verdict: tree[0], steps: tree[1], failed: tree[2], obligations: tree[3] }) + "\n",
);
