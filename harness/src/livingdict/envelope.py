"""Plan envelope: control program plus file artifacts.

Forth does not carry multiline patches as S" strings. The model (or a test
fixture) emits this object; USE-ARTIFACT pushes artifact text onto the stack.

Optional `nodes` is the Stage-1 graph: Forth stays the per-node language and
the envelope is the topology. Absent nodes keep today's single-program shape.
"""

from __future__ import annotations

import heapq
import json
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class EnvelopeError(ValueError):
    pass


@dataclass
class GraphNode:
    id: str
    writes: list[str] = field(default_factory=list)
    depends_on: list[str] = field(default_factory=list)
    program: str = ""
    allowed_globs: list[str] | None = None

    def write_globs(self) -> tuple[str, ...]:
        if self.writes:
            return tuple(self.writes)
        if self.allowed_globs:
            return tuple(self.allowed_globs)
        return ()

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "id": self.id,
            "writes": list(self.writes),
            "depends_on": list(self.depends_on),
            "program": self.program,
        }
        if self.allowed_globs is not None:
            payload["allowed_globs"] = list(self.allowed_globs)
        return payload


@dataclass
class PlanEnvelope:
    language: str
    program: str
    artifacts: dict[str, str] = field(default_factory=dict)
    rationale: str = ""
    nodes: list[GraphNode] | None = None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "language": self.language,
            "program": self.program,
            "artifacts": self.artifacts,
            "rationale": self.rationale,
        }
        if self.nodes:
            payload["nodes"] = [node.to_dict() for node in self.nodes]
        return payload

    def dumps(self) -> str:
        return json.dumps(self.to_dict(), indent=2, sort_keys=True) + "\n"

    def ordered_nodes(self) -> list[GraphNode]:
        if not self.nodes:
            return []
        ordered, leftover = kahn_order(self.nodes)
        if leftover:
            raise EnvelopeError(cycle_message(self.nodes))
        return ordered

    def effective_program(self) -> str:
        """Node programs in Kahn order when `nodes` is present, else top-level."""
        if not self.nodes:
            return self.program
        ordered, leftover = kahn_order(self.nodes)
        parts: list[str] = []
        for node in list(ordered) + leftover:
            text = node.program.strip()
            if text:
                parts.append(text)
        return "\n".join(parts)


def parse_string_list(value: Any, label: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise EnvelopeError(f"{label} must be an array of strings")
    return list(value)


def parse_nodes(value: Any) -> list[GraphNode] | None:
    if value is None:
        return None
    if not isinstance(value, list):
        raise EnvelopeError("envelope.nodes must be an array")
    if not value:
        return None
    nodes: list[GraphNode] = []
    for index, raw in enumerate(value):
        if not isinstance(raw, dict):
            raise EnvelopeError(f"envelope.nodes[{index}] must be an object")
        ident = raw.get("id")
        if not isinstance(ident, str) or not ident.strip():
            raise EnvelopeError(f"envelope.nodes[{index}].id must be a string")
        program = raw.get("program")
        if program is None:
            program = ""
        if not isinstance(program, str):
            raise EnvelopeError(f"envelope.nodes[{index}].program must be a string")
        allowed = raw.get("allowed_globs")
        allowed_globs: list[str] | None = None
        if allowed is not None:
            allowed_globs = parse_string_list(allowed, f"envelope.nodes[{index}].allowed_globs")
        nodes.append(
            GraphNode(
                id=ident,
                writes=parse_string_list(raw.get("writes"), f"envelope.nodes[{index}].writes"),
                depends_on=parse_string_list(
                    raw.get("depends_on"), f"envelope.nodes[{index}].depends_on"
                ),
                program=program,
                allowed_globs=allowed_globs,
            )
        )
    return nodes


def parse_envelope(value: Any) -> PlanEnvelope:
    if not isinstance(value, dict):
        raise EnvelopeError("envelope must be an object")
    language = value.get("language")
    program = value.get("program")
    nodes = parse_nodes(value.get("nodes"))
    if program is None and nodes:
        program = ""
    if not isinstance(language, str) or not language.strip():
        raise EnvelopeError("envelope.language must be a string")
    if not isinstance(program, str):
        raise EnvelopeError("envelope.program must be a string")
    artifacts = value.get("artifacts") or {}
    if not isinstance(artifacts, dict):
        raise EnvelopeError("envelope.artifacts must be an object")
    cleaned: dict[str, str] = {}
    for key, text in artifacts.items():
        if not isinstance(key, str) or not isinstance(text, str):
            raise EnvelopeError("artifact keys and values must be strings")
        cleaned[key] = text
    rationale = value.get("rationale") or ""
    if not isinstance(rationale, str):
        raise EnvelopeError("envelope.rationale must be a string")
    return PlanEnvelope(
        language=language.strip().lower(),
        program=program,
        artifacts=cleaned,
        rationale=rationale,
        nodes=nodes,
    )


def load_envelope(path: Path) -> PlanEnvelope:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise EnvelopeError(f"invalid envelope JSON: {exc}") from exc
    return parse_envelope(payload)


def load_task_graph(path: str | Path | None) -> dict[str, Any] | None:
    """Return the task graph object, None if absent, or `{'_error': ...}`."""
    if path is None or path == "":
        return None
    target = Path(path)
    if not target.is_file():
        return None
    try:
        payload = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"_error": f"invalid JSON: {exc}"}
    if not isinstance(payload, dict):
        return {"_error": "task graph must be an object"}
    return payload


def kahn_order(nodes: list[GraphNode]) -> tuple[list[GraphNode], list[GraphNode]]:
    """Deterministic Kahn sort; leftover nodes mean a cycle among them."""
    by_id = {node.id: node for node in nodes}
    indegree = {node.id: 0 for node in nodes}
    children: dict[str, list[str]] = defaultdict(list)
    for node in nodes:
        for dep in node.depends_on:
            if dep not in by_id:
                continue
            indegree[node.id] += 1
            children[dep].append(node.id)
    heap = [ident for ident, degree in indegree.items() if degree == 0]
    heapq.heapify(heap)
    ordered: list[GraphNode] = []
    while heap:
        ident = heapq.heappop(heap)
        ordered.append(by_id[ident])
        for child in children[ident]:
            indegree[child] -= 1
            if indegree[child] == 0:
                heapq.heappush(heap, child)
    leftover = [by_id[ident] for ident in sorted(indegree) if indegree[ident] > 0]
    return ordered, leftover


def cycle_ids(nodes: list[GraphNode]) -> list[str] | None:
    by_id = {node.id: node for node in nodes}
    white, gray, black = 0, 1, 2
    color = {ident: white for ident in by_id}

    def dfs(ident: str, stack: list[str]) -> list[str] | None:
        color[ident] = gray
        stack.append(ident)
        for dep in by_id[ident].depends_on:
            if dep not in by_id:
                continue
            if color[dep] == gray:
                start = stack.index(dep)
                return stack[start:] + [dep]
            if color[dep] == white:
                found = dfs(dep, stack)
                if found:
                    return found
        stack.pop()
        color[ident] = black
        return None

    for ident in sorted(by_id):
        if color[ident] == white:
            found = dfs(ident, [])
            if found:
                return found
    return None


def cycle_message(nodes: list[GraphNode]) -> str:
    found = cycle_ids(nodes)
    if not found:
        return "dependency cycle"
    return "dependency cycle: " + " -> ".join(found)


def nodes_from_value(value: Any) -> list[GraphNode] | None:
    if not value:
        return None
    if isinstance(value, list) and value and isinstance(value[0], GraphNode):
        return list(value)
    return parse_nodes(value)
