from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

from livingdict.policy_eval import evaluate


REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "client" / "cli.py"
POLICY = REPO / "bin" / "livingdict-policy"


def _env() -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("RHO_PROTOCOL_GRANT_")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


class PolicyEvaluateTests(unittest.TestCase):
    def test_execute_without_explicit_globs_is_denied(self) -> None:
        """Deny-by-default: stock scud refs alone carry no authority."""
        decision = evaluate(
            {
                "run_id": "r1",
                "action": "execute",
                "resource": "write-fizzbuzz",
                "attributes": {
                    "goal_id": "demo",
                    "capability_ref": "livingdict",
                    "policy_ref": "critic",
                    "grant_ref": "scud-local",
                },
            }
        )
        self.assertFalse(decision["allowed"])
        self.assertIn("allowed_globs is required", decision["reason"])
        self.assertEqual(decision["constraints"], {})

    def test_unrecognized_glob_attribute_name_is_denied_not_widened(self) -> None:
        """A caller using the wrong key must not get a blanket `**` allow."""
        decision = evaluate(
            {
                "run_id": "r1",
                "action": "execute",
                "resource": "ob-2",
                "attributes": {
                    "goal_id": "g",
                    "write_globs": "../outside/**",
                    "effects": "read,write",
                },
            }
        )
        self.assertFalse(decision["allowed"])
        self.assertIn("allowed_globs is required", decision["reason"])

    def test_execute_without_effects_is_denied(self) -> None:
        decision = evaluate(
            {
                "run_id": "r1",
                "action": "execute",
                "resource": "ob-3",
                "attributes": {"goal_id": "g", "allowed_globs": "src/**"},
            }
        )
        self.assertFalse(decision["allowed"])
        self.assertIn("allowed_effects is required", decision["reason"])

    def test_execute_denies_disallowed_effect_with_critic_reason(self) -> None:
        decision = evaluate(
            {
                "run_id": "r1",
                "action": "execute",
                "resource": "ob-1",
                "attributes": {
                    "goal_id": "g",
                    "program": 'S" body" S" x.py" WRITE-FILE',
                    "allowed_effects": "read",
                    "allowed_globs": "**",
                },
            }
        )
        self.assertFalse(decision["allowed"])
        self.assertIn("effects not allowed", decision["reason"])
        self.assertEqual(decision["constraints"], {})

    def test_execute_denies_write_outside_globs(self) -> None:
        decision = evaluate(
            {
                "run_id": "r1",
                "action": "execute",
                "resource": "ob-1",
                "attributes": {
                    "program": 'S" pwned" S" secrets.env" WRITE-FILE',
                    "allowed_effects": "read,write,exec",
                    "allowed_globs": "app/config.py",
                    "forbidden_globs": "secrets.env",
                },
            }
        )
        self.assertFalse(decision["allowed"])
        self.assertTrue(
            "forbidden" in decision["reason"] or "outside allowed" in decision["reason"],
            decision["reason"],
        )

    def test_non_execute_is_denied(self) -> None:
        decision = evaluate(
            {
                "run_id": "r1",
                "action": "read",
                "resource": "file",
                "attributes": {"goal_id": "g"},
            }
        )
        self.assertFalse(decision["allowed"])
        self.assertIn("unsupported action", decision["reason"])

    def test_cli_and_bin_write_evaluator_shape(self) -> None:
        payload = json.dumps(
            {
                "run_id": "r1",
                "action": "execute",
                "resource": "ob-1",
                "attributes": {
                    "goal_id": "g",
                    "capability_ref": "livingdict",
                    "policy_ref": "critic",
                    "grant_ref": "scud-local",
                    "program": "RECEIPT",
                    "allowed_effects": "read,write,exec",
                    "allowed_globs": "**",
                },
            }
        )
        for argv in (
            [sys.executable, str(CLI), "policy"],
            [sys.executable, str(POLICY)],
        ):
            proc = subprocess.run(
                argv,
                input=payload,
                capture_output=True,
                text=True,
                check=False,
                env=_env(),
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            body = json.loads(proc.stdout)
            self.assertEqual(set(body), {"allowed", "reason", "constraints"})
            self.assertTrue(body["allowed"])
            self.assertEqual(body["reason"], "accepted")


if __name__ == "__main__":
    unittest.main()
