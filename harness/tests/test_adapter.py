from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from livingdict.adapter import run_request
from livingdict.envelope import PlanEnvelope
from livingdict.trace import read_events


REPO = Path(__file__).resolve().parents[2]
CONFIG_01 = REPO / "eval" / "tasks" / "config-01"
ADAPTER = REPO / "harness" / "adapters" / "forth_shen.py"
ORACLE = (CONFIG_01 / "protected" / "oracle" / "files" / "app" / "config.py").read_text(encoding="utf-8")


def _request(workspace: Path, run_dir: Path, resume: bool = False) -> dict:
    return {
        "protocol_version": "1.0",
        "run_id": "adapter-test",
        "arm": "forth-shen",
        "memory_mode": "cold",
        "resume": resume,
        "task": {
            "id": "config-01",
            "family": "config_migration",
            "sequence": 1,
            "allowed_effects": ["read", "write", "exec"],
            "allowed_globs": ["app/config.py"],
            "forbidden_globs": ["tests/**", "TASK.md"],
        },
        "workspace": str(workspace),
        "prompt_path": str(workspace / "TASK.md"),
        "trace_path": str(run_dir / "trace.jsonl"),
        "receipt_path": str(run_dir / "receipt.json"),
        "dictionary_dir": str(run_dir / "dictionary"),
    }


class AdapterTests(unittest.TestCase):
    def test_oracle_envelope_fixes_config_01_public_tests(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)
        workspace = base / "workspace"
        run_dir = base / "run"
        dictionary = run_dir / "dictionary"
        shutil.copytree(CONFIG_01 / "repo", workspace)
        dictionary.mkdir(parents=True)
        envelope = PlanEnvelope(
            language="forth",
            program='S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE RUN-TESTS RECEIPT',
            artifacts={"app/config.py": ORACLE},
        )
        (dictionary / "envelope.json").write_text(envelope.dumps(), encoding="utf-8")
        request = _request(workspace, run_dir)
        code = run_request(request, preflight=True)
        self.assertEqual(code, 0)
        self.assertIn("timeout_seconds", (workspace / "app" / "config.py").read_text(encoding="utf-8"))
        receipt = json.loads((run_dir / "receipt.json").read_text(encoding="utf-8"))
        self.assertEqual(receipt["changed_files"], ["app/config.py"])
        kinds = [event["type"] for event in read_events(run_dir / "trace.jsonl")]
        self.assertIn("mutation.applied", kinds)
        tmp.cleanup()

    def test_subprocess_adapter_rejects_forbidden_write(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)
        workspace = base / "workspace"
        run_dir = base / "run"
        dictionary = run_dir / "dictionary"
        shutil.copytree(CONFIG_01 / "repo", workspace)
        dictionary.mkdir(parents=True)
        envelope = PlanEnvelope(
            language="forth",
            program='S" tests/test_public.py" USE-ARTIFACT S" tests/test_public.py" WRITE-FILE',
            artifacts={"tests/test_public.py": "bad\n"},
        )
        (dictionary / "envelope.json").write_text(envelope.dumps(), encoding="utf-8")
        request = _request(workspace, run_dir)
        request_path = run_dir / "request.json"
        request_path.write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(ADAPTER), str(request_path)],
            cwd=workspace,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        original = (CONFIG_01 / "repo" / "tests" / "test_public.py").read_text(encoding="utf-8")
        self.assertEqual((workspace / "tests" / "test_public.py").read_text(encoding="utf-8"), original)
        events = read_events(run_dir / "trace.jsonl")
        self.assertTrue(any(event["type"] == "preflight.rejected" for event in events))
        tmp.cleanup()

    def test_resume_does_not_rewrite(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)
        workspace = base / "workspace"
        run_dir = base / "run"
        dictionary = run_dir / "dictionary"
        shutil.copytree(CONFIG_01 / "repo", workspace)
        dictionary.mkdir(parents=True)
        envelope = PlanEnvelope(
            language="forth",
            program='S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE RECEIPT',
            artifacts={"app/config.py": ORACLE},
        )
        (dictionary / "envelope.json").write_text(envelope.dumps(), encoding="utf-8")
        first = _request(workspace, run_dir)
        self.assertEqual(run_request(first, preflight=True), 0)
        mutations = [event for event in read_events(run_dir / "trace.jsonl") if event["type"] == "mutation.applied"]
        self.assertEqual(len(mutations), 1)
        second = _request(workspace, run_dir, resume=True)
        self.assertEqual(run_request(second, preflight=True), 0)
        mutations = [event for event in read_events(run_dir / "trace.jsonl") if event["type"] == "mutation.applied"]
        self.assertEqual(len(mutations), 1)
        tmp.cleanup()
