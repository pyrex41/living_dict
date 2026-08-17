from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from livingdict.envelope import GraphNode, PlanEnvelope
from livingdict.execute import ExecutionError, run_forth
from livingdict.host import CapabilityHost
from livingdict.preflight import validate


class PreflightTests(unittest.TestCase):
    def test_accepts_straight_line_capability_program(self) -> None:
        program = (
            'S" src/records.py" USE-ARTIFACT\n'
            'S" src/records.py" WRITE-FILE\n'
            "RUN-TESTS RECEIPT"
        )
        result = validate(
            program,
            {"read", "write", "exec"},
            allowed_globs=["src/records.py"],
            artifacts={"src/records.py": "ok\n"},
        )
        self.assertTrue(result["valid"], result)
        self.assertIn("write", result["effects"])

    def test_run_gates_is_a_host_word(self) -> None:
        result = validate("RUN-GATES RECEIPT", {"read", "write", "exec"})
        self.assertTrue(result["valid"], result)
        self.assertIn("exec", result["effects"])

    def test_rejects_unknown_underflow_and_forbidden_write(self) -> None:
        result = validate(
            "DROP MYSTERY S\" tests/test_public.py\" WRITE-FILE",
            {"read", "write", "exec"},
            allowed_globs=["app/config.py"],
            forbidden_globs=["tests/**"],
        )
        self.assertFalse(result["valid"])
        joined = " ".join(result["errors"])
        self.assertIn("underflow", joined)
        self.assertIn("unknown word", joined)
        self.assertIn("forbidden", joined)

    def test_rejects_missing_artifact(self) -> None:
        result = validate(
            'S" app/config.py" USE-ARTIFACT',
            {"read", "write", "exec"},
            artifacts={},
        )
        self.assertFalse(result["valid"])
        self.assertTrue(any("no artifact" in error for error in result["errors"]))

    def test_artifact_key_outside_globs_is_reject(self) -> None:
        result = validate(
            "RECEIPT",
            {"read", "write", "exec"},
            allowed_globs=["app/config.py"],
            forbidden_globs=["tests/**"],
            artifacts={"tests/test_public.py": "PWNED\n"},
        )
        self.assertFalse(result["valid"])
        joined = " ".join(result["errors"])
        self.assertIn("artifact", joined)
        self.assertIn("forbidden", joined)

    def test_rejected_program_does_not_write(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "tests").mkdir()
        target = root / "tests" / "test_public.py"
        target.write_text("SAFE\n", encoding="utf-8")
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("app/config.py",),
            forbidden_globs=("tests/**",),
        )
        envelope = PlanEnvelope(
            language="forth",
            program='S" tests/test_public.py" USE-ARTIFACT S" tests/test_public.py" WRITE-FILE',
            artifacts={"tests/test_public.py": "PWNED\n"},
        )
        with self.assertRaises(ExecutionError) as caught:
            run_forth(host, envelope, preflight=True)
        self.assertEqual(caught.exception.code, "preflight")
        self.assertEqual(target.read_text(encoding="utf-8"), "SAFE\n")
        tmp.cleanup()


def _node(ident: str, writes: list[str], deps: list[str] | None = None, program: str = "RECEIPT") -> GraphNode:
    return GraphNode(id=ident, writes=writes, depends_on=deps or [], program=program)


class GraphCriticTests(unittest.TestCase):
    def test_duplicate_node_id(self) -> None:
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["**"],
            artifacts={"a.py": "x\n"},
            nodes=[_node("a", ["a.py"]), _node("a", ["a.py"])],
        )
        self.assertFalse(result["valid"])
        self.assertTrue(any("duplicate node id" in error for error in result["errors"]))

    def test_unknown_depends_on(self) -> None:
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["**"],
            artifacts={"a.py": "x\n"},
            nodes=[_node("a", ["a.py"], ["missing"])],
        )
        self.assertFalse(result["valid"])
        self.assertTrue(any("unknown depends_on" in error for error in result["errors"]))

    def test_dependency_cycle(self) -> None:
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["**"],
            artifacts={"a.py": "x\n", "b.py": "y\n"},
            nodes=[
                _node("a", ["a.py"], ["b"]),
                _node("b", ["b.py"], ["a"]),
            ],
        )
        self.assertFalse(result["valid"])
        joined = " ".join(result["errors"])
        self.assertIn("dependency cycle", joined)
        self.assertIn("a", joined)
        self.assertIn("b", joined)

    def test_out_of_node_write(self) -> None:
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["pipeline/*.py"],
            artifacts={"pipeline/a.py": "x\n"},
            nodes=[
                _node(
                    "a",
                    ["pipeline/a.py"],
                    program='S" x" S" pipeline/b.py" WRITE-FILE',
                )
            ],
        )
        self.assertFalse(result["valid"])
        joined = " ".join(result["errors"])
        self.assertIn("node a:", joined)
        self.assertIn("path outside allowed change set", joined)

    def test_overlapping_independent_writes(self) -> None:
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["**"],
            artifacts={"shared.py": "x\n"},
            nodes=[_node("left", ["shared.py"]), _node("right", ["shared.py"])],
        )
        self.assertFalse(result["valid"])
        self.assertTrue(any("overlapping independent writes" in error for error in result["errors"]))

    def test_overlap_allowed_when_dependent(self) -> None:
        result = validate(
            "RECEIPT",
            {"read", "write", "exec"},
            allowed_globs=["**"],
            artifacts={"shared.py": "x\n"},
            nodes=[
                _node("first", ["shared.py"]),
                _node("second", ["shared.py"], ["first"]),
            ],
        )
        self.assertTrue(result["valid"], result)

    def test_uncovered_artifact(self) -> None:
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["**"],
            artifacts={"a.py": "x\n", "b.py": "y\n"},
            nodes=[_node("a", ["a.py"])],
        )
        self.assertFalse(result["valid"])
        self.assertTrue(any("uncovered artifact: b.py" in error for error in result["errors"]))

    def test_task_graph_order_inconsistency(self) -> None:
        task_graph = {
            "nodes": [
                {"id": "ingest", "writes": ["pipeline/ingest.py"], "depends_on": []},
                {
                    "id": "registry",
                    "writes": ["pipeline/registry.py"],
                    "depends_on": ["ingest"],
                },
            ]
        }
        result = validate(
            "",
            {"read", "write", "exec"},
            allowed_globs=["pipeline/*.py"],
            artifacts={
                "pipeline/ingest.py": "x\n",
                "pipeline/registry.py": "y\n",
            },
            nodes=[
                _node("registry", ["pipeline/registry.py"]),
                _node("ingest", ["pipeline/ingest.py"], ["registry"]),
            ],
            task_graph=task_graph,
        )
        self.assertFalse(result["valid"])
        joined = " ".join(result["errors"])
        self.assertIn("graph order", joined)
        self.assertIn("registry", joined)
        self.assertIn("ingest", joined)

    def test_absent_nodes_unchanged(self) -> None:
        result = validate("RUN-GATES RECEIPT", {"read", "write", "exec"})
        self.assertTrue(result["valid"], result)
