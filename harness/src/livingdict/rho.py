"""rho.run/v1 child wire: request parse, JSONL events, ConsumeRhoV1 checker.

Matches scud pkg/executor ConsumeRhoV1 / reduceTerminal. The parent Go
Request is never stdin; only wireRequest is.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, TextIO

from . import bip340


PROTOCOL = "rho.run/v1"
TERMINAL_TYPES = frozenset({"run.completed", "run.failed", "run.cancelled"})
MAX_LINE = 1024 * 1024

_KNOWN_TOP = frozenset(
    {"protocol", "run_id", "model", "input", "system", "limits", "grant", "context"}
)


class WireError(ValueError):
    pass


class StreamError(ValueError):
    pass


class GrantError(ValueError):
    pass


class GrantExpired(GrantError):
    pass


@dataclass
class WireRequest:
    protocol: str
    run_id: str
    model_provider: str
    model_id: str
    prompt: str
    system: str
    limits: dict[str, Any]
    grant: dict[str, Any]
    context: dict[str, Any]
    extra: dict[str, Any] = field(default_factory=dict)
    raw: dict[str, Any] = field(default_factory=dict)


def parse_wire_request(raw: Any) -> WireRequest:
    if not isinstance(raw, dict):
        raise WireError("request must be an object")
    extra = {key: raw[key] for key in raw if key not in _KNOWN_TOP}
    protocol = raw.get("protocol")
    if protocol is None:
        protocol = ""
    if not isinstance(protocol, str):
        protocol = str(protocol)
    run_id = raw.get("run_id")
    if run_id is None:
        run_id = ""
    if not isinstance(run_id, str):
        run_id = str(run_id)
    model = raw.get("model")
    provider = ""
    model_id = ""
    if isinstance(model, dict):
        provider = model.get("provider") or ""
        model_id = model.get("id") or ""
        if not isinstance(provider, str):
            provider = str(provider)
        if not isinstance(model_id, str):
            model_id = str(model_id)
    elif model is not None:
        extra.setdefault("model", model)
    system = raw.get("system") or ""
    if not isinstance(system, str):
        system = str(system)
    limits = raw.get("limits")
    if not isinstance(limits, dict):
        limits = {}
    grant = raw.get("grant")
    if not isinstance(grant, dict):
        grant = {}
    context = raw.get("context")
    if not isinstance(context, dict):
        context = {}
    return WireRequest(
        protocol=protocol,
        run_id=run_id,
        model_provider=provider,
        model_id=model_id,
        prompt=_extract_prompt(raw.get("input")),
        system=system,
        limits=dict(limits),
        grant=dict(grant),
        context=dict(context),
        extra=extra,
        raw=raw,
    )


def _extract_prompt(input_value: Any) -> str:
    if not isinstance(input_value, list):
        return ""
    for message in input_value:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and isinstance(block.get("text"), str):
                return block["text"]
    return ""


def require_wire_fields(req: WireRequest) -> None:
    if req.protocol != PROTOCOL:
        raise WireError(f'unsupported protocol {req.protocol!r}')
    if not req.run_id:
        raise WireError("run_id is required")
    if not req.model_provider or not req.model_id:
        raise WireError("model.provider and model.id are required")


def parse_rfc3339(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def rfc3339_now() -> str:
    return utc_now().strftime("%Y-%m-%dT%H:%M:%SZ")


class EventStream:
    """stdout JSONL producer. One terminal, then silence."""

    def __init__(self, run_id: str, out: TextIO) -> None:
        self.run_id = run_id
        self.out = out
        self.seq = 0
        self.closed = False

    def emit(self, event_type: str, data: Any = None) -> None:
        if self.closed:
            return
        self.seq += 1
        event = {
            "protocol": PROTOCOL,
            "run_id": self.run_id,
            "seq": self.seq,
            "time": rfc3339_now(),
            "type": event_type,
            "data": {} if data is None else data,
        }
        line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
        encoded = line.encode("utf-8")
        if len(encoded) > MAX_LINE:
            event["data"] = {"truncated": True, "type": event_type}
            line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
        self.out.write(line + "\n")
        self.out.flush()
        if event_type in TERMINAL_TYPES:
            self.closed = True


def consume_rho_v1(text: str, expected_run_id: str) -> dict[str, Any]:
    """Python port of executor.ConsumeRhoV1 including reduceTerminal payloads."""
    result: dict[str, Any] = {
        "run_id": expected_run_id,
        "text": "",
        "outcome": "",
        "failure": None,
        "usage": {},
        "events": [],
    }
    previous = 0
    seen = False
    terminal = False
    for line in text.splitlines():
        if not line.strip():
            continue
        if len(line.encode("utf-8")) > MAX_LINE:
            raise StreamError("read rho.run/v1 stream: token too long")
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise StreamError("decode rho.run/v1 event") from exc
        if not isinstance(event, dict):
            raise StreamError("decode rho.run/v1 event")
        protocol = event.get("protocol")
        if protocol != PROTOCOL:
            raise StreamError(f"unsupported protocol {protocol!r}")
        run_id = event.get("run_id")
        if run_id != expected_run_id:
            raise StreamError(f"event run ID {run_id!r} does not match {expected_run_id!r}")
        if terminal:
            raise StreamError("event received after terminal event")
        seq = event.get("seq", 0)
        if isinstance(seq, bool) or not isinstance(seq, int) or seq < 0:
            raise StreamError("decode rho.run/v1 event")
        if seen and seq <= previous:
            raise StreamError(f"non-monotonic event sequence: {seq} follows {previous}")
        seen, previous = True, seq
        typ = event.get("type")
        data = event.get("data")
        if typ == "message.delta":
            if not isinstance(data, dict) or not isinstance(data.get("text"), str):
                raise StreamError("decode message.delta")
            result["text"] += data["text"]
        result["events"].append(event)
        if typ in TERMINAL_TYPES:
            terminal = True
            _reduce_terminal(result, str(typ), data)
    if not terminal:
        raise StreamError("rho.run/v1 stream ended without terminal event")
    return result


def _reduce_terminal(result: dict[str, Any], typ: str, data: Any) -> None:
    result["outcome"] = typ[4:] if typ.startswith("run.") else typ
    if typ == "run.completed":
        if not isinstance(data, dict) or data.get("status") != "succeeded":
            raise StreamError("invalid run.completed payload")
        usage = data.get("usage")
        result["usage"] = usage if isinstance(usage, dict) else {}
        return
    if typ == "run.failed":
        if (
            not isinstance(data, dict)
            or not isinstance(data.get("code"), str)
            or data.get("code") == ""
            or not isinstance(data.get("message"), str)
            or data.get("message") == ""
        ):
            raise StreamError("invalid run.failed payload")
        result["failure"] = data
        return
    if typ == "run.cancelled":
        if not isinstance(data, dict) or not isinstance(data.get("reason"), str) or data.get("reason") == "":
            raise StreamError("invalid run.cancelled payload")
        usage = data.get("usage")
        result["usage"] = usage if isinstance(usage, dict) else {}


def canonical_json(payload: bytes | str) -> bytes:
    """Match Go encoding/json over `any`: sorted keys, no extra space, HTML-safe strings."""
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    value = json.loads(payload)
    return _canonical_value(value).encode("utf-8")


def _canonical_value(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return _encode_string(value)
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            raise ValueError("unsupported number")
        if value.is_integer() and abs(value) < 2**53:
            return str(int(value))
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ",".join(_canonical_value(item) for item in value) + "]"
    if isinstance(value, dict):
        parts: list[str] = []
        for key in sorted(str(item) for item in value):
            parts.append(_encode_string(key) + ":" + _canonical_value(value[key]))
        return "{" + ",".join(parts) + "}"
    raise TypeError(f"unsupported JSON value {type(value).__name__}")


def _encode_string(text: str) -> str:
    out: list[str] = ['"']
    for char in text:
        code = ord(char)
        if char == '"':
            out.append('\\"')
        elif char == "\\":
            out.append("\\\\")
        elif char == "\b":
            out.append("\\b")
        elif char == "\f":
            out.append("\\f")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\t":
            out.append("\\t")
        elif char == "&":
            out.append("\\u0026")
        elif char == "<":
            out.append("\\u003c")
        elif char == ">":
            out.append("\\u003e")
        elif code < 0x20 or char in "\u2028\u2029":
            out.append(f"\\u{code:04x}")
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def unsigned_request_bytes(raw: dict[str, Any]) -> bytes:
    clone = json.loads(json.dumps(raw))
    grant = clone.get("grant")
    if isinstance(grant, dict):
        grant.pop("witness", None)
    return canonical_json(json.dumps(clone))


def request_sha256(raw: dict[str, Any]) -> str:
    """Hex digest of canonicalJSON(request) with grant.witness stripped."""
    return hashlib.sha256(unsigned_request_bytes(raw)).hexdigest()


def grant_mode_require() -> bool:
    return os.environ.get("RHO_PROTOCOL_GRANT_MODE", "").strip().lower() == "require"


def _xonly_pubkey(value: str) -> bytes | None:
    try:
        raw = bip340._decode_bytes(value)
    except (ValueError, TypeError):
        return None
    if len(raw) == 33 and raw[0] in (2, 3):
        raw = raw[1:]
    if len(raw) != 32:
        return None
    return raw


def verify_witness(
    raw: dict[str, Any],
    *,
    pubkey: str | None = None,
    now: datetime | None = None,
) -> str:
    """Require-mode grant gate. Returns sha256(hex) of the unsigned request.

    Structural checks (always):
      * grant.witness is a non-empty string
      * pubkey is a 32-byte x-only key (hex or base64)
      * grant.issuer_pubkey / grant.pubkey, if present, equals that key
      * grant.expires_at is parseable RFC3339 and strictly in the future

    Then BIP340 over sha256(canonical unsigned request). A receipt may name
    grant_verification=bip340 only after this function returns. Do not treat a
    structural-only inspection as a signature check.

    TODO: if bip340.verify is removed, keep this function as the only gate and
    never advertise cryptographic verification from receipts or docs.
    """
    if pubkey is None:
        pubkey = os.environ.get("RHO_PROTOCOL_GRANT_PUBKEY", "").strip()
    if not isinstance(pubkey, str) or not pubkey.strip():
        raise GrantError("RHO_PROTOCOL_GRANT_PUBKEY is required")
    pubkey = pubkey.strip()
    key_bytes = _xonly_pubkey(pubkey)
    if key_bytes is None:
        raise GrantError("RHO_PROTOCOL_GRANT_PUBKEY is not a 32-byte x-only key")

    grant = raw.get("grant") if isinstance(raw, dict) else None
    if not isinstance(grant, dict):
        grant = {}
    for field in ("issuer_pubkey", "pubkey"):
        carried = grant.get(field)
        if not isinstance(carried, str) or not carried.strip():
            continue
        carried_bytes = _xonly_pubkey(carried.strip())
        if carried_bytes != key_bytes:
            raise GrantError("grant pubkey does not match RHO_PROTOCOL_GRANT_PUBKEY")

    witness = grant.get("witness") or ""
    if not isinstance(witness, str) or not witness.strip():
        raise GrantError("grant.witness is required")

    expires = parse_rfc3339(grant.get("expires_at"))
    if expires is None:
        raise GrantError("grant.expires_at is required")
    moment = now if now is not None else utc_now()
    if moment >= expires:
        raise GrantExpired("grant expires_at is in the past")

    digest_hex = request_sha256(raw)
    message = bytes.fromhex(digest_hex)
    if not bip340.verify(pubkey, message, witness.strip()):
        raise GrantError("grant witness verification failed")
    return digest_hex


def verify_required_grant(raw: dict[str, Any]) -> None:
    verify_witness(raw)


def globs_from_roots(roots: Any, workspace) -> tuple[str, ...]:
    """Map grant read/write roots onto workspace-relative allowed globs."""
    from pathlib import Path

    if not isinstance(roots, list) or not roots:
        return ("**",)
    root = Path(workspace).resolve()
    globs: list[str] = []
    for item in roots:
        if not isinstance(item, str) or not item:
            continue
        path = Path(item)
        resolved = path.resolve() if path.is_absolute() else (root / path).resolve()
        try:
            rel = resolved.relative_to(root)
        except ValueError:
            continue
        posix = rel.as_posix()
        if posix == ".":
            return ("**",)
        globs.append(posix)
        globs.append(posix + "/**")
    return tuple(globs)
