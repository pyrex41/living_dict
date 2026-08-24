from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

from livingdict.gates import (
    infer_gates,
    measure_bundle,
    measure_sources,
    parse_gates_toml,
    run_gates,
)


class ParseManifestTests(unittest.TestCase):
    def test_parses_wave1_gates_tables(self) -> None:
        text = """
[project]
lang = "js"

[[gates]]
name = "sources"
kind = "livingdict"
measure = "sources"

[[gates]]
name = "build"
kind = "command"
run = "npm run build"
"""
        gates = parse_gates_toml(text)
        self.assertEqual(len(gates), 2)
        self.assertEqual(gates[0]["name"], "sources")
        self.assertEqual(gates[0]["measure"], "sources")
        self.assertEqual(gates[1]["run"], "npm run build")


class MeasureTests(unittest.TestCase):
    def test_sources_fail_without_app(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "package.json").write_text("{}", encoding="utf-8")
        result = measure_sources(root)
        self.assertFalse(result["passed"])
        self.assertIn("index.html", result["reason"])
        tmp.cleanup()

    def test_sources_pass_solid_layout(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "package.json").write_text('{"scripts":{"build":"echo ok"}}', encoding="utf-8")
        (root / "index.html").write_text("<div id='root'></div>", encoding="utf-8")
        (root / "src").mkdir()
        (root / "src" / "App.jsx").write_text("export default function App(){return null}", encoding="utf-8")
        result = measure_sources(root)
        self.assertTrue(result["passed"], result)
        self.assertIn("src/App.jsx", result["evidence"])
        tmp.cleanup()

    def test_bundle_fails_without_dist(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        result = measure_bundle(root)
        self.assertFalse(result["passed"])
        tmp.cleanup()

    def test_bundle_passes_with_referenced_js(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        assets = root / "dist" / "assets"
        assets.mkdir(parents=True)
        (root / "dist" / "index.html").write_text(
            '<script type="module" src="/scene/assets/app.js"></script>',
            encoding="utf-8",
        )
        (assets / "app.js").write_text("console.log('ok');\n", encoding="utf-8")
        result = measure_bundle(root)
        self.assertTrue(result["passed"], result)
        tmp.cleanup()

    def test_run_gates_and_is_conjunction(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "sb.toml").write_text(
            '[[gates]]\nname = "sources"\nkind = "livingdict"\nmeasure = "sources"\n',
            encoding="utf-8",
        )
        (root / "package.json").write_text("{}", encoding="utf-8")
        report = run_gates(root, timeout=5)
        self.assertFalse(report["passed"])
        self.assertEqual(report["schema_version"], 1)
        self.assertTrue((root / ".sb" / "discharge_report.json").is_file())
        names = [g["name"] for g in report["gates"]]
        self.assertEqual(names, ["sources", "claims"])
        tmp.cleanup()

    def test_infer_studio_includes_goal_gates(self) -> None:
        root = Path(__file__).resolve().parents[2] / "apps" / "studio"
        if not (root / "package.json").is_file():
            self.skipTest("studio missing")
        specs = infer_gates(root)
        names = [s.get("name") for s in specs]
        self.assertIn("sources", names)
        self.assertIn("build", names)
        self.assertIn("claims", names)

    def test_missing_claims_fail(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        result = __import__("livingdict.gates", fromlist=["measure_claims"]).measure_claims(root)
        self.assertFalse(result["passed"])
        self.assertEqual(result["layer"], "goal")
        tmp.cleanup()

    def test_source_claim_scans_workspace(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "src").mkdir()
        (root / "src" / "main.py").write_text("def add(a, b):\n    return a + b\n", encoding="utf-8")
        (root / "claims.json").write_text(
            json.dumps({"claims": [{"id": "add", "kind": "source", "any": ["def add"]}]}),
            encoding="utf-8",
        )
        result = __import__("livingdict.gates", fromlist=["measure_claims"]).measure_claims(root)
        self.assertTrue(result["passed"], result)
        tmp.cleanup()

    def test_path_claim_fails_on_tiny_stub(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "index.html").write_text("<title>ocean beach</title>\n", encoding="utf-8")
        (root / "claims.json").write_text(
            json.dumps(
                {
                    "claims": [
                        {
                            "id": "ocean",
                            "kind": "source",
                            "path": "index.html",
                            "any": ["ocean"],
                            "min_bytes": 120,
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        result = __import__("livingdict.gates", fromlist=["measure_claims"]).measure_claims(root)
        self.assertFalse(result["passed"], result)
        tmp.cleanup()


class StudioGatesLiveTests(unittest.TestCase):
    def test_studio_sources_pass(self) -> None:
        root = Path(__file__).resolve().parents[2] / "apps" / "studio"
        result = measure_sources(root)
        self.assertTrue(result["passed"], result)

    def test_studio_run_includes_claims_gate(self) -> None:
        root = Path(__file__).resolve().parents[2] / "apps" / "studio"
        if not (root / "node_modules").is_dir():
            self.skipTest("studio deps not installed")
        report = run_gates(root, timeout=120)
        names = [g["name"] for g in report["gates"]]
        self.assertIn("claims", names)
        self.assertIn("look", names)


if __name__ == "__main__":
    unittest.main()


class CheckClaimTests(unittest.TestCase):
    def _workspace(self, claims: dict) -> tempfile.TemporaryDirectory:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "claims.json").write_text(json.dumps(claims), encoding="utf-8")
        (root / "app.py").write_text("print(42)\n" * 20, encoding="utf-8")
        return tmp

    def test_check_claims_denied_without_contract_authority(self) -> None:
        from livingdict.gates import run_gates

        tmp = self._workspace(
            {"claims": [{"id": "runs", "kind": "check", "command": "true"}]}
        )
        report = run_gates(Path(tmp.name), persist=False)  # allow_check defaults False
        claims_gate = next(g for g in report["gates"] if g["name"] == "claims")
        self.assertFalse(claims_gate["passed"])
        entry = claims_gate["claims"][0]
        self.assertIn("approved or hidden contract", entry["reason"])
        tmp.cleanup()

    def test_check_claims_execute_under_contract(self) -> None:
        from livingdict.gates import run_gates

        tmp = self._workspace(
            {
                "claims": [
                    {"id": "ok", "kind": "check", "command": "test -f app.py"},
                    {"id": "bad", "kind": "check", "command": "exit 3"},
                ]
            }
        )
        report = run_gates(Path(tmp.name), persist=False, allow_check=True)
        claims_gate = next(g for g in report["gates"] if g["name"] == "claims")
        by_id = {c["id"]: c for c in claims_gate["claims"]}
        self.assertTrue(by_id["ok"]["passed"])
        self.assertFalse(by_id["bad"]["passed"])
        self.assertEqual(by_id["bad"]["returncode"], 3)
        self.assertFalse(claims_gate["passed"])
        tmp.cleanup()

    def test_bifrost_without_shen_launcher_fails_fast(self) -> None:
        from livingdict.gates import run_gates

        tmp = self._workspace(
            {"claims": [{"id": "shake", "kind": "check", "command": "bifrost --shake"}]}
        )
        report = run_gates(Path(tmp.name), persist=False, allow_check=True)
        entry = next(c for c in report["gates"][0]["claims"] if c["id"] == "shake")
        # The test environment has no Shen launcher; this must not consume the
        # generic 60-second command timeout.
        self.assertIn("missing Shen launcher", entry.get("reason", ""))
        self.assertFalse(entry.get("timed_out"))
        tmp.cleanup()

    def test_dependent_http_check_is_blocked_after_build_failure(self) -> None:
        from livingdict.gates import run_gates

        tmp = self._workspace(
            {
                "claims": [
                    {"id": "build", "kind": "check", "command": "exit 7"},
                    {"id": "http", "kind": "check", "command": "curl -sf http://127.0.0.1:1"},
                ]
            }
        )
        report = run_gates(Path(tmp.name), persist=False, allow_check=True)
        checks = {item["id"]: item for item in report["gates"][0]["claims"]}
        self.assertEqual(checks["build"]["returncode"], 7)
        self.assertIn("blocked by failed prerequisite", checks["http"]["reason"])
        self.assertIn("build", checks["http"]["blocked_by"])
        tmp.cleanup()

    def test_successful_static_gate_is_cached(self) -> None:
        from livingdict.gates import run_gates

        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "app.py").write_text("def main():\n    return 1\n" + ("# padding\n" * 20), encoding="utf-8")
        (root / "claims.json").write_text(
            json.dumps({"claims": [{"id": "main", "kind": "source", "path": "app.py", "any": ["def main"]}]}),
            encoding="utf-8",
        )
        first = run_gates(root, persist=True)
        second = run_gates(root, persist=True)
        cached = [gate for gate in second["gates"] if gate.get("cached")]
        self.assertTrue(cached, second)
        tmp.cleanup()

    def test_http_fixture_starts_once_and_is_torn_down(self) -> None:
        from livingdict.gates import run_gates

        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        fixture = {"command": f"{sys.executable} -m http.server 18765 --bind 127.0.0.1", "ready_url": "http://127.0.0.1:18765/"}
        claims = {
            "claims": [
                {"id": "one", "kind": "check", "command": "curl -sf http://127.0.0.1:18765/", "fixture": fixture},
                {"id": "two", "kind": "check", "command": "curl -sf http://127.0.0.1:18765/", "fixture": fixture},
            ]
        }
        (root / "claims.json").write_text(json.dumps(claims), encoding="utf-8")
        report = run_gates(root, persist=False, allow_check=True)
        checks = report["gates"][0]["claims"]
        self.assertTrue(all(item["passed"] for item in checks), report)
        # Teardown is guaranteed; a second run can reclaim the same port.
        report2 = run_gates(root, persist=False, allow_check=True)
        self.assertTrue(report2["passed"], report2)
        tmp.cleanup()
