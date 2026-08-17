"""Run a Forth envelope against the capability host, with crash resume."""

from __future__ import annotations

import hashlib
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .dictionary import compose_program, load_prelude, loaded_names, save_colon_words, tokens_to_source, used_names
from .envelope import GraphNode, PlanEnvelope, cycle_message, kahn_order, load_task_graph, parse_envelope
from .forth import ForthError, ForthVM, Token, tokenize
from .host import CapabilityError, CapabilityHost
from .policy import PathPolicy
from .preflight import validate, write_sets_overlap
from .trace import append_events, emit
from .wave import WavePlanError, compute_metrics, format_metrics, plan_waves, ready_nodes


def lower_artifact_writes(program: str, artifacts: dict[str, str] | None) -> str:
    """Drop `S\" k\" WRITE-FILE` when k is an artifact key.

    The host installs artifacts after Accept. Those writes are already
    on disk (idempotent), so a 1-arity WRITE-FILE must not underflow.
    Does not insert USE-ARTIFACT.
    """
    keys = set(artifacts or {})
    if not keys or not program:
        return program
    try:
        tokens = tokenize(program)
    except Exception:
        return program
    kept = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        nxt = tokens[index + 1] if index + 1 < len(tokens) else None
        if (
            token.kind == "string"
            and str(token.value) in keys
            and nxt is not None
            and nxt.kind == "word"
            and str(nxt.value).upper() == "WRITE-FILE"
        ):
            index += 2
            continue
        kept.append(token)
        index += 1
    return tokens_to_source(kept)


def prepare_program(envelope: PlanEnvelope, dictionary_dir: str | None = None) -> str:
    prelude = load_prelude(dictionary_dir)
    source = envelope.effective_program()
    return compose_program(prelude, lower_artifact_writes(source, envelope.artifacts))


def _artifact_keys_for_node(node: GraphNode, artifacts: dict[str, str], workspace) -> list[str]:
    globs = node.write_globs()
    if not globs:
        return []
    policy = PathPolicy(workspace, globs, ())
    keys: list[str] = []
    for path in artifacts:
        if not isinstance(artifacts[path], str):
            continue
        try:
            rel = policy.relative(path)
        except ValueError:
            continue
        if policy.write_allowed(rel) is None:
            keys.append(path)
    return sorted(keys)


def install_artifacts(
    host: CapabilityHost,
    artifacts: dict[str, str],
    trace: str | None,
    nodes: list[GraphNode] | None = None,
) -> None:
    """Artifacts are the write set. Envelope nodes retarget graph.node.* ids."""
    if nodes:
        ordered, leftover = kahn_order(nodes)
        if leftover:
            raise ExecutionError("graph", "dependency cycle")
        for node in ordered:
            if trace:
                emit(trace, "graph.node.start", {"node": node.id, "worker": "host"})
            try:
                for path in _artifact_keys_for_node(node, artifacts, host.workspace):
                    host.write_file(artifacts[path], path)
            except CapabilityError as exc:
                if trace:
                    emit(
                        trace,
                        "graph.node.finish",
                        {
                            "node": node.id,
                            "status": "fail",
                            "worker": "host",
                            "detail": str(exc),
                        },
                    )
                raise
            if trace:
                emit(
                    trace,
                    "graph.node.finish",
                    {"node": node.id, "status": "ok", "worker": "host"},
                )
        return
    for path in sorted(artifacts):
        content = artifacts[path]
        if not isinstance(content, str):
            continue
        if trace:
            emit(trace, "graph.node.start", {"node": path, "worker": "host"})
        try:
            host.write_file(content, path)
        except CapabilityError as exc:
            if trace:
                emit(
                    trace,
                    "graph.node.finish",
                    {"node": path, "status": "fail", "worker": "host", "detail": str(exc)},
                )
            raise
        if trace:
            emit(trace, "graph.node.finish", {"node": path, "status": "ok", "worker": "host"})


class ExecutionError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        details: list[str] | None = None,
        *,
        node: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or []
        self.node = node


def checkpoint_path(request: dict[str, Any]) -> Path:
    receipt = Path(request["receipt_path"])
    return receipt.with_name("checkpoint.json")


def save_checkpoint(request: dict[str, Any], envelope: PlanEnvelope) -> None:
    path = checkpoint_path(request)
    path.write_text(
        json.dumps(
            {
                "envelope": envelope.to_dict(),
                "workspace": request["workspace"],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def load_checkpoint(request: dict[str, Any]) -> PlanEnvelope | None:
    path = checkpoint_path(request)
    if not path.exists():
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    return parse_envelope(payload["envelope"])


def _truthy(value: Any) -> bool:
    if value is True:
        return True
    if isinstance(value, str) and value.strip().lower() in {"1", "true", "yes", "on"}:
        return True
    if value == 1:
        return True
    return False


def resolve_wave_workers(
    request: dict[str, Any] | None,
    *,
    wave_workers: int | None = None,
    serial: bool = False,
) -> int:
    if serial:
        return 1
    if request is not None and _truthy(request.get("serial")):
        return 1
    if request is not None:
        raw = request.get("wave_workers")
        if raw is not None and raw != "":
            try:
                return max(1, int(raw))
            except (TypeError, ValueError):
                pass
    if wave_workers is not None:
        return max(1, int(wave_workers))
    env_serial = os.environ.get("LIVINGDICT_SERIAL", "").strip().lower()
    if env_serial in {"1", "true", "yes", "on"}:
        return 1
    env_n = os.environ.get("LIVINGDICT_WAVE_WORKERS", "").strip()
    if env_n:
        try:
            return max(1, int(env_n))
        except ValueError:
            pass
    return 4


@dataclass
class NodeOutcome:
    node_id: str
    events: list[dict[str, Any]] = field(default_factory=list)
    colon: dict[str, list[Token]] = field(default_factory=dict)
    effects: set[str] = field(default_factory=set)
    last_check: dict[str, Any] | None = None
    trap: tuple[str, str] | None = None
    start: str = ""
    finish: str = ""
    stack_depth: int = 0


def _copy_colon(colon: dict[str, list[Token]]) -> dict[str, list[Token]]:
    return {name: list(body) for name, body in colon.items()}


def _event_ts(events: list[dict[str, Any]], kind: str) -> str:
    for event in events:
        if event.get("type") == kind:
            return str(event.get("timestamp") or "")
    return ""


def _sibling_write_globs(wave: list[GraphNode], node: GraphNode) -> tuple[str, ...]:
    extra: list[str] = []
    for other in wave:
        if other.id == node.id:
            continue
        extra.extend(other.write_globs())
    return tuple(extra)


def _wave_overlap_count(wave: list[GraphNode]) -> int:
    count = 0
    for index, left in enumerate(wave):
        for right in wave[index + 1 :]:
            if write_sets_overlap(left.write_globs(), right.write_globs()):
                count += 1
    return count


def _run_one_node(
    host: CapabilityHost,
    node: GraphNode,
    artifacts: dict[str, str],
    prelude: str,
    colon_seed: dict[str, list[Token]],
    sibling_globs: tuple[str, ...] = (),
) -> NodeOutcome:
    view = host.node_view(node.write_globs(), extra_forbidden=sibling_globs)
    outcome = NodeOutcome(node_id=node.id)
    view.emit_event("graph.node.start", {"node": node.id, "worker": "host"})
    hook = host.node_start_hook
    if hook is not None:
        hook(node.id)
    try:
        covered = _artifact_keys_for_node(node, artifacts, host.workspace)
        for path in covered:
            view.write_file(artifacts[path], path)
        machine = ForthVM(view, artifacts=artifacts)
        machine.colon.update(_copy_colon(colon_seed))
        owned = {path: artifacts[path] for path in covered}
        source = compose_program(prelude, lower_artifact_writes(node.program, owned))
        if source.strip():
            machine.interpret(source)
        outcome.colon = _copy_colon(machine.colon)
        outcome.stack_depth = len(machine.stack)
        view.emit_event("graph.node.finish", {"node": node.id, "status": "ok", "worker": "host"})
    except (CapabilityError, ForthError) as exc:
        outcome.trap = (exc.code, exc.message)
        view.emit_event(
            "execution.trap",
            {"reason": exc.code, "detail": exc.message, "node": node.id},
        )
        view.emit_event(
            "graph.node.finish",
            {
                "node": node.id,
                "status": "fail",
                "worker": "host",
                "detail": exc.message,
            },
        )
    except Exception as exc:
        outcome.trap = ("error", str(exc))
        view.emit_event(
            "execution.trap",
            {"reason": "error", "detail": str(exc), "node": node.id},
        )
        view.emit_event(
            "graph.node.finish",
            {
                "node": node.id,
                "status": "fail",
                "worker": "host",
                "detail": str(exc),
            },
        )
    outcome.events = list(view._event_sink or [])
    outcome.effects = set(view._effects_used)
    outcome.last_check = view._last_check
    outcome.start = _event_ts(outcome.events, "graph.node.start")
    outcome.finish = _event_ts(outcome.events, "graph.node.finish")
    return outcome


def _merge_wave(
    host: CapabilityHost,
    wave: list[GraphNode],
    outcomes: dict[str, NodeOutcome],
    accumulated_colon: dict[str, list[Token]],
    timings: dict[str, tuple[str, str]],
    trapped: dict[str, tuple[str, str]],
    completed: set[str],
    last_stack: list[int],
) -> None:
    for node in wave:
        result = outcomes[node.id]
        append_events(host.trace_path, result.events)
        host._effects_used.update(result.effects)
        if result.last_check is not None:
            host._last_check = result.last_check
        if result.start and result.finish:
            timings[node.id] = (result.start, result.finish)
        last_stack[0] = result.stack_depth
        if result.trap:
            trapped[node.id] = result.trap
            continue
        completed.add(node.id)
        for name in sorted(result.colon):
            accumulated_colon[name] = list(result.colon[name])


def execute_waves(
    host: CapabilityHost,
    nodes: list[GraphNode],
    artifacts: dict[str, str],
    *,
    prelude: str = "",
    workers: int = 4,
    trace: bool = True,
) -> dict[str, Any]:
    """Run accepted nodes by wave. OpenResty stays on serial install_artifacts."""
    try:
        planned = plan_waves(nodes)
    except WavePlanError as exc:
        raise ExecutionError("graph", str(exc)) from exc

    remaining = {node.id for node in nodes}
    completed: set[str] = set()
    trapped: dict[str, tuple[str, str]] = {}
    timings: dict[str, tuple[str, str]] = {}
    accumulated_colon: dict[str, list[Token]] = {}
    last_stack = [0]
    conflict_count = 0
    started = time.perf_counter()
    wave_index = 0

    while remaining:
        ready = [node for node in ready_nodes(nodes, completed) if node.id in remaining]
        if not ready:
            if remaining and not trapped:
                raise ExecutionError("graph", cycle_message(nodes))
            break
        cap = max(1, min(len(ready), workers))
        colon_seed = _copy_colon(accumulated_colon)
        outcomes: dict[str, NodeOutcome] = {}
        conflict_count += _wave_overlap_count(ready)
        if cap == 1:
            for node in ready:
                outcomes[node.id] = _run_one_node(
                    host,
                    node,
                    artifacts,
                    prelude,
                    colon_seed,
                    _sibling_write_globs(ready, node),
                )
        else:
            with ThreadPoolExecutor(max_workers=cap) as pool:
                futures = {
                    node.id: pool.submit(
                        _run_one_node,
                        host,
                        node,
                        artifacts,
                        prelude,
                        colon_seed,
                        _sibling_write_globs(ready, node),
                    )
                    for node in ready
                }
                for node in ready:
                    outcomes[node.id] = futures[node.id].result()
        _merge_wave(
            host,
            ready,
            outcomes,
            accumulated_colon,
            timings,
            trapped,
            completed,
            last_stack,
        )
        for node in ready:
            remaining.discard(node.id)
        if "exec" in host.allowed_effects:
            report = host.run_gates(persist=False)
            if trace:
                emit(
                    host.trace_path,
                    "graph.wave.gates",
                    {
                        "wave": wave_index,
                        "passed": bool(report.get("passed")),
                        "nodes": [node.id for node in ready],
                    },
                )
        wave_index += 1

    wall_ms = int(round((time.perf_counter() - started) * 1000))
    metrics = compute_metrics(planned, timings, wall_ms, conflicts=conflict_count)
    host.graph_metrics = metrics
    if trace:
        emit(host.trace_path, "graph.metrics", dict(metrics))
    return {
        "defined": sorted(accumulated_colon),
        "colon": accumulated_colon,
        "stack_depth": last_stack[0],
        "trapped": trapped,
        "completed": sorted(completed),
        "graph": metrics,
    }


def run_forth(
    host: CapabilityHost,
    envelope: PlanEnvelope,
    *,
    preflight: bool,
    request: dict[str, Any] | None = None,
    resume: bool = False,
    wave_workers: int | None = None,
    serial: bool = False,
) -> dict[str, Any]:
    if envelope.language not in {"forth", "forth-shen"}:
        raise ExecutionError("language", f"unsupported envelope language: {envelope.language}")

    dict_dir = request.get("dictionary_dir") if request is not None else None
    prelude = load_prelude(dict_dir)
    program = prepare_program(envelope, dict_dir)
    task_graph = None
    if request is not None:
        graph_path = request.get("graph_path")
        if graph_path:
            task_graph = load_task_graph(graph_path)
        else:
            task_graph = load_task_graph(Path(request["workspace"]) / "task_graph.json")

    if preflight:
        result = validate(
            program,
            set(host.allowed_effects),
            host.allowed_globs,
            host.forbidden_globs,
            envelope.artifacts,
            nodes=envelope.nodes,
            task_graph=task_graph,
        )
        if not result["valid"]:
            if request is not None:
                emit(
                    host.trace_path,
                    "preflight.rejected",
                    {"errors": result["errors"], "effects": result["effects"]},
                )
            raise ExecutionError("preflight", "preflight rejected program", result["errors"])

    if request is not None and not resume:
        save_checkpoint(request, envelope)

    if request is not None and prelude:
        known = loaded_names(dict_dir)
        emit(host.trace_path, "dictionary.retrieve", {"query": "*", "candidates": known})
        for name in used_names(envelope.effective_program(), known):
            emit(host.trace_path, "dictionary.reuse", {"word": name, "version": 1})

    workers = resolve_wave_workers(request, wave_workers=wave_workers, serial=serial)
    extra: dict[str, Any]
    machine: ForthVM | None = None
    if envelope.nodes:
        extra = execute_waves(
            host,
            envelope.nodes,
            envelope.artifacts,
            prelude=prelude,
            workers=workers,
            trace=request is not None,
        )
        trapped = extra.get("trapped") or {}
        if trapped:
            details = [
                f"node {ident}: {code}: {message}"
                for ident, (code, message) in sorted(trapped.items())
            ]
            first_id = next(iter(sorted(trapped)))
            code, message = trapped[first_id]
            raise ExecutionError(code, message, details, node=first_id)
        colon = extra.get("colon") or {}
        if dict_dir:
            for name in save_colon_words(dict_dir, colon):
                if request is not None:
                    emit(
                        host.trace_path,
                        "dictionary.promote",
                        {"evidence": "colon", "version": 1, "word": name},
                    )
        return {
            "stack_depth": extra.get("stack_depth", 0),
            "defined": extra.get("defined") or [],
            "program_hash": hashlib.sha256(envelope.program.encode("utf-8")).hexdigest(),
            "graph": extra.get("graph") or {},
        }

    machine = ForthVM(host, artifacts=envelope.artifacts)
    try:
        install_artifacts(
            host,
            envelope.artifacts,
            host.trace_path if request is not None else None,
            nodes=None,
        )
        machine.interpret(program)
    except CapabilityError as exc:
        if request is not None:
            emit(host.trace_path, "execution.trap", {"reason": exc.code, "detail": exc.message})
        raise ExecutionError(exc.code, exc.message) from exc
    except ForthError as exc:
        if request is not None:
            emit(host.trace_path, "execution.trap", {"reason": exc.code, "detail": exc.message})
        raise ExecutionError(exc.code, exc.message) from exc

    if dict_dir:
        for name in save_colon_words(dict_dir, machine.colon):
            if request is not None:
                emit(
                    host.trace_path,
                    "dictionary.promote",
                    {"evidence": "colon", "version": 1, "word": name},
                )

    return {
        "stack_depth": len(machine.stack),
        "defined": sorted(machine.colon),
        "program_hash": hashlib.sha256(envelope.program.encode("utf-8")).hexdigest(),
    }


def metrics_line(metrics: dict[str, Any] | None) -> str:
    if not metrics:
        return ""
    return format_metrics(metrics)
