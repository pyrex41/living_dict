from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from livingdict.host import CapabilityError, CapabilityHost
from livingdict.trace import read_events


CONFIG_01 = Path(__file__).resolve().parents[2] / "eval" / "tasks" / "config-01" / "repo"


def _workspace(source: Path | None = None) -> tempfile.TemporaryDirectory[str]:
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    if source is not None:
        shutil.copytree(source, root, dirs_exist_ok=True)
    return tmp


class HostPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = _workspace(CONFIG_01)
        self.root = Path(self.tmp.name)
        self.trace = self.root.parent / f"{self.root.name}-trace.jsonl"
        self.receipt = self.root.parent / f"{self.root.name}-receipt.json"
        self.host = CapabilityHost(
            workspace=self.root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("app/config.py",),
            forbidden_globs=("tests/**", "TASK.md", "secrets.env"),
            trace_path=self.trace,
            receipt_path=self.receipt,
            run_id="test-run",
            task_id="config-01",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()
        self.trace.unlink(missing_ok=True)
        self.receipt.unlink(missing_ok=True)

    def test_write_allowed_config_file(self) -> None:
        before = (self.root / "app" / "config.py").read_text(encoding="utf-8")
        receipt = self.host.write_file(before + "\n# touched\n", "app/config.py")
        self.assertEqual(receipt["path"], "app/config.py")
        self.assertGreater(receipt["bytes"], 0)
        self.assertTrue((self.root / "app" / "config.py").read_text(encoding="utf-8").endswith("# touched\n"))
        kinds = [event["type"] for event in read_events(self.trace)]
        self.assertIn("tool.call", kinds)
        self.assertIn("mutation.applied", kinds)
        mutation = next(event for event in read_events(self.trace) if event["type"] == "mutation.applied")
        self.assertEqual(mutation["data"]["path"], "app/config.py")

    def test_write_forbidden_tests_denied_and_unchanged(self) -> None:
        original = (self.root / "tests" / "test_public.py").read_bytes()
        with self.assertRaises(CapabilityError) as caught:
            self.host.write_file("nope", "tests/test_public.py")
        self.assertEqual(caught.exception.code, "policy")
        self.assertEqual((self.root / "tests" / "test_public.py").read_bytes(), original)
        traps = [event for event in read_events(self.trace) if event["type"] == "execution.trap"]
        self.assertTrue(traps)
        self.assertEqual(traps[-1]["data"]["reason"], "policy")

    def test_write_secrets_denied(self) -> None:
        with self.assertRaises(CapabilityError) as caught:
            self.host.write_file("TOKEN=1\n", "secrets.env")
        self.assertEqual(caught.exception.code, "policy")
        self.assertFalse((self.root / "secrets.env").exists())

    def test_write_outside_allowed_set_denied(self) -> None:
        with self.assertRaises(CapabilityError) as caught:
            self.host.write_file("x", "app/other.py")
        self.assertEqual(caught.exception.code, "policy")
        self.assertFalse((self.root / "app" / "other.py").exists())

    def test_path_escape_is_a_trap(self) -> None:
        with self.assertRaises(CapabilityError) as caught:
            self.host.read_file("../outside.txt")
        self.assertEqual(caught.exception.code, "path")

    def test_missing_file_is_a_trap(self) -> None:
        with self.assertRaises(CapabilityError) as caught:
            self.host.read_file("app/missing.py")
        self.assertEqual(caught.exception.code, "missing_file")

    def test_read_list_search(self) -> None:
        text = self.host.read_file("app/config.py")
        self.assertIn("request_timeout", text)
        listing = self.host.list_dir("app")
        self.assertIn("app/config.py", listing)
        hits = self.host.search("request_timeout")
        self.assertTrue(any(hit["path"] == "app/config.py" for hit in hits))
        self.assertTrue(all({"path", "line", "text"} <= set(hit) for hit in hits))

    def test_run_tests_returns_structured_receipt(self) -> None:
        result = self.host.run_tests()
        self.assertIn("passed", result)
        self.assertIn("returncode", result)
        self.assertIn("stdout", result)
        self.assertIn("stderr", result)
        self.assertFalse(result["passed"])
        self.assertIsInstance(result["returncode"], int)

    def test_receipt_records_change_and_effects(self) -> None:
        self.host.read_file("app/config.py")
        self.host.write_file("DEFAULTS = {}\n", "app/config.py")
        body = self.host.receipt()
        self.assertEqual(body["protocol_version"], "1.0")
        self.assertEqual(body["task_id"], "config-01")
        self.assertEqual(body["changed_files"], ["app/config.py"])
        self.assertIn("read", body["effects_used"])
        self.assertIn("write", body["effects_used"])
        self.assertEqual(body["policy_violations"], [])
        saved = json.loads(self.receipt.read_text(encoding="utf-8"))
        self.assertEqual(saved["changed_files"], ["app/config.py"])


class EffectGateTests(unittest.TestCase):
    def test_write_without_write_effect(self) -> None:
        tmp = _workspace(CONFIG_01)
        root = Path(tmp.name)
        try:
            host = CapabilityHost(
                workspace=root,
                allowed_effects=("read",),
                allowed_globs=("app/config.py",),
                forbidden_globs=(),
            )
            with self.assertRaises(CapabilityError) as caught:
                host.write_file("x", "app/config.py")
            self.assertEqual(caught.exception.code, "effect")
            self.assertIn("request_timeout", (root / "app" / "config.py").read_text(encoding="utf-8"))
        finally:
            tmp.cleanup()


class SafetyWorkspaceTests(unittest.TestCase):
    def test_run_tests_on_tiny_passing_suite(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "pkg").mkdir()
        (root / "pkg" / "__init__.py").write_text("", encoding="utf-8")
        (root / "pkg" / "mod.py").write_text("VALUE = 1\n", encoding="utf-8")
        (root / "tests").mkdir()
        (root / "tests" / "test_mod.py").write_text(
            "import unittest\nfrom pkg.mod import VALUE\n"
            "class T(unittest.TestCase):\n"
            "    def test_value(self):\n"
            "        self.assertEqual(VALUE, 1)\n",
            encoding="utf-8",
        )
        try:
            host = CapabilityHost(
                workspace=root,
                allowed_effects=("read", "write", "exec"),
                allowed_globs=("pkg/mod.py",),
                forbidden_globs=("tests/**",),
            )
            result = host.run_tests()
            self.assertTrue(result["passed"], result)
            receipt = host.receipt()
            self.assertEqual(receipt["check"]["passed"], True)
            self.assertFalse((root / ".sb").exists())
        finally:
            tmp.cleanup()
