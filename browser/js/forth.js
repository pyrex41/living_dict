/** Tiny hosted Forth. Control flow and tool order, not a payload language. */

import { CapabilityError, isspace, relativeTo, writeAllowed } from "./host.js";

export class ForthError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.message = message;
  }
}

export function tokenize(source) {
  const tokens = [];
  let i = 0;
  const n = source.length;
  while (i < n) {
    const ch = source[i];
    if (isspace(ch)) {
      i += 1;
      continue;
    }
    if (ch === "\\" && (i === 0 || isspace(source[i - 1]))) {
      while (i < n && source[i] !== "\n") i += 1;
      continue;
    }
    if (ch === "(" && (i + 1 === n || isspace(source[i + 1]))) {
      i += 1;
      while (i < n && source[i] !== ")") i += 1;
      if (i < n) i += 1;
      continue;
    }
    if (source.startsWith('S"', i) || source.startsWith('s"', i)) {
      i += 2;
      if (i < n && source[i] === " ") i += 1;
      const start = i;
      while (i < n && source[i] !== '"') i += 1;
      if (i >= n) throw new ForthError("syntax", 'unterminated S" string');
      tokens.push({ kind: "string", value: source.slice(start, i), index: tokens.length });
      i += 1;
      continue;
    }
    const start = i;
    while (i < n && !isspace(source[i])) i += 1;
    const raw = source.slice(start, i);
    if (isNumber(raw)) tokens.push({ kind: "number", value: parseInt(raw, 10), index: tokens.length });
    else tokens.push({ kind: "word", value: raw, index: tokens.length });
  }
  return tokens;
}

function isNumber(raw) {
  if (raw === "+" || raw === "-") return false;
  if (raw.startsWith("-")) return raw.length > 1 && /^[0-9]+$/.test(raw.slice(1));
  return /^[0-9]+$/.test(raw);
}

export const HOST_DICTIONARY = {
  "READ-FILE": { inputs: 1, outputs: 1, effects: ["read"] },
  "LIST-DIR": { inputs: 1, outputs: 1, effects: ["read"] },
  SEARCH: { inputs: 1, outputs: 1, effects: ["read"] },
  "WRITE-FILE": { inputs: 2, outputs: 1, effects: ["write"] },
  "RUN-TESTS": { inputs: 0, outputs: 1, effects: ["exec"] },
  "RUN-GATES": { inputs: 0, outputs: 1, effects: ["exec"] },
  RECEIPT: { inputs: 0, outputs: 1, effects: [] },
  "USE-ARTIFACT": { inputs: 1, outputs: 1, effects: ["read"] },
  DUP: { inputs: 1, outputs: 2, effects: [] },
  DROP: { inputs: 1, outputs: 0, effects: [] },
  SWAP: { inputs: 2, outputs: 2, effects: [] },
  OVER: { inputs: 2, outputs: 3, effects: [] },
  "+": { inputs: 2, outputs: 1, effects: [] },
  "-": { inputs: 2, outputs: 1, effects: [] },
  "*": { inputs: 2, outputs: 1, effects: [] },
  IF: { inputs: 1, outputs: 0, effects: [] },
  ELSE: { inputs: 0, outputs: 0, effects: [] },
  THEN: { inputs: 0, outputs: 0, effects: [] },
};

function literalBefore(tokens, wordIndex) {
  if (wordIndex <= 0) return null;
  const prev = tokens[wordIndex - 1];
  return prev.kind === "string" ? String(prev.value) : null;
}

function skipColon(tokens, i, errors) {
  if (i + 1 >= tokens.length || tokens[i + 1].kind !== "word") {
    errors.push(`token ${tokens[i].index}: expected name after :`);
    return [i + 1, null];
  }
  const defined = String(tokens[i + 1].value).toUpperCase();
  let j = i + 2;
  while (j < tokens.length) {
    const token = tokens[j];
    if (token.kind === "word" && String(token.value).toUpperCase() === ";") return [j + 1, defined];
    if (token.kind === "word" && String(token.value).toUpperCase() === ":") {
      errors.push(`token ${token.index}: nested colon definitions are not supported`);
      return [j + 1, null];
    }
    j += 1;
  }
  errors.push("unterminated colon definition");
  return [tokens.length, null];
}

const DUMMY_ROOT = "/workspace";

export function forthValidate(program, allowedEffects, allowedGlobs, forbiddenGlobs, artifacts) {
  const errors = [];
  let tokens;
  try {
    tokens = tokenize(program);
  } catch (err) {
    return { valid: false, errors: [err.message || String(err)], final_depth: 0, effects: [] };
  }
  artifacts = artifacts || {};
  allowedGlobs = allowedGlobs && allowedGlobs.length ? allowedGlobs : ["**"];
  forbiddenGlobs = forbiddenGlobs || [];
  const allowedSet = new Set(allowedEffects || []);
  const words = { ...HOST_DICTIONARY };
  const effects = new Set();
  let depth = 0;
  let i = 0;
  while (i < tokens.length) {
    const token = tokens[i];
    if (token.kind === "string" || token.kind === "number") {
      depth += 1;
      i += 1;
      continue;
    }
    const name = String(token.value).toUpperCase();
    if (name === ":") {
      const [next, defined] = skipColon(tokens, i, errors);
      i = next;
      if (defined) words[defined] = { inputs: 0, outputs: 0, effects: [] };
      continue;
    }
    const contract = words[name];
    if (!contract) {
      errors.push(`token ${token.index}: unknown word ${token.value}`);
      i += 1;
      continue;
    }
    if (depth < contract.inputs) {
      errors.push(`token ${token.index}: stack underflow at ${name}`);
      depth = 0;
    } else {
      depth -= contract.inputs;
    }
    depth += contract.outputs;
    for (const e of contract.effects) effects.add(e);
    if (name === "WRITE-FILE") {
      const path = literalBefore(tokens, i);
      if (path !== null) {
        try {
          const rel = relativeTo(DUMMY_ROOT, path);
          const reason = writeAllowed(rel, allowedGlobs, forbiddenGlobs);
          if (reason) errors.push(`token ${token.index}: ${reason}`);
        } catch (err) {
          errors.push(`token ${token.index}: ${err.message || err}`);
        }
      }
    }
    if (name === "USE-ARTIFACT") {
      const path = literalBefore(tokens, i);
      if (path !== null && artifacts[path] === undefined) {
        errors.push(`token ${token.index}: no artifact: ${path}`);
      }
    }
    i += 1;
  }
  const excess = [...effects].filter((e) => !allowedSet.has(e)).sort();
  if (excess.length) errors.push(`effects not allowed: ${excess.join(", ")}`);
  return {
    valid: errors.length === 0,
    errors,
    final_depth: depth,
    effects: [...effects].sort(),
  };
}

function matchIf(tokens, start) {
  let depth = 0;
  let elseAt = null;
  for (let i = start; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.kind !== "word") continue;
    const word = String(token.value).toUpperCase();
    if (word === "IF") depth += 1;
    else if (word === "ELSE" && depth === 1) elseAt = i;
    else if (word === "THEN") {
      if (depth === 1) return [elseAt, i];
      depth -= 1;
    }
  }
  throw new ForthError("syntax", "IF without THEN");
}

export class ForthVM {
  constructor(host, artifacts) {
    this.host = host;
    this.artifacts = artifacts || {};
    this.stack = [];
    this.colon = {};
    this.words = {
      DUP: () => this._dup(),
      DROP: () => this._drop(),
      SWAP: () => this._swap(),
      OVER: () => this._over(),
      "+": () => this._add(),
      "-": () => this._sub(),
      "*": () => this._mul(),
      "READ-FILE": () => this._readFile(),
      "LIST-DIR": () => this._listDir(),
      SEARCH: () => this._search(),
      "WRITE-FILE": () => this._writeFile(),
      "RUN-TESTS": () => this._runTests(),
      "RUN-GATES": () => this._runTests(),
      RECEIPT: () => this._receipt(),
      "USE-ARTIFACT": () => this._useArtifact(),
    };
  }

  async interpret(source) {
    await this.runTokens(tokenize(source));
  }

  async runTokens(tokens) {
    let i = 0;
    while (i < tokens.length) {
      const token = tokens[i];
      if (token.kind === "string") {
        this.stack.push(String(token.value));
        i += 1;
        continue;
      }
      if (token.kind === "number") {
        this.stack.push(Number(token.value));
        i += 1;
        continue;
      }
      const name = String(token.value);
      const key = name.toUpperCase();
      if (key === ":") {
        i = this._compileColon(tokens, i);
        continue;
      }
      if (key === "IF") {
        i = await this._runIf(tokens, i);
        continue;
      }
      if (key === "ELSE" || key === "THEN" || key === ";") {
        throw new ForthError("syntax", `${key} without matching opener`);
      }
      await this._execWord(key, name);
      i += 1;
    }
  }

  async _execWord(key, original) {
    if (this.colon[key]) {
      await this.runTokens(this.colon[key]);
      return;
    }
    const action = this.words[key];
    if (!action) throw new ForthError("unknown", `unknown word ${original}`);
    try {
      await action();
    } catch (err) {
      if (err instanceof CapabilityError) throw new ForthError(err.code, err.message);
      throw err;
    }
  }

  _compileColon(tokens, i) {
    if (i + 1 >= tokens.length || tokens[i + 1].kind !== "word") {
      throw new ForthError("syntax", "expected name after :");
    }
    const name = String(tokens[i + 1].value).toUpperCase();
    const body = [];
    let j = i + 2;
    while (j < tokens.length) {
      const token = tokens[j];
      if (token.kind === "word" && String(token.value).toUpperCase() === ";") {
        this.colon[name] = body;
        return j + 1;
      }
      if (token.kind === "word" && String(token.value).toUpperCase() === ":") {
        throw new ForthError("syntax", "nested colon definitions are not supported");
      }
      body.push(token);
      j += 1;
    }
    throw new ForthError("syntax", `unterminated definition of ${name}`);
  }

  async _runIf(tokens, i) {
    const flag = this._truthy(this._pop("IF"));
    const [elseAt, thenAt] = matchIf(tokens, i);
    if (flag) {
      const finish = elseAt === null ? thenAt : elseAt;
      await this.runTokens(tokens.slice(i + 1, finish));
    } else if (elseAt !== null) {
      await this.runTokens(tokens.slice(elseAt + 1, thenAt));
    }
    return thenAt + 1;
  }

  _dup() {
    this.stack.push(this._peek("DUP"));
  }

  _drop() {
    this._pop("DROP");
  }

  _swap() {
    const b = this._pop("SWAP");
    const a = this._pop("SWAP");
    this.stack.push(b, a);
  }

  _over() {
    if (this.stack.length < 2) throw new ForthError("underflow", "stack underflow at OVER");
    this.stack.push(this.stack[this.stack.length - 2]);
  }

  _add() {
    const b = this._popInt("+");
    const a = this._popInt("+");
    this.stack.push(a + b);
  }

  _sub() {
    const b = this._popInt("-");
    const a = this._popInt("-");
    this.stack.push(a - b);
  }

  _mul() {
    const b = this._popInt("*");
    const a = this._popInt("*");
    this.stack.push(a * b);
  }

  async _readFile() {
    this.stack.push(await this.host.read_file(this._popStr("READ-FILE")));
  }

  async _listDir() {
    this.stack.push(await this.host.list_dir(this._popStr("LIST-DIR")));
  }

  async _search() {
    this.stack.push(await this.host.search(this._popStr("SEARCH")));
  }

  async _writeFile() {
    const path = this._popStr("WRITE-FILE");
    const content = this._popStr("WRITE-FILE");
    this.stack.push(await this.host.write_file(content, path));
  }

  async _runTests() {
    this.stack.push(await this.host.run_tests());
  }

  async _receipt() {
    this.stack.push(await this.host.receipt());
  }

  _useArtifact() {
    const path = this._popStr("USE-ARTIFACT");
    if (this.artifacts[path] === undefined) {
      throw new ForthError("missing_artifact", `no artifact: ${path}`);
    }
    this.stack.push(this.artifacts[path]);
  }

  _pop(word) {
    if (!this.stack.length) throw new ForthError("underflow", `stack underflow at ${word}`);
    return this.stack.pop();
  }

  _peek(word) {
    if (!this.stack.length) throw new ForthError("underflow", `stack underflow at ${word}`);
    return this.stack[this.stack.length - 1];
  }

  _popStr(word) {
    const value = this._pop(word);
    if (typeof value !== "string") throw new ForthError("type", `${word} expected string, got ${typeof value}`);
    return value;
  }

  _popInt(word) {
    const value = this._pop(word);
    if (typeof value !== "number" || !Number.isInteger(value)) {
      throw new ForthError("type", `${word} expected integer, got ${typeof value}`);
    }
    return value;
  }

  _truthy(value) {
    if (value === null || value === undefined || value === false || value === 0) return false;
    return true;
  }

  definedNames() {
    return Object.keys(this.colon).sort();
  }
}
