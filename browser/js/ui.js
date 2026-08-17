/** REPL, stack, dictionary, files, critic pane. */

import {
  CapabilityHost,
  clearSoul,
  defaultFiles,
  loadSoul,
  saveSoul,
} from "./host.js";
import { ForthError, ForthVM } from "./forth.js";
import { boot, bridge } from "./bridge.js";
import { DEMO_ENVELOPE, FORBIDDEN_ENVELOPE, parseEnvelope, runRequest } from "./agent.js";

const $ = (id) => document.getElementById(id);

let host;
let replVm;
let colonSource = "";

function makeHost(files) {
  const h = new CapabilityHost({
    files,
    workspace: "/workspace",
    allowed_effects: ["read", "write", "exec"],
    allowed_globs: ["**"],
    forbidden_globs: ["tests/**", "secrets.env"],
    run_id: "tab",
    task_id: "browser",
    onChange: persist,
  });
  return h;
}

function persist() {
  saveSoul(host.files, colonSource);
  render();
}

function resetSoul() {
  clearSoul();
  colonSource = "";
  host = makeHost(defaultFiles());
  replVm = new ForthVM(host, {});
  persist();
}

async function restore() {
  const soul = loadSoul();
  const files = soul && soul.files && Object.keys(soul.files).length ? soul.files : defaultFiles();
  colonSource = (soul && soul.colonSource) || "";
  host = makeHost(files);
  await host.ready();
  replVm = new ForthVM(host, {});
  if (colonSource.trim()) {
    try {
      await replVm.interpret(colonSource);
    } catch {
      colonSource = "";
    }
  }
}

function setStamp(text, kind) {
  const el = $("stamp");
  el.textContent = text;
  el.dataset.kind = kind || "";
}

function render() {
  $("stack").textContent = replVm.stack.length
    ? replVm.stack.map((v) => show(v)).join("\n")
    : "∅";
  $("dict").textContent = replVm.definedNames().join("\n") || "—";
  $("files").textContent = host.tree().join("\n") || "—";
  $("critic-engine").textContent = bridge.engine;
}

function show(value) {
  if (typeof value === "string") return JSON.stringify(value);
  if (value && typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return String(value);
    }
  }
  return String(value);
}

function paintCritic(result) {
  const pane = $("critic");
  if (!result) {
    pane.textContent = "idle";
    pane.dataset.kind = "";
    return;
  }
  if (result.valid) {
    pane.dataset.kind = "accept";
    pane.textContent = `ACCEPT  engine=${result.engine}\neffects: ${(result.effects || []).join(", ") || "—"}`;
  } else {
    pane.dataset.kind = "reject";
    pane.textContent = `REJECT  engine=${result.engine}\n${(result.errors || []).join("\n")}`;
  }
}

function paintTrace(events) {
  $("trace").textContent = events.map((e) => `${e.type}${e.data && e.data.tool ? ` ${e.data.tool}` : ""}`).join("\n") || "—";
}

async function runRepl() {
  const src = $("repl").value;
  if (!src.trim()) return;
  try {
    await replVm.interpret(src);
    if (src.includes(":")) {
      colonSource = `${colonSource.trim()}\n${src}`.trim() + "\n";
      persist();
    }
    setStamp("OK", "ok");
    $("repl-err").textContent = "";
  } catch (err) {
    const msg = err instanceof ForthError ? `${err.code}: ${err.message}` : String(err);
    $("repl-err").textContent = msg;
    setStamp("TRAP", "bad");
  }
  render();
}

async function runEnvelope(raw) {
  let envelope;
  try {
    envelope = parseEnvelope(typeof raw === "string" ? JSON.parse(raw) : raw);
  } catch (err) {
    $("critic").textContent = err.message || String(err);
    $("critic").dataset.kind = "reject";
    setStamp("BAD ENVELOPE", "bad");
    return;
  }
  const result = await runRequest(host, envelope, { preflight: true, seedColon: colonSource });
  paintTrace(host.trace);
  if (result.ok) {
    if (result.result && result.result.vm) replVm = result.result.vm;
    paintCritic({ valid: true, engine: result.critic, effects: [], errors: [] });
    setStamp("RAN", "ok");
    $("mind").textContent = result.receipt ? JSON.stringify(result.receipt, null, 2) : "ok";
  } else {
    const rejected = host.trace.filter((e) => e.type === "preflight.rejected").pop();
    paintCritic({
      valid: false,
      engine: result.critic,
      errors: result.details && result.details.length ? result.details : [result.error],
    });
    if (rejected) paintCritic({ valid: false, engine: rejected.data.engine, errors: rejected.data.errors });
    setStamp(result.code === "preflight" ? "REJECT" : "TRAP", "bad");
    $("mind").textContent = result.error || "";
  }
  render();
}

async function main() {
  await restore();
  const ok = await boot();
  $("health").textContent = ok
    ? `critic ${bridge.engine}  (shaken ShenScript)`
    : `critic js-mirror  (shake the critic: make browser-shake)`;
  $("health").className = `health ${ok ? "ok" : "warn"}`;
  $("goal").value = JSON.stringify(DEMO_ENVELOPE, null, 2);
  render();
  paintCritic(null);

  $("run-repl").addEventListener("click", runRepl);
  $("repl").addEventListener("keydown", (ev) => {
    if ((ev.metaKey || ev.ctrlKey) && ev.key === "Enter") {
      ev.preventDefault();
      runRepl();
    }
  });
  $("run-goal").addEventListener("click", () => runEnvelope($("goal").value));
  $("load-demo").addEventListener("click", () => {
    $("goal").value = JSON.stringify(DEMO_ENVELOPE, null, 2);
  });
  $("load-forbidden").addEventListener("click", () => {
    $("goal").value = JSON.stringify(FORBIDDEN_ENVELOPE, null, 2);
  });
  $("reset").addEventListener("click", () => {
    resetSoul();
    paintCritic(null);
    paintTrace([]);
    $("mind").textContent = "wiped";
    setStamp("RESET", "");
  });
}

main();
