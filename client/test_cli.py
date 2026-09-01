from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "client" / "cli.py"
BIN = ROOT / "bin" / "livingdict"


class CliEntryTests(unittest.TestCase):
    def test_help(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(CLI), "-h"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--planner-cmd", proc.stdout)
        self.assertIn("--run-dir", proc.stdout)
        self.assertIn("--cwd", proc.stdout)
        self.assertIn("--cache-scope", proc.stdout)

    def test_bin_help(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(BIN), "-h"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("-p", proc.stdout)


if __name__ == "__main__":
    unittest.main()
