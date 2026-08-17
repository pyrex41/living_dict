"""Runnable Stage 2 verifier. Prints {pass, summary, gaps, evidence} as JSON."""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tempfile
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

from .envelope import GraphNode, PlanEnvelope, load_envelope
from .execute import ExecutionError, run_forth
from .host import CapabilityHost
from .preflight import validate
from .trace import read_events
from .wave import WavePlanError, format_metrics, plan_waves


REPO = Path(__file__).resolve().parents[3]
FIXTURE = REPO / "harness" / "tests" / "fixtures" / "graph-01.envelope.json"
GRAPH_01 = REPO / "eval" / "tasks" / "graph-01"


def _node(ident: str, writes: list[str], deps: list[str] | None = None, program: str = "") -> GraphNode:
    return GraphNode(id=ident, writes=writes, depends_on=deps or [], program=program)


def _host(root: Path) -> CapabilityHost:
    return CapabilityHost(
        workspace=root,
        allowed_effects=("read", "write", "exec"),
        allowed_globs=("**",),
        forbidden_globs=(),
        trace_path=root / "trace.jsonl",
        receipt_path=root / "receipt.json",
    )


def _request(root: Path, workers: int) -> dict[str, Any]:
    run = root.parent / (root.name + "-run")
    (run / "dictionary").mkdir(parents=True, exist_ok=True)
    return {
        "workspace": str(root),
        "dictionary_dir": str(run / "dictionary"),
        "receipt_path": str(run / "receipt.json"),
        "trace_path": str(run / "trace.jsonl"),
        "wave_workers": workers,
        "serial": workers == 1,
    }


def _tree_hashes(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    skip = {".git", "__pycache__", ".sb", ".livingdict-run"}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix in {".pyc", ".pyo"}:
            continue
        if any(part in skip for part in path.parts):
            continue
        if path.name in {"trace.jsonl", "receipt.json", "checkpoint.json"}:
            continue
        values[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def _parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def check_critic() -> str | None:
    result = validate(
        "",
        {"read", "write", "exec"},
        allowed_globs=["**"],
        artifacts={"shared.py": "x\n"},
        nodes=[
            _node("left", ["shared.py"], program="RECEIPT"),
            _node("right", ["shared.py"], program="RECEIPT"),
        ],
    )
    if result["valid"] or not any("overlapping independent writes" in err for err in result["errors"]):
        return f"critic missed overlap: {result}"
    return None


def check_same_path(root: Path) -> str | None:
    host = _host(root)
    envelope = PlanEnvelope(
        language="forth",
        program="",
        nodes=[
            _node("a", ["shared.txt"], program='S" AAA" S" shared.txt" WRITE-FILE'),
            _node("b", ["shared.txt"], program='S" BBB" S" shared.txt" WRITE-FILE'),
        ],
    )
    try:
        run_forth(host, envelope, preflight=False, request=_request(root, 2), wave_workers=2)
        return "same-wave shared write did not trap"
    except ExecutionError as exc:
        if exc.code != "policy":
            return f"same-wave shared write trapped as {exc.code}, want policy"
    if (root / "shared.txt").exists():
        return "same-wave shared write mutated shared.txt"
    return None


def check_trap(root: Path) -> str | None:
    host = _host(root)
    envelope = PlanEnvelope(
        language="forth",
        program="",
        artifacts={"ok.txt": "ok\n", "dep.txt": "dep\n"},
        nodes=[
            _node("ok", ["ok.txt"], program='S" ok.txt" USE-ARTIFACT S" ok.txt" WRITE-FILE'),
            _node("trap", [], program='S" missing.txt" READ-FILE'),
            _node("dep", ["dep.txt"], ["trap"], program='S" dep.txt" USE-ARTIFACT S" dep.txt" WRITE-FILE'),
        ],
    )
    try:
        run_forth(host, envelope, preflight=True, request=_request(root, 2), wave_workers=2)
        return "trap isolation did not raise"
    except ExecutionError as exc:
        if exc.node != "trap":
            return f"trap node id {exc.node!r}, want 'trap'"
    if not (root / "ok.txt").is_file():
        return "sibling ok.txt missing after trap"
    if (root / "dep.txt").exists():
        return "dependent dep.txt was written"
    started = [
        event["data"]["node"]
        for event in read_events(root / "trace.jsonl")
        if event.get("type") == "graph.node.start"
    ]
    if "dep" in started:
        return "dependent node started"
    return None


def check_cycle() -> str | None:
    try:
        plan_waves(
            [
                _node("a", ["a.txt"], ["b"]),
                _node("b", ["b.txt"], ["a"]),
            ]
        )
        return "cycle produced a plan"
    except WavePlanError as exc:
        if "dependency cycle" not in str(exc):
            return f"cycle error {exc}"
    return None


def check_equivalence(base: Path) -> tuple[str | None, dict[str, Any]]:
    metrics: dict[str, Any] = {}
    envelope = load_envelope(FIXTURE)
    trees: dict[str, dict[str, str]] = {}
    for name, workers in (("serial", 1), ("waved", 4)):
        root = base / name
        shutil.copytree(GRAPH_01 / "repo", root)
        host = _host(root)
        extra = run_forth(
            host,
            envelope,
            preflight=True,
            request=_request(root, workers),
            wave_workers=workers,
            serial=workers == 1,
        )
        metrics[name] = extra.get("graph") or host.graph_metrics
        trees[name] = _tree_hashes(root)
    if trees["serial"] != trees["waved"]:
        return f"workspace trees differ: {trees['serial']} vs {trees['waved']}", metrics
    if metrics["serial"].get("conflicts") != 0 or metrics["waved"].get("conflicts") != 0:
        return f"conflicts not 0: {metrics}", metrics
    return None, metrics


def check_overlap(root: Path) -> str | None:
    host = _host(root)
    host.node_start_hook = lambda _nid: time.sleep(0.15)
    envelope = PlanEnvelope(
        language="forth",
        program="",
        artifacts={"a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n"},
        nodes=[
            _node("a", ["a.txt"], program='S" a.txt" USE-ARTIFACT S" a.txt" WRITE-FILE'),
            _node("b", ["b.txt"], program='S" b.txt" USE-ARTIFACT S" b.txt" WRITE-FILE'),
            _node("c", ["c.txt"], program='S" c.txt" USE-ARTIFACT S" c.txt" WRITE-FILE'),
        ],
    )
    extra = run_forth(host, envelope, preflight=True, request=_request(root, 3), wave_workers=3)
    events = read_events(root / "trace.jsonl")
    starts = [event for event in events if event.get("type") == "graph.node.start"]
    finishes = [event for event in events if event.get("type") == "graph.node.finish"]
    intervals = []
    for start in starts:
        finish = next(event for event in finishes if event["data"]["node"] == start["data"]["node"])
        intervals.append((_parse_ts(start["timestamp"]), _parse_ts(finish["timestamp"])))
    overlapped = False
    for index, (left0, left1) in enumerate(intervals):
        for right0, right1 in intervals[index + 1 :]:
            if left0 < right1 and right0 < left1:
                overlapped = True
    if not overlapped:
        return "no overlapping start/finish intervals"
    if extra["graph"].get("nodes_parallel", 0) < 2:
        return f"nodes_parallel={extra['graph'].get('nodes_parallel')}"
    return None


def run_verifier() -> dict[str, Any]:
    gaps: list[str] = []
    evidence: list[str] = []
    tmp = tempfile.TemporaryDirectory()
    base = Path(tmp.name)
    try:
        for name, fn in (
            ("critic-overlap", lambda: check_critic()),
            ("same-path", lambda: check_same_path(base / "same-path")),
            ("trap", lambda: check_trap(base / "trap")),
            ("cycle", check_cycle),
            ("overlap", lambda: check_overlap(base / "overlap")),
        ):
            (base / name).mkdir(parents=True, exist_ok=True)
            err = fn()
            if err:
                gaps.append(f"{name}: {err}")
            else:
                evidence.append(f"{name}: ok")
        err, metrics = check_equivalence(base / "equiv")
        if err:
            gaps.append(f"equivalence: {err}")
        else:
            evidence.append("equivalence: ok " + format_metrics(metrics.get("waved") or {}))
            evidence.append("serial " + format_metrics(metrics.get("serial") or {}))
    except Exception as exc:
        gaps.append(f"verifier crashed: {exc}")
        evidence.append(traceback.format_exc())
    tmp.cleanup()
    passed = not gaps
    return {
        "pass": passed,
        "summary": "wave verifier passed" if passed else "wave verifier failed: " + "; ".join(gaps),
        "gaps": gaps,
        "evidence": "\n".join(evidence),
    }


def main(argv: list[str] | None = None) -> int:
    del argv
    verdict = run_verifier()
    json.dump(verdict, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if verdict["pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
