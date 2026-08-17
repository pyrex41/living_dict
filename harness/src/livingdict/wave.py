"""Kahn-level wave planner. Dependency layers are not concurrency rounds.

A cycle here is an internal error (the critic already rejected it). Fail
closed: raise, never return a prefix plan (scud v2 Waves lesson).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable

from .envelope import GraphNode, cycle_message, kahn_order


class WavePlanError(Exception):
    pass


METRIC_KEYS = (
    "wave_count",
    "max_wave_width",
    "nodes_parallel",
    "conflicts",
    "wall_ms_serial_estimate",
    "wall_ms_actual",
)


def plan_waves(nodes: list[GraphNode]) -> list[list[GraphNode]]:
    """Partition nodes into Kahn levels. Lexicographic id order inside a wave."""
    if not nodes:
        return []
    seen: dict[str, int] = {}
    for node in nodes:
        seen[node.id] = seen.get(node.id, 0) + 1
    dupes = [ident for ident, count in seen.items() if count > 1]
    if dupes:
        raise WavePlanError("duplicate node id: " + ", ".join(sorted(dupes)))
    _ordered, leftover = kahn_order(nodes)
    if leftover:
        raise WavePlanError(cycle_message(nodes))

    by_id = {node.id: node for node in nodes}
    remaining = set(by_id)
    completed: set[str] = set()
    waves: list[list[GraphNode]] = []
    while remaining:
        ready = ready_nodes(nodes, completed)
        ready = [node for node in ready if node.id in remaining]
        if not ready:
            raise WavePlanError(cycle_message(nodes))
        waves.append(ready)
        for node in ready:
            remaining.remove(node.id)
            completed.add(node.id)
    return waves


def ready_nodes(nodes: Iterable[GraphNode], completed: set[str]) -> list[GraphNode]:
    """Nodes whose declared deps are all in `completed`. Unknown deps stay unsatisfied."""
    ready = [
        node
        for node in nodes
        if node.id not in completed and all(dep in completed for dep in node.depends_on)
    ]
    ready.sort(key=lambda node: node.id)
    return ready


def compute_metrics(
    waves: list[list[GraphNode]],
    timings: dict[str, tuple[str, str]],
    wall_ms_actual: int,
    *,
    conflicts: int = 0,
) -> dict[str, Any]:
    """Hypothesis 6 counters. `conflicts` is structurally 0 when the critic held."""
    widths = [len(wave) for wave in waves]
    parallel = _nodes_parallel(waves, timings)
    serial_ms = 0
    for start, finish in timings.values():
        serial_ms += _interval_ms(start, finish)
    return {
        "wave_count": len(waves),
        "max_wave_width": max(widths) if widths else 0,
        "nodes_parallel": len(parallel),
        "conflicts": int(conflicts),
        "wall_ms_serial_estimate": serial_ms,
        "wall_ms_actual": int(wall_ms_actual),
    }


def format_metrics(metrics: dict[str, Any]) -> str:
    parts = [f"{key}={metrics.get(key, 0)}" for key in METRIC_KEYS]
    return "graph.waves " + " ".join(parts)


def _nodes_parallel(
    waves: list[list[GraphNode]],
    timings: dict[str, tuple[str, str]],
) -> set[str]:
    parallel: set[str] = set()
    for wave in waves:
        ids = [node.id for node in wave if node.id in timings]
        for index, left in enumerate(ids):
            left_start, left_end = timings[left]
            for right in ids[index + 1 :]:
                right_start, right_end = timings[right]
                if _overlaps(left_start, left_end, right_start, right_end):
                    parallel.add(left)
                    parallel.add(right)
    return parallel


def _overlaps(a0: str, a1: str, b0: str, b1: str) -> bool:
    start_a, end_a = _parse_ts(a0), _parse_ts(a1)
    start_b, end_b = _parse_ts(b0), _parse_ts(b1)
    if start_a is None or end_a is None or start_b is None or end_b is None:
        return False
    return start_a < end_b and start_b < end_a


def _interval_ms(start: str, finish: str) -> int:
    first, last = _parse_ts(start), _parse_ts(finish)
    if first is None or last is None:
        return 0
    delta = (last - first).total_seconds()
    if delta < 0:
        return 0
    return int(round(delta * 1000))


def _parse_ts(value: str) -> datetime | None:
    if not value:
        return None
    text = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed
