from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path

from livingdict.cli import run_job
from livingdict.envelope import GraphNode, PlanEnvelope, load_envelope
from livingdict.execute import ExecutionError, run_forth
from livingdict.host import CapabilityError, CapabilityHost
from livingdict.trace import read_events
from livingdict.wave import WavePlanError, plan_waves
from livingdict.wave_verify import run_verifier


REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "graph-01.envelope.json"
PLANNER = Path(__file__).resolve().parent / "graph_planner.py"
GRAPH_01 = REPO / "eval" / "tasks" / "graph-01"

SKIP_TREE = {".git", "__pycache__", ".sb", ".livingdict-run", ".mypy_cache"}


def _node(ident: str, writes: list[str], deps: list[str] | None = None, program: str = "") -> GraphNode:
    return GraphNode(id=ident, writes=writes, depends_on=deps or [], program=program)


def _host(root: Path, globs: tuple[str, ...] = ("**",)) -> CapabilityHost:
    return CapabilityHost(
        workspace=root,
        allowed_effects=("read", "write", "exec"),
        allowed_globs=globs,
        forbidden_globs=(),
        trace_path=root / "trace.jsonl",
        receipt_path=root / "receipt.json",
    )


def _parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _tree_hashes(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_TREE for part in path.parts):
            continue
        if path.suffix in {".pyc", ".pyo"}:
            continue
        rel = path.relative_to(root).as_posix()
        values[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def _gate_shape(report: dict) -> list[tuple[str, bool, bool]]:
    gates = report.get("gates") or []
    return [
        (str(gate.get("name")), bool(gate.get("passed")), bool(gate.get("skipped")))
        for gate in gates
    ]


class WavePlannerTests(unittest.TestCase):
    def test_graph01_kahn_levels_are_lexicographic(self) -> None:
        envelope = load_envelope(FIXTURE)
        waves = plan_waves(envelope.nodes or [])
        self.assertEqual(
            [[node.id for node in wave] for wave in waves],
            [["ingest", "offset", "scale"], ["registry"], ["verify"]],
        )

    def test_cycle_is_fail_closed_no_prefix(self) -> None:
        nodes = [
            _node("a", ["a.txt"], ["b"], program="RECEIPT"),
            _node("b", ["b.txt"], ["a"], program="RECEIPT"),
        ]
        with self.assertRaises(WavePlanError) as caught:
            plan_waves(nodes)
        self.assertIn("dependency cycle", str(caught.exception))


class WaveEquivalenceTests(unittest.TestCase):
    def test_graph01_serial_and_waved_trees_match(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)

        def run_once(name: str, *, serial: bool) -> tuple[dict[str, str], dict, dict]:
            workspace = base / name / "ws"
            run_dir = base / name / "run"
            shutil.copytree(GRAPH_01 / "repo", workspace)
            _code, receipt = run_job(
                "complete the graph-01 pipeline",
                workspace,
                max_turns=1,
                run_dir=run_dir,
                planner_cmd=[sys.executable, str(PLANNER)],
                wave_workers=4,
                serial=serial,
            )
            discharge_path = workspace / ".sb" / "discharge_report.json"
            discharge = json.loads(discharge_path.read_text(encoding="utf-8")) if discharge_path.is_file() else {}
            return _tree_hashes(workspace), receipt, discharge

        serial_tree, serial_receipt, serial_discharge = run_once("serial", serial=True)
        waved_tree, waved_receipt, waved_discharge = run_once("waved", serial=False)
        self.assertEqual(serial_tree, waved_tree)
        self.assertEqual(_gate_shape(serial_discharge), _gate_shape(waved_discharge))
        self.assertEqual(serial_discharge.get("passed"), waved_discharge.get("passed"))
        for key in (
            "wave_count",
            "max_wave_width",
            "conflicts",
        ):
            self.assertEqual(serial_receipt.get(key), waved_receipt.get(key), key)
        self.assertEqual(serial_receipt.get("wave_count"), 3)
        self.assertEqual(serial_receipt.get("max_wave_width"), 3)
        self.assertEqual(serial_receipt.get("conflicts"), 0)
        self.assertGreater(waved_receipt.get("wall_ms_serial_estimate", -1), -1)
        tmp.cleanup()


class WaveConcurrencyTests(unittest.TestCase):
    def test_independent_nodes_overlap_when_workers_gt_one(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = _host(root)
        host.node_start_hook = lambda _nid: time.sleep(0.2)
        envelope = PlanEnvelope(
            language="forth",
            program="",
            artifacts={
                "a.txt": "a\n",
                "b.txt": "b\n",
                "c.txt": "c\n",
            },
            nodes=[
                _node(
                    "a",
                    ["a.txt"],
                    program='S" a.txt" USE-ARTIFACT S" a.txt" WRITE-FILE S" a.txt" READ-FILE DROP',
                ),
                _node(
                    "b",
                    ["b.txt"],
                    program='S" b.txt" USE-ARTIFACT S" b.txt" WRITE-FILE S" b.txt" READ-FILE DROP',
                ),
                _node(
                    "c",
                    ["c.txt"],
                    program='S" c.txt" USE-ARTIFACT S" c.txt" WRITE-FILE S" c.txt" READ-FILE DROP',
                ),
            ],
        )
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
            "wave_workers": 3,
        }
        (root / "dictionary").mkdir()
        extra = run_forth(host, envelope, preflight=True, request=request, wave_workers=3)
        events = read_events(root / "trace.jsonl")
        starts = [event for event in events if event["type"] == "graph.node.start"]
        finishes = [event for event in events if event["type"] == "graph.node.finish"]
        self.assertEqual([event["data"]["node"] for event in starts], ["a", "b", "c"])
        intervals = []
        for start in starts:
            finish = next(
                event
                for event in finishes
                if event["data"]["node"] == start["data"]["node"]
            )
            intervals.append((_parse_ts(start["timestamp"]), _parse_ts(finish["timestamp"])))
        overlapped = False
        for index, (left0, left1) in enumerate(intervals):
            for right0, right1 in intervals[index + 1 :]:
                if left0 < right1 and right0 < left1:
                    overlapped = True
        self.assertTrue(overlapped, "expected overlapping start/finish intervals")
        self.assertGreaterEqual(extra["graph"]["nodes_parallel"], 2)
        self.assertEqual(extra["graph"]["conflicts"], 0)
        tmp.cleanup()


class WaveSafetyTests(unittest.TestCase):
    def test_narrowed_policy_refuses_out_of_set_write(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = _host(root)
        envelope = PlanEnvelope(
            language="forth",
            program="",
            artifacts={"b.txt": "ok\n"},
            nodes=[
                _node(
                    "writer-a",
                    ["a.txt"],
                    program='S" stolen" S" b.txt" WRITE-FILE',
                ),
                _node(
                    "writer-b",
                    ["b.txt"],
                    program='S" ok" S" b.txt" WRITE-FILE',
                ),
            ],
        )
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
            "wave_workers": 2,
        }
        (root / "dictionary").mkdir()
        with self.assertRaises(ExecutionError) as caught:
            run_forth(host, envelope, preflight=False, request=request, wave_workers=2)
        self.assertEqual(caught.exception.code, "policy")
        self.assertEqual(caught.exception.node, "writer-a")
        self.assertEqual((root / "b.txt").read_text(encoding="utf-8"), "ok\n")
        self.assertFalse((root / "a.txt").exists())
        events = read_events(root / "trace.jsonl")
        traps = [event for event in events if event["type"] == "execution.trap"]
        self.assertTrue(any(event["data"].get("node") == "writer-a" for event in traps))
        self.assertTrue(any(event["data"].get("reason") == "policy" for event in traps))
        tmp.cleanup()

    def test_same_wave_shared_path_is_refused_with_no_mutation(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = _host(root)
        envelope = PlanEnvelope(
            language="forth",
            program="",
            artifacts={},
            nodes=[
                _node("a", ["shared.txt"], program='S" AAA" S" shared.txt" WRITE-FILE'),
                _node("b", ["shared.txt"], program='S" BBB" S" shared.txt" WRITE-FILE'),
            ],
        )
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
            "wave_workers": 2,
        }
        (root / "dictionary").mkdir()
        with self.assertRaises(ExecutionError) as caught:
            run_forth(host, envelope, preflight=False, request=request, wave_workers=2)
        self.assertEqual(caught.exception.code, "policy")
        self.assertFalse((root / "shared.txt").exists())
        self.assertGreaterEqual(host.graph_metrics.get("conflicts", 0), 1)
        tmp.cleanup()

    def test_node_view_write_denied_at_host_layer(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = _host(root, ("**",))
        view = host.node_view(("a.txt",))
        with self.assertRaises(CapabilityError) as caught:
            view.write_file("x", "b.txt")
        self.assertEqual(caught.exception.code, "policy")
        self.assertFalse((root / "b.txt").exists())
        tmp.cleanup()


class WaveTrapIsolationTests(unittest.TestCase):
    def test_trap_completes_siblings_skips_dependents(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = _host(root)
        envelope = PlanEnvelope(
            language="forth",
            program="",
            artifacts={"ok.txt": "ok\n", "dep.txt": "dep\n"},
            nodes=[
                _node(
                    "ok",
                    ["ok.txt"],
                    program='S" ok.txt" USE-ARTIFACT S" ok.txt" WRITE-FILE',
                ),
                _node("trap", [], program='S" missing.txt" READ-FILE'),
                _node(
                    "dep",
                    ["dep.txt"],
                    ["trap"],
                    program='S" dep.txt" USE-ARTIFACT S" dep.txt" WRITE-FILE',
                ),
            ],
        )
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
            "wave_workers": 2,
        }
        (root / "dictionary").mkdir()
        with self.assertRaises(ExecutionError) as caught:
            run_forth(host, envelope, preflight=True, request=request, wave_workers=2)
        self.assertEqual(caught.exception.code, "missing_file")
        self.assertEqual(caught.exception.node, "trap")
        self.assertTrue((root / "ok.txt").is_file())
        self.assertFalse((root / "dep.txt").exists())
        started = [
            event["data"]["node"]
            for event in read_events(root / "trace.jsonl")
            if event["type"] == "graph.node.start"
        ]
        self.assertIn("ok", started)
        self.assertIn("trap", started)
        self.assertNotIn("dep", started)
        tmp.cleanup()

    def test_cli_trap_is_backpressure_not_crash(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)
        workspace = base / "ws"
        run_dir = base / "run"
        workspace.mkdir()
        envelope = {
            "language": "forth",
            "program": "",
            "artifacts": {"ok.txt": "ok\n", "dep.txt": "dep\n"},
            "nodes": [
                {
                    "id": "ok",
                    "writes": ["ok.txt"],
                    "depends_on": [],
                    "program": 'S" ok.txt" USE-ARTIFACT S" ok.txt" WRITE-FILE',
                },
                {
                    "id": "trap",
                    "writes": [],
                    "depends_on": [],
                    "program": 'S" missing.txt" READ-FILE',
                },
                {
                    "id": "dep",
                    "writes": ["dep.txt"],
                    "depends_on": ["trap"],
                    "program": 'S" dep.txt" USE-ARTIFACT S" dep.txt" WRITE-FILE',
                },
            ],
            "rationale": "trap isolation",
        }
        env_path = base / "envelope.json"
        env_path.write_text(json.dumps(envelope) + "\n", encoding="utf-8")
        previous = os.environ.get("LIVINGDICT_TEST_ENVELOPE")
        os.environ["LIVINGDICT_TEST_ENVELOPE"] = str(env_path)
        try:
            code, receipt = run_job(
                "trap isolation",
                workspace,
                max_turns=1,
                run_dir=run_dir,
                planner_cmd=[sys.executable, str(PLANNER)],
                serial=True,
            )
        finally:
            if previous is None:
                os.environ.pop("LIVINGDICT_TEST_ENVELOPE", None)
            else:
                os.environ["LIVINGDICT_TEST_ENVELOPE"] = previous
        self.assertEqual(code, 2)
        self.assertNotEqual(receipt.get("decision"), "success")
        events = (run_dir / "events.jsonl").read_text(encoding="utf-8")
        self.assertIn("critic.rejected", events)
        self.assertTrue((workspace / "ok.txt").is_file())
        self.assertFalse((workspace / "dep.txt").exists())
        tmp.cleanup()


class WaveVerifierSlotTests(unittest.TestCase):
    def test_wave_verify_module_returns_usable_verdict(self) -> None:
        verdict = run_verifier()
        self.assertIn("pass", verdict)
        self.assertIn("gaps", verdict)
        self.assertIn("evidence", verdict)
        self.assertTrue(verdict["pass"], verdict)


class WaveCycleExecuteTests(unittest.TestCase):
    def test_cycle_does_not_write(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = _host(root)
        envelope = PlanEnvelope(
            language="forth",
            program="",
            artifacts={"a.txt": "a\n", "b.txt": "b\n"},
            nodes=[
                _node("a", ["a.txt"], ["b"], program='S" a" S" a.txt" WRITE-FILE'),
                _node("b", ["b.txt"], ["a"], program='S" b" S" b.txt" WRITE-FILE'),
            ],
        )
        with self.assertRaises(ExecutionError) as caught:
            run_forth(host, envelope, preflight=False)
        self.assertEqual(caught.exception.code, "graph")
        self.assertFalse((root / "a.txt").exists())
        self.assertFalse((root / "b.txt").exists())
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
