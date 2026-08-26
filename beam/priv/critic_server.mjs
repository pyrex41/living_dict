// Persistent critic server: loads the yggdrasil-shaken ShenScript critic
// (browser/dist/critic/app.js) and answers JSONL validate requests on
// stdin. Fallback engine for the BEAM host while luerl lacks goto support
// (the Lua artifact's embedded TCO chunks) and until the shen-erl
// yggdrasil target lands. Protocol:
//   -> {"id":1,"program":"...","effects":[],"globs":[],"forbidden":[],"artifacts":[]}
//   <- {"id":1,"tag":"accept","depth":0,"effects":[]}
//   <- {"id":1,"tag":"reject","errors":[...],"depth":0,"effects":[]}
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const artifact = process.argv[2];
const mod = await import(pathToFileURL(artifact).href);
const $ = mod.default;
const validate = $.caller("validate");

function tagName(x) {
  if (typeof x === "symbol") return Symbol.keyFor(x) || String(x);
  return String(x);
}

function flat(v) {
  if (v == null) return [];
  if (typeof v === "string") return [v];
  if (Array.isArray(v)) return v.map((x) => (typeof x === "string" ? x : tagName(x)));
  return [String(v)];
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
process.stdout.write(JSON.stringify({ ready: true }) + "\n");

for await (const line of rl) {
  if (!line.trim()) continue;
  let req;
  try {
    req = JSON.parse(line);
  } catch {
    continue;
  }
  let out;
  try {
    const raw = await validate(
      req.program,
      $.toListTree(req.effects),
      $.toListTree(req.globs),
      $.toListTree(req.forbidden),
      $.toListTree(req.artifacts),
    );
    const tree = $.toArrayTree(raw);
    const tag = Array.isArray(tree) && tree.length ? tagName(tree[0]) : "";
    if (tag === "accept") {
      out = { tag: "accept", depth: Number(tree[1]) || 0, effects: flat(tree[2]) };
    } else if (tag === "reject") {
      out = { tag: "reject", errors: flat(tree[1]), depth: Number(tree[2]) || 0, effects: flat(tree[3]) };
    } else {
      out = { tag: "error", message: "unexpected validate result" };
    }
  } catch (err) {
    out = { tag: "error", message: err && err.message ? err.message : String(err) };
  }
  out.id = req.id;
  process.stdout.write(JSON.stringify(out) + "\n");
}
