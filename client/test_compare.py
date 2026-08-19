from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from compare import (
    changed,
    grok_argv,
    livingdict_argv,
    parse_grok_json,
    parse_livingdict_json,
    parse_pi_json,
    pi_argv,
    seed_copy,
    snapshot,
    write_summary,
)
from job import ensure_run_gates
from arms import ArmResult, validate_arm_name


class SnapshotTests(unittest.TestCase):
    def test_changed_files_skip_vendor_trees(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "a.txt").write_text("one\n", encoding="utf-8")
        before = snapshot(root)
        (root / "a.txt").write_text("two plus\n", encoding="utf-8")
        (root / "b.txt").write_text("new\n", encoding="utf-8")
        (root / "node_modules").mkdir()
        (root / "node_modules" / "x.js").write_text("x\n", encoding="utf-8")
        (root / "dist").mkdir()
        (root / "dist" / "index.html").write_text("<html></html>\n", encoding="utf-8")
        after = snapshot(root)
        self.assertEqual(changed(before, after), ["a.txt", "b.txt"])
        tmp.cleanup()


class ArmProtocolTests(unittest.TestCase):
    def test_normalizes_cost_and_failure_metrics(self) -> None:
        result = ArmResult.from_raw(
            "json-plan",
            {
                "ok": True,
                "exit": 0,
                "duration_ms": 12,
                "changed_files": ["a.py"],
                "parsed": {"turns": 2, "tool_calls": 3, "usage": {"input_tokens": 10}},
            },
        )
        self.assertEqual(result.model_calls, 2)
        self.assertEqual(result.tool_calls, 3)
        self.assertEqual(result.input_tokens, 10)
        self.assertEqual(result.changed_files, ["a.py"])

    def test_arm_names_are_explicit(self) -> None:
        self.assertEqual(validate_arm_name("python-plan"), "python-plan")
        with self.assertRaises(ValueError):
            validate_arm_name("unknown")

    def test_seed_copy_empty_and_ignore_node_modules(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        src = Path(tmp.name) / "src"
        dest = Path(tmp.name) / "dest"
        src.mkdir()
        (src / "keep.py").write_text("ok\n", encoding="utf-8")
        (src / "node_modules").mkdir()
        (src / "node_modules" / "pkg.js").write_text("nope\n", encoding="utf-8")
        seed_copy(src, dest)
        self.assertTrue((dest / "keep.py").is_file())
        self.assertFalse((dest / "node_modules").exists())
        empty = Path(tmp.name) / "empty"
        seed_copy(None, empty)
        self.assertTrue((empty / "README.md").is_file())
        tmp.cleanup()


class ParseTests(unittest.TestCase):
    def test_parse_grok_json(self) -> None:
        raw = '{"text":"hello","num_turns":3,"stopReason":"end_turn"}'
        parsed = parse_grok_json(raw)
        self.assertEqual(parsed["text"], "hello")
        self.assertEqual(parsed["turns"], 3)

    def test_parse_grok_json_embedded(self) -> None:
        raw = 'noise\n{"text":"ok","num_turns":1}\n'
        parsed = parse_grok_json(raw)
        self.assertEqual(parsed["text"], "ok")

    def test_parse_pi_jsonl_message_end(self) -> None:
        raw = (
            '{"type":"session","id":"x"}\n'
            '{"type":"tool_execution_start","toolName":"write"}\n'
            '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}\n'
        )
        parsed = parse_pi_json(raw)
        self.assertIn("done", parsed["text"])
        self.assertEqual(parsed["tool_calls"], 1)

    def test_parse_pi_legacy_text_events(self) -> None:
        raw = '{"type":"text","text":"hi "}\n{"type":"text","text":"there"}\n'
        parsed = parse_pi_json(raw)
        self.assertIn("hi", parsed["text"])
        self.assertIn("there", parsed["text"])


class ArgvTests(unittest.TestCase):
    def test_grok_is_headless_json_yolo(self) -> None:
        argv = grok_argv("build it", Path("/tmp/arm"), model="grok-4.6", max_turns=4)
        self.assertIn("-p", argv)
        self.assertIn("--output-format", argv)
        self.assertIn("json", argv)
        self.assertIn("--always-approve", argv)
        self.assertIn("--max-turns", argv)
        self.assertIn("4", argv)
        self.assertIn("/tmp/arm", argv)

    def test_pi_is_headless_json_isolated(self) -> None:
        argv = pi_argv("build it", model="", provider="")
        self.assertIn("-p", argv)
        self.assertIn("--mode", argv)
        self.assertIn("json", argv)
        self.assertIn("--no-session", argv)
        self.assertIn("--no-approve", argv)
        self.assertIn("--no-context-files", argv)
        self.assertEqual(argv[-1], "build it")

    def test_livingdict_is_headless_argv(self) -> None:
        cwd = Path("/tmp/arm")
        argv = livingdict_argv("build it", cwd, max_turns=4, run_dir=cwd / ".livingdict-run")
        self.assertIn("-p", argv)
        self.assertIn("build it", argv)
        self.assertIn("--cwd", argv)
        self.assertIn("/tmp/arm", argv)
        self.assertIn("--max-turns", argv)
        self.assertIn("4", argv)
        self.assertIn("--run-dir", argv)
        joined = " ".join(argv)
        self.assertNotIn("http://", joined)
        self.assertNotIn("/think", joined)


class SummaryTests(unittest.TestCase):
    def test_write_summary_table(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        out = Path(tmp.name)
        write_summary(
            out,
            "write hello.txt",
            [
                {
                    "arm": "grok",
                    "ok": True,
                    "duration_ms": 12,
                    "changed_files": ["hello.txt"],
                    "parsed": {"turns": 2, "text": "wrote hello"},
                    "judge": {"passed": True},
                }
            ],
        )
        md = (out / "summary.md").read_text(encoding="utf-8")
        self.assertIn("write hello.txt", md)
        self.assertIn("grok", md)
        self.assertIn("hello.txt", md)
        payload = json.loads((out / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(payload["arms"][0]["arm"], "grok")
        tmp.cleanup()


class JobHelperStillIndependent(unittest.TestCase):
    def test_job_gates_helper_not_on_compare(self) -> None:
        self.assertIn("RUN-GATES", ensure_run_gates("RECEIPT"))
        import compare as compare_mod

        self.assertFalse(hasattr(compare_mod, "ensure_run_gates_unused"))


class DryRunTests(unittest.TestCase):
    def test_dry_run_does_not_require_prompt(self) -> None:
        from compare import main

        code = main(["--dry-run"])
        self.assertIn(code, (0, 1))


class RunLoopTests(unittest.TestCase):
    def test_main_writes_isolated_arms_and_summary(self) -> None:
        from compare import main

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = Path(tmp.name) / "run"

        def fake_grok(prompt, cwd, **_kwargs):
            (cwd / "hello.txt").write_text("hello from grok\n", encoding="utf-8")
            return {"ok": True, "exit": 0, "stdout": "{}", "stderr": "", "duration_ms": 3, "parsed": {"turns": 1}}

        def fake_pi(prompt, cwd, **_kwargs):
            (cwd / "hello.txt").write_text("hello from pi\n", encoding="utf-8")
            return {"ok": True, "exit": 0, "stdout": "{}", "stderr": "", "duration_ms": 4, "parsed": {"turns": 1}}

        def fake_ld(prompt, cwd, **_kwargs):
            (cwd / "hello.txt").write_text("hello from livingdict\n", encoding="utf-8")
            (cwd / ".dictionary" / "words").mkdir(parents=True, exist_ok=True)
            return {
                "ok": True,
                "exit": 0,
                "stdout": "[]",
                "stderr": "",
                "duration_ms": 5,
                "episodes": [{"episode": 1, "ok": True}],
                "parsed": {"turns": 1, "discharged": False},
            }

        with (
            patch("compare.run_grok", side_effect=fake_grok),
            patch("compare.run_pi", side_effect=fake_pi),
            patch("compare.run_livingdict", side_effect=fake_ld),
        ):
            code = main(["--prompt", "Write hello.txt", "--out", str(out)])
        self.assertEqual(code, 0)
        self.assertTrue((out / "grok" / "hello.txt").is_file())
        self.assertTrue((out / "pi" / "hello.txt").is_file())
        self.assertTrue((out / "livingdict" / "hello.txt").is_file())
        self.assertNotEqual((out / "grok" / "hello.txt").read_text(), (out / "pi" / "hello.txt").read_text())
        summary = json.loads((out / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual([row["arm"] for row in summary["arms"]], ["grok", "pi", "livingdict"])
        self.assertEqual(summary["arms"][0]["changed_files"], ["hello.txt"])

    def test_livingdict_receipt_json(self) -> None:
        parsed = parse_livingdict_json(
            json.dumps({"ok": True, "decision": "success", "discharged": True, "episodes": 2, "reason": "claims discharged"})
        )
        self.assertTrue(parsed["discharged"])
        self.assertEqual(parsed["turns"], 2)
        self.assertEqual(parsed["text"], "claims discharged")

    def test_hidden_claims_score_every_arm(self) -> None:
        from compare import measure_hidden_claims

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name) / "arm"
        root.mkdir()
        (root / "hello.txt").write_text("hello world\n", encoding="utf-8")
        claims = Path(tmp.name) / "claims.json"
        claims.write_text(
            json.dumps(
                {"claims": [{"id": "hello", "kind": "file", "path": "hello.txt", "any": ["hello world"], "min_bytes": 5}]}
            ),
            encoding="utf-8",
        )
        report = measure_hidden_claims(root, claims)
        self.assertTrue(report.get("passed"), report)
        self.assertFalse((root / "claims.json").exists())


if __name__ == "__main__":
    unittest.main()
