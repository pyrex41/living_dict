"""SCUD v2 Shen Evaluator seam.

Reads one JSON object {run_id, action, resource, attributes} and writes
{allowed, reason, constraints}. Action `execute` is allowed iff the
attributes' program/globs/effects pass livingdict.preflight.validate.
"""

from __future__ import annotations

import json
import sys
from typing import Any

from .preflight import validate


def evaluate(request: Any) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise ValueError("policy request must be an object")
    action = _field(request, "action", "Action")
    resource = _field(request, "resource", "Resource")
    attributes = request.get("attributes")
    if attributes is None:
        attributes = request.get("Attributes")
    if not isinstance(attributes, dict):
        attributes = {}
    attrs = {str(key): _as_text(value) for key, value in attributes.items()}

    if action != "execute":
        return _deny(f"unsupported action: {action or '<empty>'}")
    if not resource:
        return _deny("resource is required")

    program = attrs.get("program") or ""
    allowed_effects = _effects(attrs)
    allowed_globs = _globs(attrs, "allowed_globs", "globs", default=("**",))
    forbidden_globs = _globs(attrs, "forbidden_globs", default=())
    artifacts = _json_map(attrs.get("artifacts"))
    nodes = _json_list(attrs.get("nodes"))
    task_graph = _json_map(attrs.get("task_graph")) or None

    result = validate(
        program,
        allowed_effects,
        allowed_globs,
        forbidden_globs,
        artifacts,
        nodes=nodes or None,
        task_graph=task_graph,
    )
    if not result["valid"]:
        errors = [str(item) for item in result["errors"]]
        return _deny(errors[0] if errors else "critic: rejected")
    constraints = {
        "allowed_effects": ",".join(sorted(allowed_effects)),
        "allowed_globs": ",".join(allowed_globs),
    }
    if forbidden_globs:
        constraints["forbidden_globs"] = ",".join(forbidden_globs)
    return {"allowed": True, "reason": "accepted", "constraints": constraints}


def main(argv: list[str] | None = None) -> int:
    del argv
    try:
        raw = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"decode policy request: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"read policy request: {exc}", file=sys.stderr)
        return 1
    try:
        decision = evaluate(raw)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    sys.stdout.write(json.dumps(decision, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    return 0


def _deny(reason: str) -> dict[str, Any]:
    return {"allowed": False, "reason": reason, "constraints": {}}


def _field(obj: dict[str, Any], *names: str) -> str:
    for name in names:
        if name in obj:
            return _as_text(obj[name])
    return ""


def _as_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return str(value)


def _effects(attrs: dict[str, str]) -> set[str]:
    if "allowed_effects" in attrs:
        raw = attrs["allowed_effects"]
    elif "effects" in attrs:
        raw = attrs["effects"]
    else:
        return {"read", "write", "exec"}
    return {item for item in _split_list(raw)}


def _globs(attrs: dict[str, str], *keys: str, default: tuple[str, ...]) -> tuple[str, ...]:
    raw = None
    for key in keys:
        if key in attrs:
            raw = attrs[key]
            break
    if raw is None:
        return default
    items = _split_list(raw)
    return tuple(items) if items else default


def _split_list(raw: str) -> list[str]:
    text = (raw or "").strip()
    if not text:
        return []
    if text[0] in "[{":
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            parsed = None
        if isinstance(parsed, list):
            return [str(item).strip() for item in parsed if str(item).strip()]
    return [part.strip() for part in text.split(",") if part.strip()]


def _json_map(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _json_list(raw: str | None) -> list[Any]:
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return []
    return parsed if isinstance(parsed, list) else []
