from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

from .models import RunResult, Task
from .policy import changed_files, snapshot, violations
from .trace import append_event, event_seen, read_events, summarize
from .verifier import verify


def _copy_oracle(task: Task, workspace: Path) -> int:
    if not task.oracle_files.exists():
        return 2
    for source in task.oracle_files.rglob("*"):
        if source.is_dir():
            continue
        target = workspace / source.relative_to(task.oracle_files)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    return 0


def _request_payload(
    task: Task,
    run_id: str,
    workspace: Path,
    trace_path: Path,
    receipt_path: Path,
    dictionary_dir: Path,
    arm: str,
    memory_mode: str,
    resume: bool,
) -> dict[str, Any]:
    graph_path = workspace / "task_graph.json"
    return {
        "protocol_version": "1.0",
        "run_id": run_id,
        "arm": arm,
        "memory_mode": memory_mode,
        "resume": resume,
        "task": {
            "id": task.id,
            "family": task.family,
            "sequence": task.sequence,
            "title": task.title,
            "difficulty": task.difficulty,
            "mechanisms": list(task.mechanisms),
            "allowed_effects": list(task.allowed_effects),
            "allowed_globs": list(task.allowed_globs),
            "forbidden_globs": list(task.forbidden_globs),
            "time_limit_seconds": task.time_limit_seconds,
        },
        "workspace": str(workspace),
        "prompt_path": str(workspace / "TASK.md"),
        "trace_path": str(trace_path),
        "receipt_path": str(receipt_path),
        "dictionary_dir": str(dictionary_dir),
        "graph_path": str(graph_path) if graph_path.exists() else None,
    }


def _launch_agent(
    command: str,
    request_path: Path,
    workspace: Path,
    timeout: int,
    trace_path: Path,
    fault_event: str | None,
) -> tuple[int, bool, bool]:
    argv = [*shlex.split(command), str(request_path)]
    env = os.environ.copy()
    env["LDEVAL_REQUEST"] = str(request_path)
    env["LDEVAL_WORKSPACE"] = str(workspace)
    env["LDEVAL_TRACE"] = str(trace_path)
    proc = subprocess.Popen(argv, cwd=workspace, env=env)
    started = time.monotonic()
    injected = False
    timed_out = False
    while proc.poll() is None:
        elapsed = time.monotonic() - started
        if elapsed > timeout:
            proc.kill()
            timed_out = True
            break
        if fault_event and not injected and event_seen(trace_path, fault_event):
            append_event(trace_path, {"type": "fault.injected", "data": {"after_event": fault_event}})
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
            injected = True
            break
        time.sleep(0.05)
    try:
        code = proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        code = proc.wait()
    return code, timed_out, injected


def run_task(
    task: Task,
    output_root: Path,
    arm: str,
    agent_command: str | None = None,
    oracle: bool = False,
    memory_mode: str = "cold",
    dictionary_dir: Path | None = None,
    inject_fault: bool = False,
    keep_workspace: bool = True,
) -> RunResult:
    output_root = output_root.resolve()
    run_id = f"{task.id}-{uuid.uuid4().hex[:10]}"
    run_dir = output_root / run_id
    workspace = run_dir / "workspace"
    trace_path = run_dir / "trace.jsonl"
    receipt_path = run_dir / "receipt.json"
    request_path = run_dir / "request.json"
    run_dir.mkdir(parents=True, exist_ok=True)
    shutil.copytree(task.repo_dir, workspace)
    shutil.copy2(task.prompt_path, workspace / "TASK.md")

    if dictionary_dir is None:
        dictionary_dir = run_dir / "dictionary"
    dictionary_dir.mkdir(parents=True, exist_ok=True)

    before = snapshot(workspace)
    payload = _request_payload(
        task, run_id, workspace, trace_path, receipt_path,
        dictionary_dir, arm, memory_mode, resume=False,
    )
    request_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    started = time.monotonic()
    timed_out = False
    injected = False

    if oracle:
        exit_code = _copy_oracle(task, workspace)
        append_event(trace_path, {"type": "oracle.applied", "data": {"task_id": task.id}})
    elif agent_command:
        exit_code, timed_out, injected = _launch_agent(
            agent_command,
            request_path,
            workspace,
            task.time_limit_seconds,
            trace_path,
            task.fault_event if inject_fault else None,
        )
        if injected and not timed_out:
            payload["resume"] = True
            request_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            append_event(trace_path, {"type": "run.resumed", "data": {"task_id": task.id}})
            exit_code, timed_out, _ = _launch_agent(
                agent_command,
                request_path,
                workspace,
                task.time_limit_seconds,
                trace_path,
                None,
            )
    else:
        raise ValueError("provide agent_command or oracle=True")

    elapsed = time.monotonic() - started
    after = snapshot(workspace)
    changed = changed_files(before, after)
    policy_violations = violations(changed, task.allowed_globs, task.forbidden_globs)
    verification = verify(task, workspace.resolve())
    telemetry = summarize(read_events(trace_path))
    telemetry["crash_injected"] = injected or telemetry.get("crash_injected", False)

    result = RunResult(
        run_id=run_id,
        task_id=task.id,
        family=task.family,
        sequence=task.sequence,
        arm=arm,
        memory_mode=memory_mode,
        success=verification.passed and not policy_violations and not timed_out,
        verifier_passed=verification.passed,
        agent_exit_code=exit_code,
        timed_out=timed_out,
        elapsed_seconds=round(elapsed, 6),
        changed_files=changed,
        policy_violations=policy_violations,
        verification=verification.raw or {"checks": verification.checks},
        telemetry=telemetry,
        workspace=str(workspace),
        trace_path=str(trace_path),
        receipt_path=str(receipt_path),
    )
    (run_dir / "result.json").write_text(
        json.dumps(result.to_dict(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if not receipt_path.exists():
        receipt_path.write_text(
            json.dumps({
                "protocol_version": "1.0",
                "run_id": run_id,
                "task_id": task.id,
                "success": result.success,
                "changed_files": changed,
                "verification": result.verification,
                "policy_violations": policy_violations,
            }, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    if not keep_workspace:
        shutil.rmtree(workspace, ignore_errors=True)
    return result


def run_suite(
    tasks: list[Task],
    output_root: Path,
    arm: str,
    agent_command: str | None,
    oracle: bool,
    memory_mode: str,
    inject_fault: bool,
    keep_workspace: bool,
) -> list[RunResult]:
    output_root.mkdir(parents=True, exist_ok=True)
    shared: dict[str, Path] = {}
    results = []
    for task in tasks:
        if memory_mode == "warm":
            dictionary = shared.setdefault(task.family, output_root / "dictionaries" / task.family)
        else:
            dictionary = None
        results.append(run_task(
            task=task,
            output_root=output_root,
            arm=arm,
            agent_command=agent_command,
            oracle=oracle,
            memory_mode=memory_mode,
            dictionary_dir=dictionary,
            inject_fault=inject_fault,
            keep_workspace=keep_workspace,
        ))
    return results
