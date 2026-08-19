"""Run a Forth envelope against the capability host, with crash resume."""

from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

from .dictionary import compose_program, load_prelude, loaded_names, save_colon_words, tokens_to_source, used_names, words_dir
from .envelope import GraphNode, PlanEnvelope, cycle_message, kahn_order, load_task_graph, parse_envelope
from .forth import ForthError, ForthVM, Token, tokenize
from .host import CapabilityError, CapabilityHost
from .policy import PathPolicy
from .preflight import validate, write_sets_overlap
from .space import Space
from .trace import append_events, emit, make_event
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


def lower_node_programs(
    nodes: list[GraphNode] | None,
    artifacts: dict[str, str] | None,
    workspace,
) -> list[GraphNode] | None:
    """Node programs as they will actually run: artifact writes lowered.

    The critic must see the program that executes. prepare_program already
    normalizes the top-level program; without this, `S" k" WRITE-FILE`
    inside a node underflows at validation even though execution would
    lower it — the fizzbuzz reject resurrected one level down. Lowering
    uses the same per-node owned-artifact set as execution.
    """
    if not nodes:
        return nodes
    lowered: list[GraphNode] = []
    for node in nodes:
        owned = {
            key: (artifacts or {})[key]
            for key in _artifact_keys_for_node(node, artifacts or {}, workspace)
        }
        lowered.append(replace(node, program=lower_artifact_writes(node.program, owned)))
    return lowered


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
    claim: Any = None,
) -> NodeOutcome:
    view = host.node_view(node.write_globs(), extra_forbidden=sibling_globs)
    view._space = getattr(host, "_space", None)
    view._space_claim = claim
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
    space_buffers: dict[str, list[dict[str, Any]]] | None = None,
) -> None:
    space_buffers = space_buffers if space_buffers is not None else {}
    for node in wave:
        result = outcomes[node.id]
        prefix = space_buffers.pop(node.id, [])
        append_events(host.trace_path, prefix + result.events)
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


class _WaveSession:
    def __init__(self, space: Space, expected: set[str]) -> None:
        self.space = space
        self.expected = set(expected)
        self.outcomes: dict[str, NodeOutcome] = {}
        self._lock = threading.Lock()
        self.done = threading.Event()

    def finish(self, node_id: str, outcome: NodeOutcome) -> None:
        with self._lock:
            if node_id in self.outcomes:
                return
            self.outcomes[node_id] = outcome
            if self.expected <= set(self.outcomes):
                self.done.set()
        if self.done.is_set():
            self.space.wake()


def _attach_space(
    host: CapabilityHost,
) -> tuple[Space, dict[str, list[dict[str, Any]]], list[dict[str, Any]], Any]:
    space = getattr(host, "_space", None)
    if space is None:
        space = Space(store=getattr(host, "_store", None))
        host._space = space
    buffers: dict[str, list[dict[str, Any]]] = {}
    extra: list[dict[str, Any]] = []
    lock = threading.Lock()
    previous = space.record

    def record(kind: str, payload: dict[str, Any]) -> None:
        event = make_event(kind, dict(payload or {}))
        node = (payload or {}).get("node")
        with lock:
            if node is not None and str(node) != "":
                buffers.setdefault(str(node), []).append(event)
            else:
                extra.append(event)

    space.record = record
    return space, buffers, extra, lambda: setattr(space, "record", previous)


def _flush_space_extras(
    host: CapabilityHost,
    buffers: dict[str, list[dict[str, Any]]],
    extra: list[dict[str, Any]],
) -> None:
    events: list[dict[str, Any]] = []
    for key in sorted(buffers):
        events.extend(buffers.pop(key))
    events.extend(extra)
    extra.clear()
    if events:
        append_events(host.trace_path, events)


def _space_worker(
    worker_id: str,
    host: CapabilityHost,
    nodes_by_id: dict[str, GraphNode],
    ready: list[GraphNode],
    artifacts: dict[str, str],
    prelude: str,
    colon_seed: dict[str, list[Token]],
    space: Space,
    lease_s: float,
    wave_index: int,
    session: _WaveSession,
) -> None:
    pattern = {"kind": "node.ready", "wave": wave_index}
    death_hook = host.node_death_hook
    while not session.done.is_set():
        claim = space.take(pattern, lease_s, worker_id, timeout=None, stop=session.done)
        if claim is None:
            return
        node_id = str(claim.tuple.get("node") or "")
        node = nodes_by_id.get(node_id)
        if node is None:
            space.ack(claim.token)
            continue
        if death_hook is not None:
            try:
                death_hook(node.id)
            except Exception:
                # Injected worker death: expire the lease so a sibling may take.
                # Node writes are whole-file and idempotent (WRITE-FILE identical
                # bytes), so re-execution after lease expiry is safe.
                space.expire(claim.token)
                continue
        outcome = _run_one_node(
            host,
            node,
            artifacts,
            prelude,
            colon_seed,
            _sibling_write_globs(ready, node),
            claim=claim,
        )
        if not space.is_current(claim) or not space.ack(claim.token):
            continue
        session.finish(node.id, outcome)


def execute_waves(
    host: CapabilityHost,
    nodes: list[GraphNode],
    artifacts: dict[str, str],
    *,
    prelude: str = "",
    workers: int = 4,
    trace: bool = True,
) -> dict[str, Any]:
    """Run accepted nodes by wave. OpenResty stays on serial install_artifacts.

    The host `out`s critic-approved ready nodes; workers only `take`. Serial
    (`workers==1`) is still one worker taking in lex node-id / oldest-first
    order so the ledger records a schedule.
    """
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
    nodes_by_id = {node.id: node for node in nodes}
    run_id = host.run_id or ""
    episode = int(getattr(host, "episode", 0) or 0)
    space, buffers, extra_events, restore_record = _attach_space(host)
    lease_s = float(host.test_timeout_seconds or 60)

    try:
        while remaining:
            ready = [node for node in ready_nodes(nodes, completed) if node.id in remaining]
            if not ready:
                if remaining and not trapped:
                    raise ExecutionError("graph", cycle_message(nodes))
                break
            cap = max(1, min(len(ready), workers))
            colon_seed = _copy_colon(accumulated_colon)
            conflict_count += _wave_overlap_count(ready)
            for node in ready:
                space.out(
                    {
                        "kind": "node.ready",
                        "run": run_id,
                        "episode": episode,
                        "wave": wave_index,
                        "node": node.id,
                    }
                )
            session = _WaveSession(space, {node.id for node in ready})
            if cap == 1:
                _space_worker(
                    "w0",
                    host,
                    nodes_by_id,
                    ready,
                    artifacts,
                    prelude,
                    colon_seed,
                    space,
                    lease_s,
                    wave_index,
                    session,
                )
            else:
                with ThreadPoolExecutor(max_workers=cap) as pool:
                    futures = [
                        pool.submit(
                            _space_worker,
                            f"w{index}",
                            host,
                            nodes_by_id,
                            ready,
                            artifacts,
                            prelude,
                            colon_seed,
                            space,
                            lease_s,
                            wave_index,
                            session,
                        )
                        for index in range(cap)
                    ]
                    for future in futures:
                        future.result()
            if set(session.outcomes) != {node.id for node in ready}:
                raise ExecutionError("graph", "wave did not resolve all ready nodes")
            _merge_wave(
                host,
                ready,
                session.outcomes,
                accumulated_colon,
                timings,
                trapped,
                completed,
                last_stack,
                buffers,
            )
            for node in ready:
                remaining.discard(node.id)
            if "exec" in host.allowed_effects:
                report = host.run_gates(persist=False)
                passed = bool(report.get("passed"))
                _flush_space_extras(host, buffers, extra_events)
                if trace:
                    emit(
                        host.trace_path,
                        "graph.wave.gates",
                        {
                            "wave": wave_index,
                            "passed": passed,
                            "nodes": [node.id for node in ready],
                        },
                    )
            else:
                _flush_space_extras(host, buffers, extra_events)
            wave_index += 1
    finally:
        restore_record()

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
            nodes=lower_node_programs(envelope.nodes, envelope.artifacts, host.workspace),
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
    store = getattr(host, "_store", None)
    if store is not None:
        for key, body in envelope.artifacts.items():
            if isinstance(body, str):
                store.intern(body.encode("utf-8"))
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
        promoted = _promote_colon(dict_dir, colon, store, host.trace_path if request is not None else None)
        return {
            "stack_depth": extra.get("stack_depth", 0),
            "defined": extra.get("defined") or [],
            "program_hash": hashlib.sha256(envelope.program.encode("utf-8")).hexdigest(),
            "graph": extra.get("graph") or {},
            "promoted": promoted,
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

    promoted = _promote_colon(
        dict_dir,
        machine.colon,
        store,
        host.trace_path if request is not None else None,
    )

    return {
        "stack_depth": len(machine.stack),
        "defined": sorted(machine.colon),
        "program_hash": hashlib.sha256(envelope.program.encode("utf-8")).hexdigest(),
        "promoted": promoted,
    }


def _promote_colon(
    dict_dir: str | None,
    colon: dict[str, list[Token]],
    store: Any,
    trace: str | Path | None,
) -> list[dict[str, str]]:
    if not dict_dir:
        return []
    written = save_colon_words(dict_dir, colon, store=store)
    root = words_dir(dict_dir)
    promoted: list[dict[str, str]] = []
    for name in written:
        digest = ""
        if root is not None:
            path = root / f"{name}.fs"
            if path.is_file():
                data = path.read_bytes()
                digest = store.intern(data) if store is not None else hashlib.sha256(data).hexdigest()
        promoted.append({"word": name, "sha256": digest})
        if trace is not None:
            emit(trace, "dictionary.promote", {"evidence": "colon", "version": 1, "word": name})
    return promoted


def metrics_line(metrics: dict[str, Any] | None) -> str:
    if not metrics:
        return ""
    return format_metrics(metrics)
