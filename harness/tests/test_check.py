from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from livingdict.check import detect_check, extend_path, find_npm, run_workspace_check
from livingdict.host import CapabilityHost


class CheckDetectTests(unittest.TestCase):
    def test_unittest_when_python_tests_exist(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "tests").mkdir()
        (root / "tests" / "test_x.py").write_text("import unittest\n", encoding="utf-8")
        spec = detect_check(root)
        self.assertEqual(spec["kind"], "unittest")
        tmp.cleanup()

    def test_npm_build_when_package_json(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "package.json").write_text(
            json.dumps({"scripts": {"build": "echo ok"}}),
            encoding="utf-8",
        )
        spec = detect_check(root)
        self.assertEqual(spec["kind"], "npm")
        self.assertEqual(spec["label"], "npm run build")
        tmp.cleanup()

    def test_path_includes_nix_or_homebrew_when_present(self) -> None:
        env = extend_path({"PATH": "/usr/bin"})
        self.assertIn("/usr/bin", env["PATH"])
        home_nix = str(Path.home() / ".nix-profile" / "bin")
        if Path(home_nix).is_dir():
            self.assertIn(home_nix, env["PATH"])
        npm = find_npm()
        self.assertTrue(npm.endswith("npm"), npm)

    def test_studio_app_uses_npm_build(self) -> None:
        root = Path(__file__).resolve().parents[2] / "apps" / "studio"
        spec = detect_check(root)
        self.assertEqual(spec["kind"], "npm")
        self.assertEqual(spec["label"], "npm run build")

    def test_empty_studio_is_skipped_pass(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        receipt = run_workspace_check(root)
        self.assertTrue(receipt["passed"])
        self.assertTrue(receipt["skipped"])
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("**",),
            forbidden_globs=(),
        )
        ran = host.run_tests()
        self.assertTrue(ran["passed"])
        self.assertTrue(ran["skipped"])
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
