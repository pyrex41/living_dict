from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from livingdict.envelope import load_envelope
from livingdict.execute import run_forth
from livingdict.host import CapabilityHost
from livingdict.trace import read_events


REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "graph-01.envelope.json"
ADAPTER = REPO / "harness" / "adapters" / "forth_shen.py"
GRAPH_01 = REPO / "eval" / "tasks" / "graph-01"

# Local SHA-256 lock for files this stage must not edit. Explore had no digest
# primitive; these were hashed from the tree as it exists on disk.
PROTECTED_HASHES = {
    "protected/verify.py": "42c6bf3d2cb3a7d9bf226c874a828cc75f0620397f2ff3b8b2356def0285158c",
    "protected/oracle/files/pipeline/ingest.py": "0bc64dc82f4321282ed5608a0a12a7753e5a9417b8dabf3bd1d6d844b5cf48f6",
    "protected/oracle/files/pipeline/scale.py": "3291a5173b2b3e247e144514bad1a43f41a436e07253c8a3a3edd4b6251cfa45",
    "protected/oracle/files/pipeline/offset.py": "61e67cf1b6ea7d739aed6d6e0582be0b88d4fa2739170a2eba4eececd4352bd7",
    "protected/oracle/files/pipeline/registry.py": "a805c3053952b9edeca718eccd2579c958e3869325c92b1fa355530bcae84b76",
    "repo/task_graph.json": "d49c4efeb34ec54a66d4ca31264d0b38da23f8762b4c54ea89371385b9de99ec",
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _graph_event_count(trace_path: Path, kind: str) -> int:
    return sum(1 for event in read_events(trace_path) if event.get("type") == kind)


class GraphTraceTests(unittest.TestCase):
    def test_nodes_emit_envelope_ids_not_paths(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "pipeline").mkdir()
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("pipeline/*.py",),
            forbidden_globs=(),
            trace_path=root / "trace.jsonl",
            receipt_path=root / "receipt.json",
        )
        envelope = load_envelope(FIXTURE)
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
        }
        (root / "dictionary").mkdir()
        run_forth(host, envelope, preflight=True, request=request)
        events = read_events(root / "trace.jsonl")
        starts = [event for event in events if event["type"] == "graph.node.start"]
        finishes = [event for event in events if event["type"] == "graph.node.finish"]
        self.assertEqual(len(starts), len(envelope.nodes))
        self.assertEqual(len(finishes), len(envelope.nodes))
        self.assertEqual(
            [event["data"]["node"] for event in starts],
            ["ingest", "offset", "scale", "registry", "verify"],
        )
        self.assertTrue(all(event["data"]["worker"] == "host" for event in starts + finishes))
        self.assertTrue(all(event["data"]["status"] == "ok" for event in finishes))
        self.assertFalse((root / ".sb").exists())
        tmp.cleanup()

    def test_absent_nodes_keep_artifact_key_series(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("**",),
            forbidden_globs=(),
            trace_path=root / "trace.jsonl",
            receipt_path=root / "receipt.json",
        )
        from livingdict.envelope import PlanEnvelope

        envelope = PlanEnvelope(
            language="forth",
            program='S" hello.txt" WRITE-FILE RECEIPT',
            artifacts={"hello.txt": "hi\n", "notes.txt": "n\n"},
        )
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
        }
        (root / "dictionary").mkdir()
        run_forth(host, envelope, preflight=True, request=request)
        starts = [
            event["data"]["node"]
            for event in read_events(root / "trace.jsonl")
            if event["type"] == "graph.node.start"
        ]
        self.assertEqual(starts, ["hello.txt", "notes.txt"])
        tmp.cleanup()


class Graph01EndToEndTests(unittest.TestCase):
    def test_protected_files_match_local_hashes(self) -> None:
        for rel, digest in PROTECTED_HASHES.items():
            path = GRAPH_01 / rel
            self.assertTrue(path.is_file(), rel)
            self.assertEqual(_sha256(path), digest, rel)

    def test_canned_envelope_via_ldeval(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        output = Path(tmp.name) / "runs"
        env = os.environ.copy()
        env["LIVINGDICT_ENVELOPE"] = str(FIXTURE)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "ldeval",
                "run",
                "--agent-command",
                f"{sys.executable} {ADAPTER}",
                "--arm",
                "forth-shen",
                "--memory-mode",
                "cold",
                "--tasks",
                "graph-01",
                "--output",
                str(output),
            ],
            cwd=str(REPO / "eval"),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        summary = json.loads((output / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(summary["overall"]["success_rate"], 1.0, summary)
        self.assertEqual(summary["overall"]["policy_violation_runs"], 0, summary)
        results = list(output.rglob("result.json"))
        self.assertEqual(len(results), 1, proc.stdout)
        result = json.loads(results[0].read_text(encoding="utf-8"))
        self.assertEqual(result["agent_exit_code"], 0, result)
        self.assertTrue(result["verifier_passed"], result["verification"])
        self.assertTrue(result["success"], result)
        self.assertEqual(result["policy_violations"], [])
        self.assertFalse(any(path.startswith(".sb/") for path in result["changed_files"]))
        envelope = load_envelope(FIXTURE)
        count = len(envelope.nodes or [])
        telemetry = result["telemetry"]
        self.assertEqual(telemetry["graph_nodes_started"], count)
        self.assertEqual(telemetry["graph_nodes_finished"], count)
        started = _graph_event_count(Path(result["trace_path"]), "graph.node.start")
        finished = _graph_event_count(Path(result["trace_path"]), "graph.node.finish")
        self.assertEqual(started, count)
        self.assertEqual(finished, count)
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
