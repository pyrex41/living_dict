#!/usr/bin/env python3
"""One-shot primitive-contract table emitter (not a runtime).

    python3 tools/gen_primitives.py spec/primitives.v1.json

Writes contract tables behind BEGIN/END GENERATED PRIMITIVES v1 markers in
shen/critic/validate.shen (yggdrasil-checkable clauses) and
beam/lib/ld_host/forth.ex (@host_words / @stack_words). Method bodies stay
handwritten. Does not write Python/Lua/JS HOST_DICTIONARY, does not codegen
docs/ARCHITECTURE.md, and does not add host Forth words.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MARKER = "GENERATED PRIMITIVES v1"
BEGIN = f"BEGIN {MARKER}"
END = f"END {MARKER}"

SHEN_PATH = ROOT / "shen" / "critic" / "validate.shen"
BEAM_PATH = ROOT / "beam" / "lib" / "ld_host" / "forth.ex"

# Handwritten implementations in forth.ex. Generating a host/ir key without
# a method body is forbidden.
IMPLEMENTED_HOST_IR = (
    "READ-FILE",
    "LIST-DIR",
    "SEARCH",
    "WRITE-FILE",
    "RUN-TESTS",
    "RUN-GATES",
    "RECEIPT",
    "USE-ARTIFACT",
)
IMPLEMENTED_STACK = ("DUP", "DROP", "SWAP", "OVER", "+", "-", "*")
EVAL_ABI = (
    "READ-FILE",
    "LIST-DIR",
    "SEARCH",
    "WRITE-FILE",
    "RUN-TESTS",
    "RUN-GATES",
    "RECEIPT",
)
CLASSES = {"host", "ir", "stack", "control"}
EFFECTS = {"read", "write", "exec"}

BLOCK_RE = re.compile(
    rf"(^[^\n]*{re.escape(BEGIN)}[^\n]*\n)(.*?)(^[^\n]*{re.escape(END)}[^\n]*\n?)",
    re.MULTILINE | re.DOTALL,
)


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def load_spec(path: Path) -> tuple[bytes, dict[str, Any], str]:
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
        spec = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"{path}: invalid JSON: {exc}")
    if not isinstance(spec, dict):
        die(f"{path}: spec must be an object")
    digest = hashlib.sha256(raw).hexdigest()
    return raw, spec, digest


def validate_spec(spec: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if spec.get("version") != "1.0":
        die("spec version must be \"1.0\"")
    if spec.get("abi") != "eval-1.0":
        die("spec abi must be \"eval-1.0\"")
    words = spec.get("words")
    if not isinstance(words, dict) or not words:
        die("spec.words must be a non-empty object")

    for name, word in words.items():
        if not isinstance(name, str) or not name:
            die(f"invalid word name: {name!r}")
        if not isinstance(word, dict):
            die(f"{name}: word entry must be an object")
        cls = word.get("class")
        if cls not in CLASSES:
            die(f"{name}: class must be one of {sorted(CLASSES)}")
        for key in ("inputs", "outputs"):
            val = word.get(key)
            if type(val) is not int or val < 0:
                die(f"{name}: {key} must be an integer >= 0")
        effects = word.get("effects")
        if not isinstance(effects, list) or any(
            not isinstance(e, str) or e not in EFFECTS for e in effects
        ):
            die(f"{name}: effects must be a list of read|write|exec")
        if cls == "control" and word.get("join") != "shape":
            die(f"{name}: control words require join \"shape\"")
        if cls != "control" and "join" in word:
            die(f"{name}: join is only valid on control words")

    missing_abi = [n for n in EVAL_ABI if n not in words]
    if missing_abi:
        die(f"eval 1.0 ABI words missing: {missing_abi}")
    for name in EVAL_ABI:
        if words[name].get("eval_abi") is not True:
            die(f"{name}: eval_abi must be true")
        if words[name]["class"] != "host":
            die(f"{name}: eval ABI words are class host")
    if words.get("USE-ARTIFACT", {}).get("class") != "ir":
        die("USE-ARTIFACT must be class ir")
    if "RUN-GATES" not in words or "RUN-TESTS" not in words:
        die("RUN-GATES and RUN-TESTS must be two table entries")

    host_ir = [n for n, w in words.items() if w["class"] in ("host", "ir")]
    stack = [n for n, w in words.items() if w["class"] == "stack"]
    extra_host = [n for n in host_ir if n not in IMPLEMENTED_HOST_IR]
    extra_stack = [n for n in stack if n not in IMPLEMENTED_STACK]
    if extra_host:
        die(
            "refusing to generate host/ir keys without handwritten "
            f"implementations: {extra_host}"
        )
    if extra_stack:
        die(
            "refusing to generate stack keys without handwritten "
            f"implementations: {extra_stack}"
        )
    missing_impl = [n for n in IMPLEMENTED_HOST_IR if n not in host_ir]
    missing_stack = [n for n in IMPLEMENTED_STACK if n not in stack]
    if missing_impl or missing_stack:
        die(
            "spec must list every implemented host/stack word "
            f"(missing host/ir={missing_impl} stack={missing_stack})"
        )
    return words


def shen_str(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def shen_list(items: list[str]) -> str:
    if not items:
        return "[]"
    return "[" + " ".join(shen_str(x) for x in items) + "]"


def emit_shen(words: dict[str, dict[str, Any]], digest: str) -> str:
    names = list(words)
    lines = [
        f"\\\\ primitive_contract {digest}",
        "\\\\ python3 tools/gen_primitives.py spec/primitives.v1.json",
        "\\\\ Python/Lua/JS HOST_DICTIONARY is documented drift (not generated).",
        "",
        "(define contract-inputs",
        "  { string --> number }",
    ]
    for name in names:
        lines.append(f"  {shen_str(name)} -> {words[name]['inputs']}")
    lines.append("  X -> -1)")
    lines.append("")
    lines.append("(define contract-outputs")
    lines.append("  { string --> number }")
    for name in names:
        lines.append(f"  {shen_str(name)} -> {words[name]['outputs']}")
    lines.append("  X -> 0)")
    lines.append("")
    lines.append("(define contract-effect")
    lines.append("  { string --> (list string) }")
    for name in names:
        effects = words[name]["effects"]
        if effects:
            lines.append(f"  {shen_str(name)} -> {shen_list(effects)}")
    lines.append("  X -> [])")
    lines.append("")
    lines.append("(define host-word?")
    lines.append("  { string --> boolean }")
    for name in names:
        lines.append(f"  {shen_str(name)} -> true")
    lines.append("  X -> false)")
    lines.append("")
    return "\n".join(lines)


def emit_beam(words: dict[str, dict[str, Any]], digest: str) -> str:
    host = [n for n, w in words.items() if w["class"] in ("host", "ir")]
    stack = [n for n, w in words.items() if w["class"] == "stack"]
    host_sigil = " ".join(host)
    stack_sigil = " ".join(stack)
    return (
        f"  # primitive_contract {digest}\n"
        "  # python3 tools/gen_primitives.py spec/primitives.v1.json\n"
        "  # Python/Lua/JS HOST_DICTIONARY is documented drift (not generated).\n"
        f'  @primitive_contract "{digest}"\n'
        f"  @host_words ~w({host_sigil})\n"
        f"  @stack_words ~w({stack_sigil})\n"
    )


def patch(path: Path, inner: str, check: bool) -> bool:
    text = path.read_text(encoding="utf-8")
    match = BLOCK_RE.search(text)
    if match is None:
        die(f"{path}: missing {BEGIN} / {END} markers")
    new_text = text[: match.start(2)] + inner + text[match.end(2) :]
    if new_text == text:
        return False
    if check:
        print(f"stale: {path.relative_to(ROOT)}", file=sys.stderr)
        return True
    path.write_text(new_text, encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")
    return True


def resolve_spec(arg: str) -> Path:
    path = Path(arg)
    if path.is_file():
        return path.resolve()
    candidate = (ROOT / arg).resolve()
    if candidate.is_file():
        return candidate
    die(f"spec not found: {arg}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", help="path to spec/primitives.v1.json")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 if generated tables would change (do not write)",
    )
    args = parser.parse_args(argv)

    spec_path = resolve_spec(args.spec)
    _raw, spec, digest = load_spec(spec_path)
    words = validate_spec(spec)

    dirty = False
    dirty |= patch(SHEN_PATH, emit_shen(words, digest), args.check)
    dirty |= patch(BEAM_PATH, emit_beam(words, digest), args.check)
    if args.check and dirty:
        die("primitive tables are stale; run python3 tools/gen_primitives.py spec/primitives.v1.json")
    if args.check:
        print(f"ok primitive_contract {digest}")
    else:
        print(f"primitive_contract {digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
