from __future__ import annotations

import json
import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ldeval.discovery import discover_tasks, select_tasks
from ldeval.forthcheck import validate_straight_line
from ldeval.policy import changed_files, violations
from ldeval.scoring import aggregate, compare
from ldeval.trace import read_events, summarize


ROOT = Path(__file__).resolve().parents[1]


class DiscoveryTests(unittest.TestCase):
    def test_catalog_has_five_ordered_families(self) -> None:
        tasks = discover_tasks()
        self.assertEqual(len(tasks), 40)
        families = sorted({task.family for task in tasks})
        self.assertEqual(families, [
            "config_migration",
            "graph_coordination",
            "parser_repair",
            "safety_boundary",
            "validation_ladder",
        ])
        for family in families:
            members = [task for task in tasks if task.family == family]
            self.assertEqual([task.sequence for task in members], list(range(1, 9)))
            self.assertIn("crash_recovery", members[4].mechanisms)
            self.assertIn("false_friend", members[7].mechanisms)

    def test_selection_is_an_intersection(self) -> None:
        selected = select_tasks(
            discover_tasks(),
            families={"config_migration"},
            mechanisms={"false_friend"},
        )
        self.assertEqual([task.id for task in selected], ["config-08"])

    def test_fixture_generator_is_deterministic(self) -> None:
        def digest() -> str:
            value = hashlib.sha256()
            for path in sorted((ROOT / "tasks").rglob("*")):
                if path.is_file():
                    value.update(path.relative_to(ROOT).as_posix().encode())
                    value.update(path.read_bytes())
            return value.hexdigest()

        before = digest()
        subprocess.run(
            [sys.executable, str(ROOT / "tools/build_tasks.py")],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(digest(), before)


class ForthCheckTests(unittest.TestCase):
    def test_valid_capability_program(self) -> None:
        result = validate_straight_line(
            "TASK OBSERVE PROPOSE-PATCH CHECK-PATCH APPLY-PATCH RUN-TESTS REQUIRE-PASS RECEIPT",
            {"read", "write", "exec", "model"},
        )
        self.assertTrue(result["valid"], result)
        self.assertEqual(result["final_depth"], 1)

    def test_underflow_unknown_word_and_effect_rejection(self) -> None:
        result = validate_straight_line("DROP MYSTERY TASK APPLY-PATCH", {"read"})
        self.assertFalse(result["valid"])
        self.assertTrue(any("underflow" in error for error in result["errors"]))
        self.assertTrue(any("unknown word" in error for error in result["errors"]))
        self.assertTrue(any("effects not allowed" in error for error in result["errors"]))


class PolicyAndTraceTests(unittest.TestCase):
    def test_snapshot_diff_policy(self) -> None:
        before = {"src/a.py": "old", "README.md": "same"}
        after = {"src/a.py": "new", "README.md": "same", "PWNED.txt": "x"}
        changed = changed_files(before, after)
        self.assertEqual(changed, ["PWNED.txt", "src/a.py"])
        self.assertEqual(
            violations(changed, ("src/*.py",), ("PWNED.txt",)),
            ["forbidden path changed: PWNED.txt"],
        )

    def test_malformed_trace_lines_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
            trace = Path(tmp) / "trace.jsonl"
            trace.write_text(
                '{"type":"llm.response","data":{"input_tokens":10,"output_tokens":2}}\n'
                'not-json\n'
                '{"type":"dictionary.reuse","data":{}}\n',
                encoding="utf-8",
            )
            telemetry = summarize(read_events(trace))
        self.assertEqual(telemetry["model_calls"], 1)
        self.assertEqual(telemetry["input_tokens"], 10)
        self.assertEqual(telemetry["dictionary_reuses"], 1)


class ScoringTests(unittest.TestCase):
    @staticmethod
    def result(task_id: str, success: bool, tokens: int, calls: int) -> dict:
        return {
            "task_id": task_id,
            "family": "family",
            "success": success,
            "elapsed_seconds": 1.0,
            "policy_violations": [],
            "telemetry": {
                "input_tokens": tokens,
                "output_tokens": 0,
                "model_calls": calls,
            },
        }

    def test_aggregate_and_paired_direction(self) -> None:
        left = [self.result("a", False, 100, 4), self.result("b", True, 80, 3)]
        right = [self.result("a", True, 60, 2), self.result("b", True, 40, 1)]
        self.assertEqual(aggregate(left)["overall"]["success_rate"], 0.5)
        delta = compare(left, right)["right_minus_left"]
        self.assertEqual(delta["success_rate"], 0.5)
        self.assertEqual(delta["median_tokens"], -40.0)
        self.assertEqual(delta["median_model_calls"], -2.0)

    def test_schemas_are_valid_json(self) -> None:
        for path in sorted((ROOT / "schemas").glob("*.json")):
            self.assertIsInstance(json.loads(path.read_text(encoding="utf-8")), dict)
