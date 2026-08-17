from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from livingdict.policy import PathPolicy, changed_files, snapshot, workspace_digest


class PathPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "app").mkdir()
        (self.root / "app" / "config.py").write_text("x\n", encoding="utf-8")
        self.policy = PathPolicy(
            self.root,
            allowed_globs=("app/config.py",),
            forbidden_globs=("tests/**", "secrets.env"),
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_relative_and_escape(self) -> None:
        self.assertEqual(self.policy.relative("app/config.py"), "app/config.py")
        self.assertEqual(self.policy.relative("./app/config.py"), "app/config.py")
        with self.assertRaises(ValueError):
            self.policy.relative("../outside.py")
        with self.assertRaises(ValueError):
            self.policy.relative(self.root.parent / "nope.py")

    def test_write_gate(self) -> None:
        self.assertIsNone(self.policy.write_allowed("app/config.py"))
        self.assertIn("forbidden", self.policy.write_allowed("tests/test_public.py") or "")
        self.assertIn("outside", self.policy.write_allowed("app/other.py") or "")
        self.assertIn("forbidden", self.policy.write_allowed("secrets.env") or "")

    def test_snapshot_and_digest(self) -> None:
        before = snapshot(self.root)
        self.assertIn("app/config.py", before)
        (self.root / "app" / "config.py").write_text("y\n", encoding="utf-8")
        after = snapshot(self.root)
        self.assertEqual(changed_files(before, after), ["app/config.py"])
        self.assertNotEqual(workspace_digest(before), workspace_digest(after))

    def test_snapshot_skips_node_modules(self) -> None:
        nm = self.root / "node_modules" / "x"
        nm.mkdir(parents=True)
        (nm / "index.js").write_text("1\n", encoding="utf-8")
        files = snapshot(self.root)
        self.assertNotIn("node_modules/x/index.js", files)
