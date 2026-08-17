from __future__ import annotations

import unittest

from job import ensure_job_files, ensure_run_gates, imply_artifact_writes
from planner import SYSTEM, extract_json_object, normalize_envelope, observe_dictionary, observe_graph, observe_workspace


class PlannerParseTests(unittest.TestCase):
    def test_strips_fence(self) -> None:
        raw = '```json\n{"language":"forth","program":"3 4 + RECEIPT","artifacts":{}}\n```'
        env = normalize_envelope(extract_json_object(raw))
        self.assertEqual(env["program"], "3 4 + RECEIPT")
        self.assertEqual(env["artifacts"], {})

    def test_embedded_object(self) -> None:
        raw = 'here you go\n{"program":"RECEIPT","artifacts":{"a":"b"},"rationale":"ok"}\nthanks'
        env = normalize_envelope(extract_json_object(raw))
        self.assertEqual(env["artifacts"]["a"], "b")
        self.assertEqual(env["rationale"], "ok")
        self.assertNotIn("continue", env)

    def test_ignores_model_continue_field(self) -> None:
        env = normalize_envelope(extract_json_object('{"program":"RECEIPT","continue":true}'))
        self.assertNotIn("continue", env)

    def test_system_omits_continue_and_job_file_traps(self) -> None:
        self.assertNotIn("continue:", SYSTEM)
        self.assertNotIn("GOAL.md", SYSTEM)
        self.assertNotIn("PROGRESS.md", SYSTEM)

    def test_system_documents_nodes(self) -> None:
        self.assertIn("nodes:", SYSTEM)
        self.assertIn("depends_on", SYSTEM)
        self.assertIn("Kahn", SYSTEM)

    def test_normalize_keeps_nodes_and_allows_empty_program(self) -> None:
        env = normalize_envelope(
            {
                "program": "",
                "nodes": [
                    {
                        "id": "ingest",
                        "writes": ["pipeline/ingest.py"],
                        "depends_on": [],
                        "program": "RECEIPT",
                    }
                ],
                "artifacts": {"pipeline/ingest.py": "x\n"},
            }
        )
        self.assertEqual(env["program"], "")
        self.assertEqual(env["nodes"][0]["id"], "ingest")
        self.assertEqual(env["nodes"][0]["writes"], ["pipeline/ingest.py"])

    def test_observe_empty_product_and_dictionary(self) -> None:
        tmp = __import__("tempfile").TemporaryDirectory()
        root = __import__("pathlib").Path(tmp.name)
        self.assertIn("empty product", observe_workspace(root))
        self.assertIn("empty dictionary", observe_dictionary(root))
        (root / "words").mkdir()
        (root / "words" / "PATCH.fs").write_text(": PATCH ;\n", encoding="utf-8")
        self.assertIn("PATCH", observe_dictionary(root))
        (root / "task_graph.json").write_text('{"nodes":[]}\n', encoding="utf-8")
        self.assertIn('"nodes"', observe_graph(root))
        tmp.cleanup()

    def test_episode_one_does_not_write_job_files_into_workspace(self) -> None:
        tmp = __import__("tempfile").TemporaryDirectory()
        root = __import__("pathlib").Path(tmp.name)
        ensure_job_files(root, "build a compiler", 1)
        self.assertTrue(root.is_dir())
        self.assertFalse((root / "GOAL.md").exists())
        self.assertFalse((root / "PROGRESS.md").exists())
        ensure_job_files(root, "something else", 2)
        self.assertFalse((root / "GOAL.md").exists())
        self.assertFalse((root / "PROGRESS.md").exists())
        tmp.cleanup()

    def test_ensure_run_gates_inserts_before_receipt(self) -> None:
        self.assertIn("RUN-GATES", ensure_run_gates("RECEIPT"))
        self.assertEqual(ensure_run_gates("RUN-GATES RECEIPT"), "RUN-GATES RECEIPT")
        self.assertTrue(ensure_run_gates("S\" a\" INSTALL").endswith("RUN-GATES RECEIPT"))

    def test_imply_artifact_writes_zips_plain_write_file(self) -> None:
        program = 'S" fizzbuzz.py" WRITE-FILE\nRUN-GATES\nRECEIPT'
        out = imply_artifact_writes(program, {"fizzbuzz.py": "def fizzbuzz(n): ...\n"})
        self.assertIn("USE-ARTIFACT", out)
        self.assertIn('S" fizzbuzz.py" WRITE-FILE', out)
        already = 'S" fizzbuzz.py" USE-ARTIFACT S" fizzbuzz.py" WRITE-FILE'
        self.assertEqual(imply_artifact_writes(already, {"fizzbuzz.py": "x"}), already)


if __name__ == "__main__":
    unittest.main()
