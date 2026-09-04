from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from livingdict.cli import _claim_quality, _json_digest, _meaningful_changed_files, gate_feedback

from livingdict.envelope import PlanEnvelope
from livingdict.execute import ExecutionError, lower_artifact_writes, run_forth
from livingdict.host import CapabilityHost


REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "client" / "cli.py"
PLANNER = Path(__file__).resolve().parent / "fizzbuzz_planner.py"
CLAIMS = REPO / "compare" / "fixtures" / "fizzbuzz" / "claims.json"
EPISODES = Path(__file__).resolve().parent / "fixtures" / "fizzbuzz_historical_episodes.json"
HISTORICAL = (
    'S" claims.json" WRITE-FILE\n'
    'S" fizzbuzz.py" WRITE-FILE\n'
    'S" test_fizzbuzz.py" WRITE-FILE\n'
    'S" README.md" WRITE-FILE\n'
    "RUN-GATES\n"
    "RECEIPT"
)


class LowerArtifactTests(unittest.TestCase):
    def test_bookkeeping_is_not_meaningful_progress(self) -> None:
        self.assertEqual(
            _meaningful_changed_files(
                ["claims.json", ".sb/discharge_report.json", ".livingdict-run/events.jsonl", "src/app.py"]
            ),
            ["src/app.py"],
        )

    def test_source_only_claims_are_audited_as_weak(self) -> None:
        quality = _claim_quality(
            {
                "gates": [
                    {
                        "name": "claims",
                        "claims": [{"id": "x", "kind": "source", "passed": True}],
                    }
                ]
            }
        )
        self.assertTrue(quality["source_only"])
        self.assertFalse(quality["has_executable_check"])
        self.assertTrue(quality["warnings"])

    def test_behavior_goal_rejects_compile_only_check(self) -> None:
        quality = _claim_quality(
            {"gates": [{"name": "claims", "claims": [
                {"id": "compile", "kind": "check", "command": "gcc -O3 app.c -lm && test -x a.out"}
            ]}]},
            "write a program and run it to print the expected output",
        )
        self.assertTrue(quality["requires_behavior"])
        self.assertFalse(quality["has_behavioral_check"])

    def test_behavior_goal_accepts_runtime_assertion(self) -> None:
        quality = _claim_quality(
            {"gates": [{"name": "claims", "claims": [
                {"id": "run", "kind": "check", "command": "./a.out input | grep -F expected"}
            ]}]},
            "run the program and print the expected output",
        )
        self.assertTrue(quality["has_behavioral_check"])

    def test_timeout_absolute_executable_is_behavioral(self) -> None:
        quality = _claim_quality(
            {"gates": [{"name": "claims", "claims": [{"kind": "check", "command": "timeout 90 /app/a.out input | tee /tmp/out; test -s /tmp/out"}]}]},
            "run the program and print output",
        )
        self.assertTrue(quality["has_behavioral_check"])

    def test_failed_check_feedback_includes_command_and_output(self) -> None:
        feedback = gate_feedback(
            {
                "gates": [
                    {
                        "name": "claims",
                        "passed": False,
                        "reason": "failed compile",
                        "claims": [
                            {
                                "id": "compile",
                                "kind": "check",
                                "passed": False,
                                "command": "gcc app.c -lm",
                                "output": "undefined reference to expf",
                            }
                        ],
                    }
                ]
            }
        )
        self.assertIn("gcc app.c -lm", feedback)
        self.assertIn("undefined reference to expf", feedback)

    def test_contract_digest_ignores_json_formatting(self) -> None:
        self.assertEqual(_json_digest('{"claims": [{"id": "x"}]}'), _json_digest('{"claims":[{"id":"x"}]}'))


    def test_lowers_one_arity_writes_without_use_artifact(self) -> None:
        artifacts = {
            "README.md": "x",
            "claims.json": "{}",
            "fizzbuzz.py": "x",
            "test_fizzbuzz.py": "x",
        }
        out = lower_artifact_writes(HISTORICAL, artifacts)
        self.assertNotIn("USE-ARTIFACT", out.upper())
        self.assertNotIn("WRITE-FILE", out.upper())
        self.assertIn("RUN-GATES", out.upper())
        self.assertIn("RECEIPT", out.upper())

    def test_leaves_non_artifact_writes(self) -> None:
        program = 'S" other.py" WRITE-FILE RECEIPT'
        self.assertIn("WRITE-FILE", lower_artifact_writes(program, {"fizzbuzz.py": "x"}))


class HistoricalExecuteTests(unittest.TestCase):
    def test_historical_program_installs_artifacts(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("**",),
            forbidden_globs=(".livingdict-run/**",),
        )
        envelope = PlanEnvelope(
            language="forth",
            program=HISTORICAL,
            artifacts={
                "README.md": "fizzbuzz notes\n",
                "claims.json": CLAIMS.read_text(encoding="utf-8"),
                "fizzbuzz.py": "def fizzbuzz(n):\n    return 'FizzBuzz'\n",
                "test_fizzbuzz.py": "import unittest\n",
            },
        )
        self.assertNotIn("USE-ARTIFACT", envelope.program.upper())
        run_forth(host, envelope, preflight=True)
        self.assertTrue((root / "fizzbuzz.py").is_file())
        self.assertTrue((root / "claims.json").is_file())
        tmp.cleanup()

    def test_forbidden_artifact_does_not_write(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        target = root / "secrets.env"
        target.write_text("SAFE\n", encoding="utf-8")
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("**",),
            forbidden_globs=("secrets.env",),
        )
        envelope = PlanEnvelope(
            language="forth",
            program='S" secrets.env" WRITE-FILE RECEIPT',
            artifacts={"secrets.env": "PWNED\n"},
        )
        with self.assertRaises(ExecutionError) as caught:
            run_forth(host, envelope, preflight=True)
        self.assertEqual(caught.exception.code, "preflight")
        self.assertEqual(target.read_text(encoding="utf-8"), "SAFE\n")
        tmp.cleanup()


class ColdFizzbuzzTests(unittest.TestCase):
    def test_historical_envelope_discharges_via_planner_cmd(self) -> None:
        self.assertTrue(EPISODES.is_file())
        stored = json.loads(EPISODES.read_text(encoding="utf-8"))[0]["program"]
        self.assertEqual(stored, HISTORICAL)
        self.assertNotIn("USE-ARTIFACT", stored)

        tmp = tempfile.TemporaryDirectory()
        cwd = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        cwd.mkdir()
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "-p",
                "Write a small Python fizzbuzz in this directory.",
                "--cwd",
                str(cwd),
                "--max-turns",
                "3",
                "--claims",
                str(CLAIMS),
                "--run-dir",
                str(run_dir),
                "--planner-cmd",
                sys.executable,
                str(PLANNER),
            ],
            cwd=str(REPO),
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        for name in ("fizzbuzz.py", "test_fizzbuzz.py", "README.md"):
            self.assertTrue((cwd / name).is_file(), name)
        self.assertIn("def fizzbuzz", (cwd / "fizzbuzz.py").read_text(encoding="utf-8"))
        self.assertFalse((cwd / "GOAL.md").exists())
        self.assertFalse((cwd / "PROGRESS.md").exists())
        self.assertTrue((run_dir / "GOAL.md").is_file())
        self.assertTrue((run_dir / "PROGRESS.md").is_file())
        events = (run_dir / "events.jsonl").read_text(encoding="utf-8")
        self.assertIn("artifacts.applied", events)
        self.assertIn("gates.measured", events)
        self.assertNotIn("USE-ARTIFACT", events)
        receipt = json.loads(proc.stdout)
        self.assertTrue(receipt["ok"])
        self.assertTrue(receipt["discharged"])
        self.assertEqual(receipt["decision"], "success")
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
