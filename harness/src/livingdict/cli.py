"""Headless livingdict loop: planner → critic → artifacts → Forth → RUN-GATES.

The model is off while words run. Job state lives in the run dir.
"""

from __future__ import annotations

import argparse
import contextvars
import hashlib
import json
import os
import shlex
import subprocess
import sys
import threading
import re
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .envelope import EnvelopeError, PlanEnvelope, load_task_graph, parse_envelope
from .execute import ExecutionError, lower_node_programs, metrics_line, prepare_program, run_forth
from .gates import run_gates
from .host import CapabilityHost
from .preflight import validate
from .kernel import (
    ARTIFACTS_APPLIED,
    BUDGET_CONSUMED,
    CONTRACT_APPROVED,
    CRITIC_ACCEPTED,
    CRITIC_REJECTED,
    DECISION_SUCCESS,
    DICTIONARY_PROMOTED,
    PROMOTION_EVIDENCE,
    EPISODE_BLOCKED_DUPLICATE,
    EPISODE_PLANNED,
    GATES_MEASURED,
    Decision,
    Event,
    KernelError,
    State,
    empty_state,
    event_to_dict,
    fingerprint,
    reconcile,
    reduce,
)
from .policy import changed_files, snapshot
from .rho import grant_mode_require
from .space import Space
from .trace import emit as trace_emit
from .store import artifact_digests, capture_tree, intern_snapshot, open_store
from .promotion import evidence_for


REPO = Path(__file__).resolve().parents[3]

DEFAULT_ALLOWED = ("**",)
DEFAULT_FORBIDDEN = (
    ".git",
    ".git/**",
    ".livingdict-run",
    ".livingdict-run/**",
    "node_modules",
    "node_modules/**",
    "__pycache__",
    "__pycache__/**",
    ".sb",
    ".sb/**",
    "dist",
    "dist/**",
    "build",
    "build/**",
)
DEFAULT_MAX_TURNS = 32
BOOKKEEPING_PATHS = {
    "claims.json",
}


def _meaningful_changed_files(changed: list[str]) -> list[str]:
    """Exclude harness bookkeeping from the product-progress signal."""
    return [
        rel
        for rel in changed
        if rel not in BOOKKEEPING_PATHS
        and not rel.startswith((".livingdict-run/", ".sb/"))
    ]


def _json_digest(text: str) -> str:
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        value = text
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


_BEHAVIOR_WORDS = re.compile(
    r"\b(run|execute|output|print|sample|serve|server|http|api|respond|render|"
    r"request|response|compile and run|program)\b",
    re.IGNORECASE,
)
_STRUCTURAL_CHECK = re.compile(
    r"^(?:(?:gcc|g\+\+|clang|cc)\b|test\s+-[efxbs]|(?:wc|grep|sed|awk)\b)",
    re.IGNORECASE,
)
_BEHAVIORAL_CHECK = re.compile(
    r"(?:pytest|unittest|npm\s+(?:test|run)|cargo\s+test|go\s+test|mvn\s+test|"
    r"curl\b|wget\b|assert|diff\b|expected|output|stdout|http://|https://|"
    r"(?:^|\s)(?:\./|python(?:3)?\s+|node\s+|ruby\s+|java\s+))",
    re.IGNORECASE,
)


def _goal_requires_behavior(goal: str) -> bool:
    return bool(_BEHAVIOR_WORDS.search(goal or ""))


def _is_behavioral_check(command: str) -> bool:
    command = command.strip()
    if not command or _STRUCTURAL_CHECK.match(command):
        return False
    return bool(_BEHAVIORAL_CHECK.search(command))


def _claim_quality(report: dict[str, Any], goal: str = "") -> dict[str, Any]:
    """Audit model-authored claims without treating them as benchmark scores."""
    claim_gate = next(
        (gate for gate in report.get("gates") or [] if gate.get("name") == "claims"),
        {},
    )
    claims = claim_gate.get("claims") or []
    kinds = {str(item.get("kind") or "source").lower() for item in claims if isinstance(item, dict)}
    source_only = bool(claims) and kinds <= {"source", "file", "absent"}
    checks = [item for item in claims if isinstance(item, dict) and str(item.get("kind") or "").lower() == "check"]
    has_behavioral_check = any(_is_behavioral_check(str(item.get("command") or "")) for item in checks)
    requires_behavior = _goal_requires_behavior(goal)
    warnings: list[str] = []
    if source_only:
        warnings.append("claims are source/file presence only; add behavior or executable checks")
    if requires_behavior and checks and not has_behavioral_check:
        warnings.append("behavior-oriented goal has no runtime behavioral check")
    return {
        "source_only": source_only,
        "claim_count": len(claims),
        "has_executable_check": "check" in kinds,
        "requires_behavior": requires_behavior,
        "has_behavioral_check": has_behavioral_check,
        "warnings": warnings,
    }


class CLIError(Exception):
    pass


def default_planner_cmd() -> list[str]:
    planner = REPO / "client" / "planner.py"
    return [sys.executable, str(planner), "--stdin"]


def resolve_argv_files(cmd: list[str], origin: Path | None = None) -> list[str]:
    """Absolutize argv files before a planner subprocess uses cwd=workspace.

    Lookup order: invocation directory, then the livingdict repo root.
    `harness/tests/fizzbuzz_planner.py` must not be resolved under --cwd.
    """
    root = Path(origin).resolve() if origin is not None else Path.cwd().resolve()
    resolved: list[str] = []
    for arg in cmd:
        if not arg or arg.startswith("-") or os.path.isabs(arg):
            resolved.append(arg)
            continue
        for base in (root, REPO):
            candidate = base / arg
            if candidate.exists():
                resolved.append(str(candidate.resolve()))
                break
        else:
            resolved.append(arg)
    return resolved


def ensure_run_files(run_dir: Path, goal: str, episode: int) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    goal_path = run_dir / "GOAL.md"
    progress_path = run_dir / "PROGRESS.md"
    body = f"# GOAL\n\n{goal.strip()}\n"
    if int(episode) <= 1:
        goal_path.write_text(body, encoding="utf-8")
        if not progress_path.is_file():
            progress_path.write_text("# PROGRESS\n\n", encoding="utf-8")
        return
    if not goal_path.is_file():
        goal_path.write_text(body, encoding="utf-8")
    if not progress_path.is_file():
        progress_path.write_text("# PROGRESS\n\n", encoding="utf-8")


def append_progress(run_dir: Path, episode: int, lines: list[str]) -> None:
    path = run_dir / "PROGRESS.md"
    prev = path.read_text(encoding="utf-8") if path.is_file() else "# PROGRESS\n"
    block = ["", f"## episode {episode}", ""] + lines + [""]
    path.write_text(prev + "\n".join(block), encoding="utf-8")


def append_reject(run_dir: Path, episode: int, errors: list[str], program: str) -> None:
    path = run_dir / "rejects.jsonl"
    record = {"episode": episode, "errors": errors, "program": program}
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")


def forbidden_for(workspace: Path, run_dir: Path) -> tuple[str, ...]:
    extra: list[str] = list(DEFAULT_FORBIDDEN)
    try:
        rel = run_dir.resolve().relative_to(workspace.resolve())
    except ValueError:
        return tuple(extra)
    posix = rel.as_posix()
    if posix and posix != ".":
        extra.append(posix)
        extra.append(posix + "/**")
    return tuple(extra)


def commit(state: State, kind: str, payload: dict[str, Any] | None, events_path: Path) -> State:
    new = reduce(state, Event(kind=kind, payload=dict(payload or {})))
    stored = new.events[-1]
    events_path.parent.mkdir(parents=True, exist_ok=True)
    with events_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event_to_dict(stored), sort_keys=True) + "\n")
    return new


def call_planner(cmd: list[str], observation: dict[str, Any], *, workspace: Path) -> PlanEnvelope:
    payload = call_planner_json(cmd, observation, workspace=workspace)
    try:
        return parse_envelope(payload)
    except EnvelopeError as exc:
        raise CLIError(str(exc)) from exc


def call_planner_json(cmd: list[str], observation: dict[str, Any], *, workspace: Path) -> dict[str, Any]:
    env = os.environ.copy()
    client = str(REPO / "client")
    current = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = client if not current else client + os.pathsep + current
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(workspace),
            env=env,
        )
    except OSError as exc:
        raise CLIError(f"planner failed to start: {exc}") from exc

    stderr_lines: list[str] = []

    def pump_stderr() -> None:
        # The planner's stderr is the live "thinking" channel: forward each
        # line as a planner.stderr trace event while the call is in flight.
        assert proc.stderr is not None
        for line in proc.stderr:
            text = line.rstrip("\n")
            stderr_lines.append(text)
            trace_emit(None, "planner.stderr", {"line": text})

    ctx = contextvars.copy_context()  # carry the live sink into the thread
    pump = threading.Thread(target=lambda: ctx.run(pump_stderr), daemon=True)
    pump.start()
    try:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(observation, ensure_ascii=False))
        proc.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    out = proc.stdout.read() if proc.stdout is not None else ""
    proc.wait()
    pump.join(timeout=5)
    if proc.returncode != 0:
        err = ("\n".join(stderr_lines) or out or "planner exited non-zero").strip()
        raise CLIError(f"planner exit {proc.returncode}: {err[:800]}")
    raw = (out or "").strip()
    if not raw:
        raise CLIError("planner wrote no envelope")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CLIError(f"planner stdout is not JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise CLIError("planner stdout is not a JSON object")
    return payload


def claims_source(workspace: Path, claims_path: Path | None, label: str | None = None) -> str:
    """Who authored the judge: 'approved' (user signed off on a contract),
    'hidden' (host/user file), 'workspace' (a claims.json the model wrote —
    weak evidence), or 'none'."""
    if claims_path is not None and Path(claims_path).is_file():
        return label or "hidden"
    if (Path(workspace) / "claims.json").is_file():
        return "workspace"
    return "none"


def measure_workspace(
    workspace: Path,
    claims_path: Path | None,
    allow_check: bool = False,
) -> dict[str, Any]:
    dest = workspace / "claims.json"
    backup: str | None = None
    replaced = False
    if claims_path is not None and Path(claims_path).is_file():
        backup = dest.read_text(encoding="utf-8") if dest.is_file() else None
        dest.write_text(Path(claims_path).read_text(encoding="utf-8"), encoding="utf-8")
        replaced = True
    try:
        return run_gates(workspace, allow_check=allow_check)
    finally:
        if replaced:
            if backup is None:
                dest.unlink(missing_ok=True)
            else:
                dest.write_text(backup, encoding="utf-8")


def critic_extra(errors: list[str]) -> str:
    if not errors:
        return ""
    return "\n".join(f"critic: {item}" for item in errors)


def gate_feedback(report: dict[str, Any]) -> str:
    """Make failed behavioral checks actionable for the next planner turn.

    The compact gate stderr is useful for receipts but commonly omits the
    compiler/test output that explains a failure.  Preserve bounded details
    in planner backpressure so the model can repair the command or product.
    """
    lines: list[str] = []
    for gate in report.get("gates") or []:
        if not isinstance(gate, dict) or gate.get("passed") or gate.get("skipped"):
            continue
        lines.append(f"gate {gate.get('name') or '?'} failed: {gate.get('reason') or ''}".strip())
        for claim in gate.get("claims") or []:
            if not isinstance(claim, dict) or claim.get("passed"):
                continue
            detail = f"claim {claim.get('id') or '?'} failed"
            if claim.get("command"):
                detail += f"; command: {claim['command']}"
            if claim.get("reason"):
                detail += f"; reason: {claim['reason']}"
            output = str(claim.get("output") or claim.get("stderr") or "").strip()
            if output:
                detail += f"; output: {output[-2000:]}"
            lines.append(detail)
    return "\n".join(lines)


def _host(
    workspace: Path,
    run_dir: Path,
    forbidden: tuple[str, ...],
    *,
    allowed_globs: tuple[str, ...] = DEFAULT_ALLOWED,
    run_id: str = "livingdict",
) -> CapabilityHost:
    return CapabilityHost(
        workspace=workspace,
        allowed_effects=("read", "write", "exec"),
        allowed_globs=allowed_globs or DEFAULT_ALLOWED,
        forbidden_globs=forbidden,
        trace_path=run_dir / "trace.jsonl",
        receipt_path=run_dir / "receipt.json",
        run_id=run_id,
        task_id="goal",
        test_timeout_seconds=180,
    )


def run_job(
    goal: str,
    workspace: Path,
    *,
    max_turns: int = DEFAULT_MAX_TURNS,
    claims: Path | None = None,
    run_dir: Path | None = None,
    planner_cmd: list[str] | None = None,
    wave_workers: int = 4,
    serial: bool = False,
    allowed_globs: tuple[str, ...] | None = None,
    event_sink: Callable[[str, dict[str, Any]], None] | None = None,
    print_receipt: bool = True,
    deadline: datetime | None = None,
    run_id: str = "livingdict",
    system_prompt: str = "",
    receipt_extra: dict[str, Any] | None = None,
    grant_verified: bool = False,
    contract: dict[str, Any] | None = None,
    oracle_feedback: Callable[[Path, dict[str, Any]], dict[str, Any] | None] | None = None,
) -> tuple[int, dict[str, Any]]:
    workspace = Path(workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    run_dir = Path(run_dir).resolve() if run_dir is not None else workspace / ".livingdict-run"
    run_dir.mkdir(parents=True, exist_ok=True)
    claims_label = "approved" if contract is not None else None
    receipt_fields = dict(receipt_extra or {})
    receipt_fields.setdefault("claims_source", claims_source(workspace, claims, claims_label))
    if grant_mode_require() and not grant_verified:
        return _finish(
            Decision("grant_invalid", "grant.witness is required"),
            empty_state(),
            workspace,
            run_dir,
            snapshot(workspace),
            {},
            print_receipt=print_receipt,
            receipt_extra=receipt_fields,
        )
    (run_dir / "dictionary" / "words").mkdir(parents=True, exist_ok=True)
    (run_dir / "GOAL.md").write_text(f"# GOAL\n\n{goal.strip()}\n", encoding="utf-8")
    (run_dir / "PROGRESS.md").write_text("# PROGRESS\n\n", encoding="utf-8")

    events_path = run_dir / "events.jsonl"
    forbidden = forbidden_for(workspace, run_dir)
    cmd = list(planner_cmd) if planner_cmd else default_planner_cmd()
    state = empty_state()
    extra = ""
    oracle_note: dict[str, Any] | None = None
    frozen_contract = Path(claims) if claims is not None else run_dir / "contract.json"
    if isinstance(contract, (str, Path)):
        frozen_contract = Path(contract)
    elif isinstance(contract, dict):
        frozen_contract.write_text(json.dumps(contract, sort_keys=True), encoding="utf-8")
    store = open_store(run_dir)
    space = Space(store=store)
    before, job_tree_before = capture_tree(workspace, store)
    episode_tree_before = job_tree_before
    last_changed: list[str] = []
    last_graph: dict[str, Any] = {}
    globs = allowed_globs if allowed_globs is not None else DEFAULT_ALLOWED

    def _commit(current: State, kind: str, payload: dict[str, Any] | None) -> State:
        new = commit(current, kind, payload, events_path)
        if event_sink is not None:
            event_sink(kind, dict(payload or {}))
        return new

    if contract is not None:
        state = _commit(state, CONTRACT_APPROVED, dict(contract))

    while True:
        if deadline is not None and datetime.now(timezone.utc) >= deadline:
            return _finish(
                Decision("cancelled", "deadline"),
                state,
                workspace,
                run_dir,
                before,
                last_graph,
                print_receipt=print_receipt,
                receipt_extra=receipt_fields,
                tree_before=job_tree_before,
            )
        decision = reconcile(
            state,
            max_turns,
            stop_on_duplicates=not bool(receipt_fields.get("benchmark_mode")),
        )
        if decision.kind != "plan":
            return _finish(
                decision,
                state,
                workspace,
                run_dir,
                before,
                last_graph,
                print_receipt=print_receipt,
                receipt_extra=receipt_fields,
                tree_before=job_tree_before,
            )

        episode = state.used + 1
        ensure_run_files(run_dir, goal, episode)
        observation = {
            "dictionary": str(run_dir / "dictionary"),
            "episode": episode,
            "errors": list(state.last_errors),
            "extra": extra,
            "goal": goal,
            "run_dir": str(run_dir),
            "workspace": str(workspace),
        }
        if frozen_contract.is_file():
            observation["contract"] = json.loads(frozen_contract.read_text(encoding="utf-8"))
        if state.last_failure is not None:
            observation["last_failure"] = state.last_failure
        if oracle_note is not None:
            observation["oracle_feedback"] = oracle_note
        if system_prompt:
            observation["system"] = system_prompt
        graph_file = workspace / "task_graph.json"
        if graph_file.is_file():
            observation["task_graph"] = graph_file.read_text(encoding="utf-8")
        trace_emit(None, "planner.call", {"episode": episode})
        envelope = call_planner(cmd, observation, workspace=workspace)
        fp = fingerprint(envelope)
        planned: dict[str, Any] = {
            "artifact_keys": sorted(envelope.artifacts),
            "artifact_sha256": artifact_digests(envelope.artifacts, store),
            "fingerprint": fp,
            "program": envelope.program,
            "rationale": envelope.rationale,
            "dedupe_key": f"{fp}:{episode_tree_before}",
        }
        if envelope.nodes:
            planned["nodes"] = [
                {
                    "id": node.id,
                    "writes": list(node.writes or []),
                    "depends_on": list(node.depends_on or []),
                }
                for node in envelope.nodes
            ]
        state = _commit(state, EPISODE_PLANNED, planned)
        if not state.pending_execute:
            state = _commit(
                state,
                EPISODE_BLOCKED_DUPLICATE,
                {"fingerprint": fp},
            )
            state = _commit(state, BUDGET_CONSUMED, {"steps": 1})
            extra = (extra + "\n" if extra else "") + f"critic: duplicate plan {fp}; change the product or repair strategy"
            append_progress(run_dir, episode, [envelope.rationale or extra, extra])
            continue

        host = _host(workspace, run_dir, forbidden, allowed_globs=globs, run_id=run_id)
        host.episode = episode
        host._space = space
        space.record = lambda kind, payload: host.emit_event(kind, payload)
        program = prepare_program(envelope, str(run_dir / "dictionary"))
        critic = validate(
            program,
            set(host.allowed_effects),
            host.allowed_globs,
            host.forbidden_globs,
            envelope.artifacts,
            nodes=lower_node_programs(envelope.nodes, envelope.artifacts, workspace),
            task_graph=load_task_graph(workspace / "task_graph.json"),
        )
        if not critic["valid"]:
            errors = [str(item) for item in critic["errors"]]
            state = _commit(state, CRITIC_REJECTED, {"errors": errors})
            state = _commit(state, BUDGET_CONSUMED, {"steps": 1})
            extra = critic_extra(errors)
            append_reject(run_dir, episode, errors, envelope.program)
            append_progress(run_dir, episode, [envelope.rationale or "rejected", extra or "critic: reject"])
            continue

        state = _commit(state, CRITIC_ACCEPTED, {})
        request = {
            "dictionary_dir": str(run_dir / "dictionary"),
            "receipt_path": str(run_dir / "receipt.json"),
            "trace_path": str(run_dir / "trace.jsonl"),
            "workspace": str(workspace),
            "wave_workers": 1 if serial else wave_workers,
            "serial": serial,
        }
        trap: str | None = None
        promoted: list[dict[str, str]] = []
        try:
            executed = run_forth(
                host,
                envelope,
                preflight=True,
                request=request,
                wave_workers=wave_workers,
                serial=serial,
            )
            last_graph = dict(executed.get("graph") or host.graph_metrics or {})
            promoted = list(executed.get("promoted") or [])
        except ExecutionError as exc:
            last_graph = dict(getattr(host, "graph_metrics", {}) or {})
            backpressure = exc.code == "preflight" or exc.node is not None
            if backpressure:
                errors = [str(item) for item in (exc.details or [f"{exc.code}: {exc.message}"])]
                state = _commit(state, CRITIC_REJECTED, {"errors": errors})
                state = _commit(state, BUDGET_CONSUMED, {"steps": 1})
                extra = critic_extra(errors)
                append_reject(run_dir, episode, errors, envelope.program)
                append_progress(run_dir, episode, [envelope.rationale or "rejected", extra])
                continue
            trap = f"{exc.code}: {exc.message}"

        state = _commit(
            state,
            ARTIFACTS_APPLIED,
            {"keys": sorted(envelope.artifacts)},
        )
        for item in promoted:
            word = str(item.get("word") or "")
            digest = str(item.get("sha256") or "")
            if not word or not digest:
                continue
            state = _commit(
                state,
                DICTIONARY_PROMOTED,
                {"episode": episode, "sha256": digest, "word": word},
            )
        receipt_fields["claims_source"] = claims_source(workspace, claims, claims_label)
        if not frozen_contract.is_file() and (workspace / "claims.json").is_file():
            contract_text = (workspace / "claims.json").read_text(encoding="utf-8")
            frozen_contract.write_text(contract_text, encoding="utf-8")
            contract_digest = _json_digest(contract_text)
            state = _commit(
                state,
                CONTRACT_APPROVED,
                {"digest": contract_digest, "claims": json.loads(contract_text), "source": "benchmark-auto" if receipt_fields.get("benchmark_mode") else "workspace"},
            )
        report = measure_workspace(
            workspace,
            frozen_contract if frozen_contract.is_file() else claims,
            # Benchmark runs are an explicit, isolated auto-approval lane:
            # the planner owns the contract, and its executable checks must
            # actually run.  Ordinary model-authored contracts remain
            # untrusted (checks require a hidden/approved contract).
            allow_check=(
                receipt_fields["claims_source"] in ("hidden", "approved")
                or bool(receipt_fields.get("benchmark_mode"))
            ),
        )
        if receipt_fields["claims_source"] == "workspace" and frozen_contract.is_file():
            current_contract = workspace / "claims.json"
            if current_contract.is_file() and _json_digest(current_contract.read_text(encoding="utf-8")) != _json_digest(frozen_contract.read_text(encoding="utf-8")):
                report["passed"] = False
                report.setdefault("gates", []).append({
                    "name": "contract",
                    "passed": False,
                    "skipped": False,
                    "layer": "goal",
                    "reason": "model attempted to change the approved contract",
                })
                report["stderr"] = (str(report.get("stderr") or "") + "\nmodel attempted to change the approved contract").strip()
        if oracle_feedback is not None:
            try:
                candidate = oracle_feedback(workspace, report)
                oracle_note = dict(candidate) if isinstance(candidate, dict) else None
            except Exception as exc:  # oracle diagnostics are advisory only
                oracle_note = {"name": "oracle", "passed": False, "error": str(exc)}
            if oracle_note is not None:
                report["oracle_feedback"] = oracle_note
        after, tree_after = capture_tree(workspace, store)
        all_changed = changed_files(before, after)
        meaningful = _meaningful_changed_files(all_changed)
        report["progress"] = {
            "passed": bool(meaningful) or receipt_fields["claims_source"] in ("hidden", "approved"),
            "changed_files": all_changed,
            "meaningful_files": meaningful,
        }
        report["claim_quality"] = _claim_quality(report, goal)
        benchmark_weak_claims = bool(
            receipt_fields.get("benchmark_mode")
            and receipt_fields["claims_source"] == "workspace"
            and report["claim_quality"].get("source_only")
        )
        benchmark_missing_behavior = bool(
            receipt_fields.get("benchmark_mode")
            and receipt_fields["claims_source"] == "workspace"
            and report["claim_quality"].get("requires_behavior")
            and not report["claim_quality"].get("has_behavioral_check")
        )
        if (
            receipt_fields["claims_source"] == "workspace"
            and not meaningful
        ) or benchmark_weak_claims or benchmark_missing_behavior:
            report["passed"] = False
            report.setdefault("gates", []).append(
                {
                    "name": "progress",
                    "passed": False,
                    "skipped": False,
                    "layer": "goal",
                    "reason": (
                        "benchmark mode requires an executable or behavioral claim"
                        if benchmark_weak_claims
                        else "benchmark mode requires a runtime behavioral check for this goal"
                        if benchmark_missing_behavior
                        else "model-authored claims made no meaningful product change"
                    ),
                }
            )
            report["stderr"] = (
                str(report.get("stderr") or "")
                + "\n"
                + (
                    "benchmark mode requires an executable or behavioral claim"
                    if benchmark_weak_claims
                    else "model-authored claims made no meaningful product change"
                )
            ).strip()
        state = _commit(
            state,
            GATES_MEASURED,
            {
                "claims_source": receipt_fields["claims_source"],
                "files": after,
                "report": report,
                "tree_after": tree_after,
                "tree_before": episode_tree_before,
            },
        )
        for item in promoted:
            evidence = evidence_for(
                {**item, "episode": episode},
                report=report,
                critic_accepted=True,
                trap=trap,
            )
            state = _commit(state, PROMOTION_EVIDENCE, evidence.to_dict())
            trace_emit(host.trace_path, "dictionary.promotion_evidence", evidence.to_dict())
        state = _commit(state, BUDGET_CONSUMED, {"steps": 1})
        last_changed = changed_files(before, after)
        episode_tree_before = tree_after
        bits = [envelope.rationale or "accepted"]
        if trap:
            bits.append(f"trap: {trap}")
        bits.append("changed: " + (", ".join(last_changed) if last_changed else "none"))
        if report.get("gates"):
            marks = []
            for gate in report["gates"]:
                mark = "pass" if gate.get("passed") else ("skip" if gate.get("skipped") else "fail")
                marks.append(f"{gate.get('name')}={mark}")
            bits.append("gates: " + " ".join(marks))
        append_progress(run_dir, episode, bits)
        extra = critic_extra(list(state.last_errors))
        if not report.get("passed"):
            details = gate_feedback(report)
            summary = f"gates: {report.get('stderr') or 'not discharged'}"
            extra = (extra + "\n" if extra else "") + summary
            if details:
                extra += "\n" + details


def _finish(
    decision: Decision,
    state: State,
    workspace: Path,
    run_dir: Path,
    before: dict[str, str],
    graph: dict[str, Any] | None = None,
    *,
    print_receipt: bool = True,
    receipt_extra: dict[str, Any] | None = None,
    tree_before: str | None = None,
) -> tuple[int, dict[str, Any]]:
    store = open_store(run_dir)
    after, tree_after = capture_tree(workspace, store)
    if tree_before is None:
        tree_before = intern_snapshot(store, workspace, before)
    changed = changed_files(before, after)
    receipt = {
        "changed_files": changed,
        "decision": decision.kind,
        "discharged": decision.kind == DECISION_SUCCESS,
        "episodes": state.used,
        "gates": state.last_gates,
        "ok": decision.kind == DECISION_SUCCESS,
        "reason": decision.reason,
        "run_dir": str(run_dir),
        "tree_after": tree_after,
        "tree_before": tree_before,
        "workspace": str(workspace),
        "last_failure": state.last_failure,
    }
    for key, value in (graph or {}).items():
        receipt[key] = value
    for key, value in (receipt_extra or {}).items():
        receipt[key] = value
    (run_dir / "receipt.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    line = metrics_line(graph)
    if line:
        print(line, file=sys.stderr)
    if print_receipt:
        print(json.dumps(receipt, indent=2, sort_keys=True))
    return (0 if decision.kind == DECISION_SUCCESS else 2), receipt


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Living Dictionary headless loop",
        epilog="SCUD child: livingdict run --request-file - --events jsonl; policy: livingdict policy",
    )
    parser.add_argument("-p", "--goal", required=True, help="natural-language goal")
    parser.add_argument("--cwd", type=Path, default=Path("."), help="product workspace")
    parser.add_argument("--max-turns", type=int, default=DEFAULT_MAX_TURNS)
    parser.add_argument("--claims", type=Path, help="hidden claims.json used for discharge")
    parser.add_argument(
        "--benchmark",
        action="store_true",
        help="mark the receipt as benchmark-driven; native verification remains authoritative",
    )
    parser.add_argument("--run-dir", type=Path, help="job state directory (default: CWD/.livingdict-run)")
    parser.add_argument(
        "--planner-cmd",
        nargs="+",
        metavar="ARG",
        help="argv that reads observation JSON on stdin and writes envelope JSON on stdout",
    )
    parser.add_argument(
        "--wave-workers",
        type=int,
        default=4,
        metavar="N",
        help="max parallel graph nodes per wave (default: min(width, 4))",
    )
    parser.add_argument(
        "--serial",
        action="store_true",
        help="force graph width 1 (Kahn levels still apply)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "run":
        from .runner import run_main

        return run_main(argv[1:])
    if argv and argv[0] == "policy":
        from .policy_eval import main as policy_main

        return policy_main(argv[1:])
    if argv and argv[0] == "tui":
        from .tui import main as tui_main

        return tui_main(argv[1:])
    parser = build_parser()
    args = parser.parse_args(argv)
    planner_cmd = list(args.planner_cmd) if args.planner_cmd else None
    if planner_cmd and len(planner_cmd) == 1:
        planner_cmd = shlex.split(planner_cmd[0])
    if planner_cmd:
        planner_cmd = resolve_argv_files(planner_cmd)
    try:
        code, _receipt = run_job(
            args.goal,
            args.cwd,
            max_turns=args.max_turns,
            claims=args.claims,
            run_dir=args.run_dir,
            planner_cmd=planner_cmd,
            wave_workers=args.wave_workers,
            serial=args.serial,
            receipt_extra={"benchmark_mode": True} if args.benchmark else None,
        )
    except (CLIError, EnvelopeError, KernelError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return code
