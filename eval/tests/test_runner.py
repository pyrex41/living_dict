from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ldeval.discovery import discover_tasks
from ldeval.runner import run_suite, run_task


ROOT = Path(__file__).resolve().parents[1]
NOOP = ROOT / "adapters" / "noop.py"
RESUMABLE = ROOT / "tests" / "fixtures" / "resumable_agent.py"
POLICY = ROOT / "tests" / "fixtures" / "policy_agent.py"


def task(task_id: str):
    return next(item for item in discover_tasks() if item.id == task_id)


class RunnerTests(unittest.TestCase):
    def test_workspace_does_not_receive_protected_material(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            result = run_task(
                task("config-01"), Path(tmp), "noop",
                agent_command=f"python3 {NOOP}",
            )
            workspace = Path(result.workspace)
            self.assertFalse((workspace / "protected").exists())
            self.assertFalse(any(workspace.rglob("verify.py")))
            self.assertTrue((workspace / "TASK.md").exists())

    def test_policy_violation_overrides_agent_exit(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            result = run_task(
                task("safety-01"), Path(tmp), "policy-test",
                agent_command=f"python3 {POLICY}",
            )
        self.assertEqual(result.agent_exit_code, 0)
        self.assertFalse(result.success)
        self.assertTrue(any("PWNED.txt" in value for value in result.policy_violations))

    def test_fault_injection_relaunches_same_workspace(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            result = run_task(
                task("config-05"), Path(tmp), "resumable",
                agent_command=f"python3 {RESUMABLE}", inject_fault=True,
            )
        self.assertTrue(result.success, result.verification)
        self.assertTrue(result.telemetry["crash_injected"])
        self.assertTrue(result.telemetry["resumed"])
        self.assertEqual(result.telemetry["mutations"], 1)

    def test_warm_mode_shares_dictionary_within_family(self) -> None:
        members = [task("config-01"), task("config-02")]
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            results = run_suite(
                members, Path(tmp), "oracle", None, True,
                "warm", False, True,
            )
            dictionaries = Path(tmp) / "dictionaries" / "config_migration"
            self.assertTrue(dictionaries.is_dir())
            requests = [
                Path(result.workspace).parent / "request.json"
                for result in results
            ]
            dictionary_values = {
                __import__("json").loads(path.read_text(encoding="utf-8"))["dictionary_dir"]
                for path in requests
            }
            self.assertEqual(len(dictionary_values), 1)


class FixtureSeparationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix=".test-runs-", dir=ROOT)
        base = Path(cls.temp.name)
        tasks = discover_tasks()
        cls.oracle = run_suite(tasks, base / "oracle", "oracle", None, True, "cold", False, False)
        cls.noop = run_suite(
            tasks, base / "noop", "noop", f"python3 {NOOP}", False,
            "cold", False, False,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_every_oracle_passes(self) -> None:
        failures = [result.task_id for result in self.oracle if not result.success]
        self.assertEqual(failures, [])

    def test_every_untouched_fixture_fails(self) -> None:
        accidental = [result.task_id for result in self.noop if result.success]
        self.assertEqual(accidental, [])
