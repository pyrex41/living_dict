/** Envelope → preflight → Forth → traces/receipts. */

import { CapabilityError, CapabilityHost } from "./host.js";
import { ForthError, ForthVM } from "./forth.js";
import { boot, validate as criticValidate, bridge } from "./bridge.js";

export class ExecutionError extends Error {
  constructor(code, message, details) {
    super(message);
    this.code = code;
    this.message = message;
    this.details = details || [];
  }
}

function parseStringList(value, label) {
  if (value == null) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new ExecutionError("envelope", `${label} must be an array of strings`);
  }
  return value.slice();
}

function parseNodes(raw) {
  if (raw == null) return null;
  if (!Array.isArray(raw)) {
    throw new ExecutionError("envelope", "envelope.nodes must be an array");
  }
  if (raw.length === 0) return null;
  return raw.map((item, index) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new ExecutionError("envelope", `envelope.nodes[${index}] must be an object`);
    }
    const ident = item.id;
    if (typeof ident !== "string" || !ident.trim()) {
      throw new ExecutionError("envelope", `envelope.nodes[${index}].id must be a string`);
    }
    let program = item.program;
    if (program == null) program = "";
    if (typeof program !== "string") {
      throw new ExecutionError("envelope", `envelope.nodes[${index}].program must be a string`);
    }
    const node = {
      id: ident,
      writes: parseStringList(item.writes, `envelope.nodes[${index}].writes`),
      depends_on: parseStringList(item.depends_on, `envelope.nodes[${index}].depends_on`),
      program,
    };
    if (item.allowed_globs != null) {
      node.allowed_globs = parseStringList(
        item.allowed_globs,
        `envelope.nodes[${index}].allowed_globs`,
      );
    }
    return node;
  });
}

export function parseEnvelope(value) {
  if (!value || typeof value !== "object") throw new ExecutionError("envelope", "envelope must be an object");
  const language = value.language;
  let program = value.program;
  const nodes = parseNodes(value.nodes);
  if (typeof language !== "string" || !language.trim()) {
    throw new ExecutionError("envelope", "envelope.language must be a string");
  }
  if (typeof program !== "string") {
    if (nodes) program = "";
    else throw new ExecutionError("envelope", "envelope.program must be a string");
  }
  const artifacts = value.artifacts || {};
  if (typeof artifacts !== "object" || Array.isArray(artifacts)) {
    throw new ExecutionError("envelope", "envelope.artifacts must be an object");
  }
  const cleaned = {};
  for (const [key, text] of Object.entries(artifacts)) {
    if (typeof key !== "string" || typeof text !== "string") {
      throw new ExecutionError("envelope", "artifact keys and values must be strings");
    }
    cleaned[key] = text;
  }
  const rationale = value.rationale || "";
  if (typeof rationale !== "string") {
    throw new ExecutionError("envelope", "envelope.rationale must be a string");
  }
  const envelope = {
    language: language.trim().toLowerCase(),
    program,
    artifacts: cleaned,
    rationale,
  };
  if (nodes) envelope.nodes = nodes;
  return envelope;
}

export async function runForth(host, envelope, opts = {}) {
  const preflight = opts.preflight !== false;
  if (envelope.language !== "forth" && envelope.language !== "forth-shen") {
    throw new ExecutionError("language", `unsupported envelope language: ${envelope.language}`);
  }
  await host.ready();
  if (preflight) {
    await boot();
    const result = await criticValidate(
      envelope.program,
      host.allowed_effects,
      host.allowed_globs,
      host.forbidden_globs,
      envelope.artifacts,
    );
    if (!result.valid) {
      host.emit("preflight.rejected", {
        effects: result.effects,
        engine: result.engine || bridge.engine,
        errors: result.errors,
      });
      throw new ExecutionError("preflight", "preflight rejected program", result.errors);
    }
  }
  const vm = new ForthVM(host, envelope.artifacts);
  if (opts.seedColon && typeof opts.seedColon === "string" && opts.seedColon.trim()) {
    await vm.interpret(opts.seedColon);
  }
  try {
    await vm.interpret(envelope.program);
  } catch (err) {
    if (err instanceof ForthError) {
      host.emit("execution.trap", { detail: err.message, reason: err.code });
      throw new ExecutionError(err.code, err.message);
    }
    if (err instanceof CapabilityError) {
      host.emit("execution.trap", { detail: err.message, reason: err.code });
      throw new ExecutionError(err.code, err.message);
    }
    throw err;
  }
  return {
    defined: vm.definedNames(),
    program_hash: null,
    stack: vm.stack.slice(),
    stack_depth: vm.stack.length,
    vm,
  };
}

export async function runRequest(host, envelope, opts = {}) {
  const preflight = opts.preflight !== false;
  try {
    const extra = await runForth(host, parseEnvelope(envelope), { preflight, seedColon: opts.seedColon });
    if (!String(envelope.program).toUpperCase().includes("RECEIPT")) {
      await host.receipt({ program_hash: extra.program_hash });
    }
    return { ok: true, critic: bridge.engine, result: extra, receipt: findReceipt(host) };
  } catch (err) {
    const code = err.code || "error";
    const message = err.message || String(err);
    const details = err.details || [];
    host.emit("execution.trap", { detail: message, errors: details, reason: code });
    return {
      ok: false,
      code,
      critic: bridge.engine,
      details,
      error: message,
    };
  }
}

function findReceipt(host) {
  const raw = host.files.get(host.receipt_path || "receipt.json");
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export const DEMO_ENVELOPE = {
  language: "forth",
  program: 'S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE RECEIPT',
  artifacts: {
    "app/config.py": "TIMEOUT = 30\nRETRIES = 2\n",
  },
  rationale: "canned write; RUN-TESTS omitted in the tab",
};

export const FORBIDDEN_ENVELOPE = {
  language: "forth",
  program: 'S" tests/test_public.py" USE-ARTIFACT S" tests/test_public.py" WRITE-FILE',
  artifacts: {
    "tests/test_public.py": "PWNED\n",
  },
  rationale: "must be rejected before Forth mutates",
};
