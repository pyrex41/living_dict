"""ldeval command adapter: request.json → Forth envelope → host."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from .envelope import EnvelopeError, PlanEnvelope, load_envelope
from .execute import ExecutionError, load_checkpoint, run_forth
from .host import CapabilityHost
from .trace import emit


def resolve_envelope(request: dict[str, Any]) -> PlanEnvelope:
    if request.get("resume"):
        saved = load_checkpoint(request)
        if saved is None:
            raise ExecutionError("resume", "resume requested but checkpoint.json is missing")
        return saved
    override = os.environ.get("LIVINGDICT_ENVELOPE")
    if override:
        return load_envelope(Path(override))
    candidate = Path(request["dictionary_dir"]) / "envelope.json"
    if candidate.exists():
        return load_envelope(candidate)
    raise ExecutionError(
        "envelope",
        "no plan envelope (set LIVINGDICT_ENVELOPE or write dictionary_dir/envelope.json)",
    )


def run_request(request: dict[str, Any], *, preflight: bool) -> int:
    host = CapabilityHost.from_request(request)
    try:
        envelope = resolve_envelope(request)
        extra = run_forth(
            host,
            envelope,
            preflight=preflight,
            request=request,
            resume=bool(request.get("resume")),
        )
        if "RECEIPT" not in envelope.program.upper():
            payload = {"program_hash": extra["program_hash"]}
            payload.update(extra.get("graph") or host.graph_metrics or {})
            host.receipt(payload)
    except (EnvelopeError, ExecutionError) as exc:
        details = list(getattr(exc, "details", []) or [])
        emit(
            host.trace_path,
            "execution.trap",
            {"reason": getattr(exc, "code", "error"), "detail": str(exc), "errors": details},
        )
        return 2
    return 0


def main(argv: list[str] | None = None, *, preflight: bool) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("usage: adapter.py REQUEST.json", file=sys.stderr)
        return 2
    request = json.loads(Path(args[-1]).read_text(encoding="utf-8"))
    return run_request(request, preflight=preflight)
