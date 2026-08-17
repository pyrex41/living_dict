from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path
from typing import Any, Iterable

from .models import Telemetry


def read_events(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    events: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            events.append(value)
    return events


def event_seen(path: Path, event_type: str) -> bool:
    return any(event.get("type") == event_type for event in read_events(path))


def summarize(events: Iterable[dict[str, Any]]) -> dict[str, Any]:
    t = Telemetry()
    for event in events:
        kind = event.get("type", "")
        data = event.get("data") or {}
        if kind == "llm.response":
            t.model_calls += 1
            t.input_tokens += int(data.get("input_tokens", 0) or 0)
            t.output_tokens += int(data.get("output_tokens", 0) or 0)
            t.cost_usd += float(data.get("cost_usd", 0.0) or 0.0)
        elif kind == "tool.call":
            t.tool_calls += 1
        elif kind in {"mutation.applied", "file.write", "patch.applied"}:
            t.mutations += 1
        elif kind == "execution.trap":
            t.traps += 1
        elif kind == "plan.replan":
            t.replans += 1
        elif kind == "preflight.rejected":
            t.preflight_rejections += 1
        elif kind == "dictionary.retrieve":
            t.dictionary_retrievals += 1
        elif kind == "dictionary.reuse":
            t.dictionary_reuses += 1
        elif kind == "dictionary.promote":
            t.dictionary_promotions += 1
        elif kind == "graph.node.start":
            t.graph_nodes_started += 1
        elif kind == "graph.node.finish":
            t.graph_nodes_finished += 1
        elif kind == "fault.injected":
            t.crash_injected = True
        elif kind == "run.resumed":
            t.resumed = True
    return asdict(t)


def append_event(path: Path, event: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")

