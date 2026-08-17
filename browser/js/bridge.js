/** Boot the shaken Shen critic once; call named validate. */

import { forthValidate } from "./forth.js";

const CRITIC_CANDIDATES = [
  "../dist/critic/app.js",
  "../dist/critic.js",
];

export const bridge = {
  booted: false,
  available: false,
  engine: "js",
  error: null,
  $: null,
};

function tagName(x) {
  if (typeof x === "symbol") return Symbol.keyFor(x) || String(x);
  return String(x);
}

function toJsTree(value, $) {
  if ($ && typeof $.toArrayTree === "function" && value && typeof value === "object") {
    try {
      return $.toArrayTree(value);
    } catch {
      /* fall through */
    }
  }
  return value;
}

function decodeShen(result, $) {
  const tree = toJsTree(result, $);
  if (!Array.isArray(tree) || tree.length === 0) {
    return { valid: false, errors: [String(result)], final_depth: 0, effects: [] };
  }
  const tag = tagName(tree[0]);
  if (tag === "accept") {
    return {
      valid: true,
      errors: [],
      final_depth: Number(tree[1]) || 0,
      effects: flattenStrings(tree[2]),
    };
  }
  if (tag === "reject") {
    return {
      valid: false,
      errors: flattenStrings(tree[1]),
      final_depth: Number(tree[2]) || 0,
      effects: flattenStrings(tree[3]),
    };
  }
  return { valid: false, errors: ["unexpected validate result"], final_depth: 0, effects: [] };
}

function flattenStrings(value) {
  if (value == null) return [];
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.map((x) => (typeof x === "string" ? x : tagName(x)));
  return [String(value)];
}

async function loadCritic() {
  for (const spec of CRITIC_CANDIDATES) {
    try {
      const url = new URL(spec, import.meta.url);
      const mod = await import(url.href);
      const $ = mod.default;
      if ($ && typeof $.caller === "function") return $;
    } catch (err) {
      bridge.error = err;
    }
  }
  return null;
}

export async function boot() {
  if (bridge.booted) return bridge.available;
  bridge.booted = true;
  const $ = await loadCritic();
  if (!$) {
    bridge.available = false;
    bridge.engine = "js";
    return false;
  }
  bridge.$ = $;
  bridge.available = true;
  bridge.engine = "shen";
  bridge.error = null;
  return true;
}

export async function validate(program, allowedEffects, allowedGlobs, forbiddenGlobs, artifacts) {
  await boot();
  const effects = allowedEffects || ["read", "write", "exec"];
  const allowed = allowedGlobs && allowedGlobs.length ? allowedGlobs : ["**"];
  const forbidden = forbiddenGlobs || [];
  const keys = artifacts ? Object.keys(artifacts).sort() : [];
  if (bridge.available && bridge.$) {
    try {
      const $ = bridge.$;
      const raw = await $.caller("validate")(
        program,
        $.toListTree(effects),
        $.toListTree(allowed),
        $.toListTree(forbidden),
        $.toListTree(keys),
      );
      const decoded = decodeShen(raw, $);
      decoded.engine = "shen";
      return decoded;
    } catch (err) {
      return {
        engine: "shen",
        valid: false,
        errors: [err && err.message ? err.message : String(err)],
        final_depth: 0,
        effects: [],
      };
    }
  }
  const decoded = forthValidate(program, effects, allowed, forbidden, artifacts || {});
  decoded.engine = "js";
  return decoded;
}

export function engine() {
  return bridge.engine;
}
