#!/usr/bin/env node
// node browser/test/node-selftest.mjs
// Forth 5 SQUARE, artifact write, Shen-gated forbidden write never mutates.

import assert from "node:assert/strict";
import { CapabilityHost, sha256, treeCanonical } from "../js/host.js";
import { ForthVM } from "../js/forth.js";
import { boot, bridge, validate } from "../js/bridge.js";
import { FORBIDDEN_ENVELOPE, parseEnvelope, runRequest } from "../js/agent.js";

let fail = 0;
function check(label, cond, detail) {
  if (cond) {
    console.log(`  ok  ${label}`);
  } else {
    fail += 1;
    console.log(`  FAIL ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

// Cross-body parity: must equal Python's json.dumps(sort_keys, ensure_ascii).
const canon = treeCanonical({ "café.txt": "aa", "a.py": "bb" });
check(
  "treeCanonical matches Python ensure_ascii",
  canon === '{"a.py":"bb","caf\\u00e9.txt":"aa"}',
  canon,
);

const empty = await sha256("");
check(
  "sha256 empty",
  empty === "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  empty,
);

console.log("== Forth 5 SQUARE ==");
{
  const h = new CapabilityHost({
    files: {},
    allowed_effects: ["read", "write", "exec"],
    allowed_globs: ["app/*.py"],
    forbidden_globs: ["tests/**"],
  });
  await h.ready();
  const vm = new ForthVM(h);
  await vm.interpret("3 4 +");
  check("3 4 +", vm.stack[0] === 7, vm.stack[0]);
  vm.stack = [];
  await vm.interpret(": SQUARE DUP * ; 5 SQUARE");
  check("5 SQUARE", vm.stack[0] === 25, vm.stack[0]);
  vm.stack = [];
  await vm.interpret("0 IF 99 ELSE 42 THEN");
  check("IF ELSE THEN", vm.stack[0] === 42, vm.stack[0]);
  vm.stack = [];
  await vm.interpret('S" hello world" \\ ignored\n( also ignored )');
  check('S" string + comments', vm.stack[0] === "hello world", vm.stack[0]);
}

console.log("== artifact write ==");
{
  const h = new CapabilityHost({
    files: { "app/config.py": "OLD\n" },
    allowed_effects: ["read", "write", "exec"],
    allowed_globs: ["app/*.py", "src/*.py"],
    forbidden_globs: ["tests/**"],
  });
  await h.ready();
  const vm = new ForthVM(h, { "app/config.py": "NEW\n" });
  await vm.interpret('S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE');
  check("wrote NEW", h.files.get("app/config.py") === "NEW\n");
  check("receipt path", vm.stack[0] && vm.stack[0].path === "app/config.py");
  const again = await h.write_file("NEW\n", "app/config.py");
  check("idempotent sha", again.sha256 === (await sha256("NEW\n")));
}

console.log("== boot critic ==");
const hasShen = await boot();
check("bridge booted", bridge.booted);
if (hasShen) {
  check("bridge.engine shen", bridge.engine === "shen", bridge.engine);
} else {
  check("js mirror fallback", bridge.engine === "js", bridge.engine);
  console.log("  note: no shaken critic at browser/dist/critic/app.js (make browser-shake)");
}

console.log("== validate (stack / effects / globs / artifacts) ==");
{
  const accepted = await validate(
    'S" src/records.py" USE-ARTIFACT S" src/records.py" WRITE-FILE RUN-TESTS RECEIPT',
    ["read", "write", "exec"],
    ["src/records.py"],
    [],
    { "src/records.py": "ok\n" },
  );
  check("accepts straight-line", accepted.valid === true, (accepted.errors || []).join("; "));
  check("write effect", accepted.effects.includes("write"));
  const rejected = await validate(
    'DROP MYSTERY S" tests/test_public.py" WRITE-FILE',
    ["read", "write", "exec"],
    ["app/config.py"],
    ["tests/**"],
    {},
  );
  check("rejects", rejected.valid === false);
  const joined = (rejected.errors || []).join(" ");
  check("underflow", joined.includes("underflow"), joined);
  check("unknown", joined.includes("unknown word"), joined);
  check("forbidden", joined.includes("forbidden"), joined);
  const missing = await validate(
    'S" app/config.py" USE-ARTIFACT',
    ["read", "write", "exec"],
    ["**"],
    [],
    {},
  );
  check("missing artifact", missing.valid === false);
  check("no artifact text", (missing.errors || []).join(" ").includes("no artifact"));
}

console.log("== gated forbidden write never mutates ==");
{
  const h = new CapabilityHost({
    files: { "tests/test_public.py": "SAFE\n" },
    allowed_effects: ["read", "write", "exec"],
    allowed_globs: ["app/config.py"],
    forbidden_globs: ["tests/**"],
    run_id: "selftest",
    task_id: "selftest",
  });
  await h.ready();
  const envelope = parseEnvelope(FORBIDDEN_ENVELOPE);
  const result = await runRequest(h, envelope, { preflight: true });
  check("adapter not ok", result.ok === false);
  check("file unchanged", h.files.get("tests/test_public.py") === "SAFE\n");
  const types = h.trace.map((e) => e.type);
  check("preflight.rejected in trace", types.includes("preflight.rejected"), types.join(","));
  check("no tool.call (host I/O never ran)", !types.includes("tool.call"), types.join(","));
  const dumped = JSON.stringify(h.trace);
  check("no WRITE-FILE tool", !dumped.includes("WRITE-FILE"), dumped);
  check("no mutation.applied", !types.includes("mutation.applied"), types.join(","));
  if (hasShen) {
    const ev = h.trace.find((e) => e.type === "preflight.rejected");
    check("trace engine is shen", ev && ev.data.engine === "shen", ev && ev.data.engine);
  }
}

if (fail === 0) {
  console.log("\nOK — browser node selftest passed");
  process.exit(0);
}
console.log(`\n${fail} check(s) FAILED`);
process.exit(1);
