"""Shen-style preflight: stack, effects, and static write paths.

This is the Python `forth-shen` critic used by `harness/adapters/forth_shen.py`.
It implements the same Accept | Reject rules as `harness/shen/contracts.shen`.
The live shen-lua critic is `openresty/shen/preflight.shen` (`validate`),
loaded under OpenResty / `openresty/bin/livingdict-resty`. Shen does not
replace Forth and does not emit patches.

Stage-1 graph checks live here (Python body). The portable Shen critic is
not silently weaker: `shen/critic/validate.shen` lists the same rules as TODO.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass
from typing import Any

from .envelope import GraphNode, cycle_ids, cycle_message, nodes_from_value
from .forth import Token, tokenize
from .policy import PathPolicy


@dataclass(frozen=True)
class Contract:
    inputs: int
    outputs: int
    effects: frozenset[str]


HOST_DICTIONARY: dict[str, Contract] = {
    "READ-FILE": Contract(1, 1, frozenset({"read"})),
    "LIST-DIR": Contract(1, 1, frozenset({"read"})),
    "SEARCH": Contract(1, 1, frozenset({"read"})),
    "WRITE-FILE": Contract(2, 1, frozenset({"write"})),
    "RUN-TESTS": Contract(0, 1, frozenset({"exec"})),
    "RUN-GATES": Contract(0, 1, frozenset({"exec"})),
    "RECEIPT": Contract(0, 1, frozenset()),
    "USE-ARTIFACT": Contract(1, 1, frozenset({"read"})),
    "DUP": Contract(1, 2, frozenset()),
    "DROP": Contract(1, 0, frozenset()),
    "SWAP": Contract(2, 2, frozenset()),
    "OVER": Contract(2, 3, frozenset()),
    "+": Contract(2, 1, frozenset()),
    "-": Contract(2, 1, frozenset()),
    "*": Contract(2, 1, frozenset()),
    "IF": Contract(1, 0, frozenset()),
    "ELSE": Contract(0, 0, frozenset()),
    "THEN": Contract(0, 0, frozenset()),
}


def validate(
    program: str,
    allowed_effects: set[str] | frozenset[str],
    allowed_globs: tuple[str, ...] | list[str] = ("**",),
    forbidden_globs: tuple[str, ...] | list[str] = (),
    artifacts: dict[str, str] | None = None,
    *,
    nodes: list[Any] | None = None,
    task_graph: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return `{valid, errors, final_depth, effects}` without touching the workspace."""
    errors: list[str] = []
    artifacts = artifacts or {}
    host_policy = PathPolicy(_dummy_root(), allowed_globs, forbidden_globs)
    for key in sorted(artifacts):
        try:
            rel = host_policy.relative(key)
        except ValueError as exc:
            errors.append(f"artifact {key}: {exc}")
            continue
        reason = host_policy.write_allowed(rel)
        if reason:
            errors.append(f"artifact {key}: {reason}")

    graph_nodes = nodes_from_value(nodes)
    if graph_nodes:
        errors.extend(
            _graph_errors(
                graph_nodes,
                artifacts,
                host_policy,
                allowed_effects,
                forbidden_globs,
                task_graph,
            )
        )

    walked = _walk_program(program, allowed_effects, [host_policy], artifacts)
    errors.extend(walked["errors"])
    return {
        "valid": not errors,
        "errors": errors,
        "final_depth": walked["final_depth"],
        "effects": walked["effects"],
    }


def _graph_errors(
    nodes: list[GraphNode],
    artifacts: dict[str, str],
    host_policy: PathPolicy,
    allowed_effects: set[str] | frozenset[str],
    forbidden_globs: tuple[str, ...] | list[str],
    task_graph: dict[str, Any] | None,
) -> list[str]:
    errors: list[str] = []
    seen: dict[str, int] = {}
    for node in nodes:
        seen[node.id] = seen.get(node.id, 0) + 1
    for ident in sorted(ident for ident, count in seen.items() if count > 1):
        errors.append(f"duplicate node id: {ident}")

    by_id = {node.id: node for node in nodes if seen.get(node.id, 0) == 1}
    for node in nodes:
        for dep in node.depends_on:
            if dep not in seen:
                errors.append(f"unknown depends_on: {node.id} -> {dep}")

    if _has_cycle(nodes):
        errors.append(cycle_message(nodes))

    pairs: list[tuple[str, str]] = []
    for index, left in enumerate(nodes):
        for right in nodes[index + 1 :]:
            if not write_sets_overlap(left.write_globs(), right.write_globs()):
                continue
            if _depends_transitively(left.id, right.id, by_id) or _depends_transitively(
                right.id, left.id, by_id
            ):
                continue
            pairs.append(tuple(sorted((left.id, right.id))))
    for left_id, right_id in sorted(set(pairs)):
        errors.append(f"overlapping independent writes: {left_id} {right_id}")

    for key in sorted(artifacts):
        if not any(_covers_path(node, key, host_policy) for node in nodes):
            errors.append(f"uncovered artifact: {key}")

    for node in nodes:
        node_policy = PathPolicy(_dummy_root(), node.write_globs(), forbidden_globs)
        walked = _walk_program(
            node.program,
            allowed_effects,
            [host_policy, node_policy],
            artifacts,
        )
        for item in walked["errors"]:
            errors.append(f"node {node.id}: {item}")

    if task_graph is not None:
        errors.extend(_task_graph_errors(nodes, task_graph))
    return errors


def _has_cycle(nodes: list[GraphNode]) -> bool:
    return cycle_ids(nodes) is not None


def _depends_transitively(src: str, dst: str, by_id: dict[str, GraphNode]) -> bool:
    if src not in by_id or dst not in by_id:
        return False
    seen: set[str] = set()
    stack = list(by_id[src].depends_on)
    while stack:
        cur = stack.pop()
        if cur == dst:
            return True
        if cur in seen or cur not in by_id:
            continue
        seen.add(cur)
        stack.extend(by_id[cur].depends_on)
    return False


def write_sets_overlap(left: tuple[str, ...] | list[str], right: tuple[str, ...] | list[str]) -> bool:
    """True when two declared write globs can name the same path."""
    if not left or not right:
        return False
    for first in left:
        for second in right:
            if first == second:
                return True
            if fnmatch.fnmatch(first, second) or fnmatch.fnmatch(second, first):
                return True
    return False


def _covers_path(node: GraphNode, path: str, host_policy: PathPolicy) -> bool:
    globs = node.write_globs()
    if not globs:
        return False
    policy = PathPolicy(host_policy.workspace, globs, ())
    try:
        rel = policy.relative(path)
    except ValueError:
        return False
    return policy.write_allowed(rel) is None


def _task_graph_errors(
    nodes: list[GraphNode],
    task_graph: dict[str, Any],
) -> list[str]:
    if task_graph.get("_error"):
        return [f"task graph: {task_graph['_error']}"]
    raw_nodes = task_graph.get("nodes")
    if not isinstance(raw_nodes, list):
        return ["task graph: nodes must be an array"]

    from .envelope import kahn_order

    ordered, leftover = kahn_order(nodes)
    if leftover:
        return []
    index = {node.id: position for position, node in enumerate(ordered)}

    parsed: list[tuple[str, list[str], list[str]]] = []
    for raw in raw_nodes:
        if not isinstance(raw, dict):
            continue
        ident = raw.get("id")
        writes = raw.get("writes") or []
        deps = raw.get("depends_on") or []
        if not isinstance(ident, str):
            continue
        if not isinstance(writes, list) or not isinstance(deps, list):
            continue
        parsed.append(
            (
                ident,
                [item for item in writes if isinstance(item, str)],
                [item for item in deps if isinstance(item, str)],
            )
        )
    tg_writes = {ident: writes for ident, writes, _deps in parsed}

    errors: list[str] = []
    seen: set[tuple[str, str]] = set()
    for _tg_id, writes, deps in parsed:
        covering = [node for node in nodes if write_sets_overlap(node.write_globs(), writes)]
        for dep_id in deps:
            dep_writes = tg_writes.get(dep_id)
            if dep_writes is None:
                continue
            dep_covering = [
                node for node in nodes if write_sets_overlap(node.write_globs(), dep_writes)
            ]
            for env_node in covering:
                for dep_node in dep_covering:
                    if index[dep_node.id] >= index[env_node.id]:
                        key = (env_node.id, dep_id)
                        if key in seen:
                            continue
                        seen.add(key)
                        errors.append(
                            f"graph order: envelope node {env_node.id} must follow "
                            f"task-graph dependency {dep_id}"
                        )
    return errors


def _walk_program(
    program: str,
    allowed_effects: set[str] | frozenset[str],
    policies: list[PathPolicy],
    artifacts: dict[str, str],
) -> dict[str, Any]:
    errors: list[str] = []
    try:
        tokens = tokenize(program)
    except Exception as exc:
        return {"errors": [str(exc)], "final_depth": 0, "effects": []}

    words = dict(HOST_DICTIONARY)
    effects: set[str] = set()
    depth = 0
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token.kind in {"string", "number"}:
            depth += 1
            i += 1
            continue
        name = str(token.value).upper()
        if name == ":":
            i, defined = _skip_colon(tokens, i, errors)
            if defined:
                words[defined] = Contract(0, 0, frozenset())
            continue
        contract = words.get(name)
        if contract is None:
            errors.append(f"token {token.index}: unknown word {token.value}")
            i += 1
            continue
        if depth < contract.inputs:
            errors.append(f"token {token.index}: stack underflow at {name}")
            depth = 0
        else:
            depth -= contract.inputs
        depth += contract.outputs
        effects.update(contract.effects)
        if name == "WRITE-FILE":
            path = _literal_before(tokens, i)
            if path is not None:
                try:
                    rel = policies[0].relative(path)
                except ValueError as exc:
                    errors.append(f"token {token.index}: {exc}")
                else:
                    reason = _policies_deny(policies, rel)
                    if reason:
                        errors.append(f"token {token.index}: {reason}")
        if name == "USE-ARTIFACT":
            path = _literal_before(tokens, i)
            if path is not None and path not in artifacts:
                errors.append(f"token {token.index}: no artifact: {path}")
        i += 1

    excess = effects - set(allowed_effects)
    if excess:
        errors.append(f"effects not allowed: {', '.join(sorted(excess))}")
    return {
        "errors": errors,
        "final_depth": depth,
        "effects": sorted(effects),
    }


def _policies_deny(policies: list[PathPolicy], rel: str) -> str | None:
    for policy in policies:
        reason = policy.write_allowed(rel)
        if reason:
            return reason
    return None


def _skip_colon(tokens: list[Token], i: int, errors: list[str]) -> tuple[int, str | None]:
    if i + 1 >= len(tokens) or tokens[i + 1].kind != "word":
        errors.append(f"token {tokens[i].index}: expected name after :")
        return i + 1, None
    defined = str(tokens[i + 1].value).upper()
    j = i + 2
    while j < len(tokens):
        token = tokens[j]
        if token.kind == "word" and str(token.value).upper() == ";":
            return j + 1, defined
        if token.kind == "word" and str(token.value).upper() == ":":
            errors.append(f"token {token.index}: nested colon definitions are not supported")
            return j + 1, None
        j += 1
    errors.append("unterminated colon definition")
    return len(tokens), None


def _literal_before(tokens: list[Token], word_index: int) -> str | None:
    if word_index == 0:
        return None
    prev = tokens[word_index - 1]
    if prev.kind == "string":
        return str(prev.value)
    return None


def _dummy_root():
    from pathlib import Path

    return Path("/workspace").resolve()
