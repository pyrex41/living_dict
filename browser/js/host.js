/** Capability host: the only I/O a plan may perform. In-memory Map workspace. */

const SKIP_DIR = new Set([".git", "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache"]);

export class CapabilityError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.message = message;
  }
}

export function isspace(ch) {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f" || ch === "\v";
}

export function normalize(path) {
  const abs = typeof path === "string" && path.startsWith("/");
  const acc = [];
  for (const part of String(path).split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (acc.length > 0) acc.pop();
      else if (!abs) acc.push("..");
    } else {
      acc.push(part);
    }
  }
  if (abs) return acc.length === 0 ? "/" : `/${acc.join("/")}`;
  return acc.join("/");
}

export function relativeTo(workspace, path) {
  const ws = normalize(workspace);
  const resolved = path.startsWith("/")
    ? normalize(path)
    : normalize(`${ws}/${path}`);
  if (resolved === ws) return "";
  const prefix = ws.endsWith("/") ? ws : `${ws}/`;
  if (resolved.startsWith(prefix)) return resolved.slice(prefix.length);
  throw new Error(`path escapes workspace: ${path}`);
}

export function fnmatch(name, pattern) {
  const match = (s, p) => {
    let si = 0;
    let pi = 0;
    let starP = -1;
    let starS = -1;
    while (si < s.length) {
      const pc = p[pi];
      if (pc === "*") {
        starP = pi;
        starS = si;
        pi += 1;
      } else if (pc === "?" || pc === s[si]) {
        si += 1;
        pi += 1;
      } else if (starP >= 0) {
        starS += 1;
        si = starS;
        pi = starP + 1;
      } else {
        return false;
      }
    }
    while (p[pi] === "*") pi += 1;
    return pi >= p.length;
  };
  return match(name, pattern);
}

export function matchesAny(path, patterns) {
  if (!patterns) return false;
  for (const p of patterns) {
    if (fnmatch(path, p)) return true;
  }
  return false;
}

export function writeAllowed(rel, allowedGlobs, forbiddenGlobs) {
  if (matchesAny(rel, forbiddenGlobs)) return `forbidden path: ${rel}`;
  if (!matchesAny(rel, allowedGlobs)) return `path outside allowed change set: ${rel}`;
  return null;
}

export async function sha256(data) {
  const text = data ?? "";
  if (globalThis.crypto?.subtle) {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
  }
  const { createHash } = await import("node:crypto");
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function escapeNonAscii(text) {
  // Python json.dumps(ensure_ascii=True) escapes every code unit >= 0x7f;
  // JSON.stringify does not. Match Python so tree hashes agree across bodies.
  return text.replace(/[\u007f-\uffff]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`);
}

export function treeCanonical(files) {
  const keys = Object.keys(files || {}).sort();
  return `{${keys.map((key) => `${escapeNonAscii(JSON.stringify(key))}:${escapeNonAscii(JSON.stringify(files[key]))}`).join(",")}}`;
}

function isoNow() {
  return new Date().toISOString();
}

function pathParts(rel) {
  return String(rel).split("/").filter(Boolean);
}

function hasSkip(rel, skip) {
  return pathParts(rel).some((part) => skip.has(part));
}

export class CapabilityHost {
  constructor(opts = {}) {
    this.files = opts.files instanceof Map ? opts.files : new Map(Object.entries(opts.files || {}));
    this.workspace = opts.workspace || "/workspace";
    this.allowed_effects = [...(opts.allowed_effects || ["read", "write", "exec"])];
    this.allowed_globs = [...(opts.allowed_globs || ["**"])];
    this.forbidden_globs = [...(opts.forbidden_globs || [])];
    this.trace = opts.trace || [];
    this.receipt_path = opts.receipt_path || "receipt.json";
    this.run_id = String(opts.run_id || "");
    this.task_id = String(opts.task_id || "");
    this._allowed_set = new Set(this.allowed_effects);
    this._effects_used = new Set();
    this._before = null;
    this._objects = opts.objects instanceof Map ? opts.objects : new Map();
    this._tree_before = null;
    this.runTestsHook = opts.runTestsHook || null;
    this.onChange = opts.onChange || null;
  }

  async intern(data) {
    const digest = await sha256(data);
    if (!this._objects.has(digest)) this._objects.set(digest, data ?? "");
    return digest;
  }

  async internTree(files) {
    return this.intern(treeCanonical(files));
  }

  async internSnapshot(files) {
    for (const [rel, text] of this.files.entries()) {
      if (files[rel] !== undefined) await this.intern(text);
    }
    return this.internTree(files);
  }

  async ready() {
    if (this._before === null) {
      this._before = await this.snapshot();
      this._tree_before = await this.internSnapshot(this._before);
    }
    return this;
  }

  emit(type, data) {
    this.trace.push({ type, timestamp: isoNow(), data: data || {} });
  }

  _tool(name, data) {
    this.emit("tool.call", { tool: name, ...(data || {}) });
  }

  _requireEffect(effect) {
    if (!this._allowed_set.has(effect)) {
      this.emit("execution.trap", { effect, reason: "effect" });
      throw new CapabilityError("effect", `effect not allowed: ${effect}`);
    }
    this._effects_used.add(effect);
  }

  _rel(path) {
    try {
      return relativeTo(this.workspace, path);
    } catch (err) {
      const msg = err instanceof Error ? err.message : `path escapes workspace: ${path}`;
      this.emit("execution.trap", { detail: msg, reason: "path" });
      throw new CapabilityError("path", msg);
    }
  }

  _notify() {
    if (this.onChange) this.onChange(this);
  }

  existsFile(rel) {
    return this.files.has(rel);
  }

  async read_file(path) {
    this._requireEffect("read");
    const rel = this._rel(path);
    if (!this.files.has(rel)) {
      this.emit("execution.trap", { path: rel || ".", reason: "missing_file" });
      throw new CapabilityError("missing_file", `missing file: ${rel || "."}`);
    }
    this._tool("READ-FILE", { path: rel });
    return this.files.get(rel);
  }

  async list_dir(path = ".") {
    this._requireEffect("read");
    const rel = path === "" || path === "." ? "" : this._rel(path);
    const prefix = rel === "" ? "" : `${rel}/`;
    const children = new Set();
    for (const key of this.files.keys()) {
      if (rel !== "" && key !== rel && !key.startsWith(prefix)) continue;
      if (key === rel) continue;
      const rest = rel === "" ? key : key.slice(prefix.length);
      const head = rest.split("/")[0];
      const childRel = rel === "" ? head : `${rel}/${head}`;
      const isDir = rest.includes("/");
      children.add(isDir ? `${childRel}/` : childRel);
    }
    if (rel !== "" && children.size === 0 && !this.files.has(rel)) {
      const any = [...this.files.keys()].some((k) => k.startsWith(prefix) || k === rel);
      if (!any) {
        this.emit("execution.trap", { path: rel || ".", reason: "missing_file" });
        throw new CapabilityError("missing_file", `missing directory: ${rel || "."}`);
      }
    }
    this._tool("LIST-DIR", { path: rel || "." });
    return [...children].sort();
  }

  async search(query) {
    this._requireEffect("read");
    this._tool("SEARCH", { query });
    const hits = [];
    if (query === "") return hits;
    for (const [rel, text] of [...this.files.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
      if (hasSkip(rel, SKIP_DIR) || text.includes("\0")) continue;
      const lines = text.split(/\r?\n/);
      if (lines.length && lines[lines.length - 1] === "") lines.pop();
      lines.forEach((line, i) => {
        if (line.includes(query)) hits.push({ path: rel, line: i + 1, text: line });
      });
    }
    return hits;
  }

  async write_file(content, path) {
    this._requireEffect("write");
    const rel = this._rel(path);
    const reason = writeAllowed(rel, this.allowed_globs, this.forbidden_globs);
    if (reason) {
      this._tool("WRITE-FILE", { denied: true, path: rel });
      this.emit("execution.trap", { detail: reason, path: rel, reason: "policy" });
      throw new CapabilityError("policy", reason);
    }
    if (typeof content !== "string") {
      throw new CapabilityError("type", "WRITE-FILE expected string content");
    }
    const digest = await this.intern(content);
    const rec = { bytes: content.length, path: rel, sha256: digest };
    if (this.files.has(rel) && this.files.get(rel) === content) {
      this._tool("WRITE-FILE", { bytes: content.length, idempotent: true, path: rel });
      return rec;
    }
    this.files.set(rel, content);
    this._tool("WRITE-FILE", { bytes: content.length, path: rel });
    this.emit("mutation.applied", { path: rel, sha256: digest });
    this._notify();
    return rec;
  }

  async run_tests() {
    this._requireEffect("exec");
    this._tool("RUN-TESTS", { command: "in-tab assertion hook" });
    if (typeof this.runTestsHook === "function") {
      return this.runTestsHook(this);
    }
    return {
      passed: true,
      returncode: 0,
      timed_out: false,
      skipped: true,
      stdout: "RUN-TESTS omitted in the tab (no python -m unittest)",
      stderr: "",
    };
  }

  async snapshot() {
    const values = {};
    for (const [rel, text] of this.files.entries()) {
      if (hasSkip(rel, SKIP_DIR) || rel.endsWith(".pyc") || rel.endsWith(".pyo")) continue;
      values[rel] = await sha256(text);
    }
    return values;
  }

  changedFiles(before, after) {
    const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
    return [...keys].filter((k) => before[k] !== after[k]).sort();
  }

  async workspaceDigest(files) {
    const keys = Object.keys(files).sort();
    let chunks = "";
    for (const rel of keys) chunks += `${rel}\0${files[rel]}\n`;
    return sha256(chunks);
  }

  async receipt(extra) {
    await this.ready();
    const after = await this.snapshot();
    const treeAfter = await this.internSnapshot(after);
    const changed = this.changedFiles(this._before, after);
    const messages = [];
    for (const item of changed) {
      if (writeAllowed(item, this.allowed_globs, this.forbidden_globs)) {
        messages.push(`path outside policy after the fact: ${item}`);
      }
    }
    const payload = {
      protocol_version: "1.0",
      changed_files: changed,
      effects_used: [...this._effects_used].sort(),
      policy_violations: messages,
      run_id: this.run_id,
      success: messages.length === 0,
      task_id: this.task_id,
      workspace_after: await this.workspaceDigest(after),
      workspace_before: await this.workspaceDigest(this._before),
      tree_after: treeAfter,
      tree_before: this._tree_before,
      ...(extra || {}),
    };
    const target = this.receipt_path || "receipt.json";
    this.files.set(target, `${JSON.stringify(payload, null, 2)}\n`);
    this._tool("RECEIPT", { changed_files: changed, path: target });
    this._notify();
    return payload;
  }

  tree() {
    return [...this.files.keys()].sort();
  }
}

const SOUL_KEY = "livingdict.soul";

export function defaultFiles() {
  return {
    "README.md": "Living Dictionary workspace. Forth runs; Shen admits or rejects.\n",
    "app/config.py": "TIMEOUT = 10\nRETRIES = 1\n",
  };
}

export function loadSoul() {
  if (typeof localStorage === "undefined") return null;
  try {
    const raw = localStorage.getItem(SOUL_KEY);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (!data || typeof data !== "object") return null;
    return {
      files: data.files && typeof data.files === "object" ? data.files : {},
      colonSource: typeof data.colonSource === "string" ? data.colonSource : "",
    };
  } catch {
    return null;
  }
}

export function saveSoul(files, colonSource) {
  if (typeof localStorage === "undefined") return;
  const obj = {};
  for (const [k, v] of files instanceof Map ? files.entries() : Object.entries(files)) obj[k] = v;
  localStorage.setItem(SOUL_KEY, JSON.stringify({ files: obj, colonSource: colonSource || "" }));
}

export function clearSoul() {
  if (typeof localStorage === "undefined") return;
  localStorage.removeItem(SOUL_KEY);
}
