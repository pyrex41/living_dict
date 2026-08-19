from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "bin" / "livingdict"
PLANNER = Path(__file__).resolve().parent / "fizzbuzz_planner.py"
CLAIMS = REPO / "compare" / "fixtures" / "fizzbuzz" / "claims.json"


class TuiPipeTests(unittest.TestCase):
    def test_piped_goal_streams_events_and_exits_zero(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        workspace.mkdir()
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "tui",
                "--cwd",
                str(workspace),
                "--claims",
                str(CLAIMS),
                "--planner-cmd",
                sys.executable,
                str(PLANNER),
            ],
            input="Write fizzbuzz.py with tests and README\n",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        self.assertIn("critic accept", proc.stdout)
        self.assertIn("installed", proc.stdout)
        self.assertIn("success: claims discharged", proc.stdout)
        self.assertNotIn("\x1b[", proc.stdout)  # no ANSI when stdout is a pipe
        self.assertTrue((workspace / "fizzbuzz.py").is_file())
        tmp.cleanup()

    def test_thinking_rationale_nodes_and_model_claims_warning(self) -> None:
        """Planner stderr streams live; rationale, node table, and the
        model-authored-claims warning all render."""
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        workspace.mkdir()
        planner = Path(tmp.name) / "planner.py"
        planner.write_text(
            "import json, sys\n"
            "sys.stdin.read()\n"
            "sys.stderr.write('thinking:\\n')\n"
            "sys.stderr.write('pondering the todo problem\\n')\n"
            "sys.stderr.flush()\n"
            "print(json.dumps({\n"
            "  'language': 'forth', 'program': '',\n"
            "  'artifacts': {\n"
            "    'claims.json': json.dumps({'claims': [\n"
            "      {'id': 'app', 'kind': 'source', 'path': 'app.py', 'any': ['def main'], 'min_bytes': 10}]}),\n"
            "    'app.py': 'def main():\\n    return 42\\n'},\n"
            "  'nodes': [\n"
            "    {'id': 'write-product', 'writes': ['app.py', 'claims.json'], 'depends_on': [],\n"
            "     'program': 'S\\\" app.py\\\" WRITE-FILE\\nS\\\" claims.json\\\" WRITE-FILE'},\n"
            "    {'id': 'verify', 'writes': [], 'depends_on': ['write-product'], 'program': 'RUN-GATES'}],\n"
            "  'rationale': 'write app then verify'}))\n",
            encoding="utf-8",
        )
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "tui",
                "--cwd",
                str(workspace),
                "--planner-cmd",
                sys.executable,
                str(planner),
            ],
            input="build the app\n",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        self.assertIn("│ pondering the todo problem", proc.stdout)
        self.assertIn('"write app then verify"', proc.stdout)
        self.assertIn("▤ write-product", proc.stdout)
        self.assertIn("[model-authored claims]", proc.stdout)
        self.assertIn("MODEL-AUTHORED claims", proc.stdout)
        tmp.cleanup()

    def test_hidden_claims_do_not_warn_and_failures_name_claims(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        workspace.mkdir()
        impossible = Path(tmp.name) / "claims.json"
        impossible.write_text(
            '{"claims":[{"id":"never","kind":"source","path":"fizzbuzz.py","any":["def not_there"]}]}',
            encoding="utf-8",
        )
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "tui",
                "--cwd",
                str(workspace),
                "--max-turns",
                "1",
                "--claims",
                str(impossible),
                "--planner-cmd",
                sys.executable,
                str(PLANNER),
            ],
            input="goal\n",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("✗ claim never: wanted def not_there in fizzbuzz.py", proc.stdout)
        self.assertNotIn("MODEL-AUTHORED", proc.stdout)
        tmp.cleanup()

    def test_pipe_mode_stops_on_failure_exit(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        workspace.mkdir()
        impossible = Path(tmp.name) / "claims.json"
        impossible.write_text(
            '{"claims":[{"id":"never","kind":"source","path":"fizzbuzz.py","any":["def not_there"]}]}',
            encoding="utf-8",
        )
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "tui",
                "--cwd",
                str(workspace),
                "--max-turns",
                "1",
                "--claims",
                str(impossible),
                "--planner-cmd",
                sys.executable,
                str(PLANNER),
            ],
            input="goal one\ngoal two\n",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.count("∙ e1 plan"), 1)
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
