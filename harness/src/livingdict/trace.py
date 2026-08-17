"""JSONL traces in the ldeval 1.0 event shape."""

from __future__ import annotations

import json
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

_live_sink: ContextVar[Callable[[dict[str, Any]], None] | None] = ContextVar(
    "livingdict_trace_sink", default=None
)


@contextmanager
def live_sink(callback: Callable[[dict[str, Any]], None]) -> Iterator[None]:
    token = _live_sink.set(callback)
    try:
        yield
    finally:
        _live_sink.reset(token)


def make_event(event_type: str, data: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "type": event_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "data": data or {},
    }


def append_events(trace_path: Path | None, events: list[dict[str, Any]]) -> None:
    sink = _live_sink.get()
    if sink is not None:
        for event in events:
            sink(event)
    if trace_path is None or not events:
        return
    trace_path = Path(trace_path)
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    with trace_path.open("a", encoding="utf-8") as handle:
        for event in events:
            handle.write(json.dumps(event, sort_keys=True) + "\n")


def emit(trace_path: Path | None, event_type: str, data: dict[str, Any] | None = None) -> None:
    append_events(trace_path, [make_event(event_type, data)])


def read_events(trace_path: Path) -> list[dict[str, Any]]:
    if not trace_path.exists():
        return []
    events: list[dict[str, Any]] = []
    for line in trace_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            events.append(value)
    return events
