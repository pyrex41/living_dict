from __future__ import annotations

import unittest
from pathlib import Path

from livingdict import claims_discharged, envelope_from_forth, ensure_receipt, format_turn, load_envelope


class EnvelopeTests(unittest.TestCase):
    def test_wraps_forth(self) -> None:
        env = envelope_from_forth("3 4 +")
        self.assertEqual(env["language"], "forth")
        self.assertEqual(env["program"], "3 4 +")
        self.assertEqual(env["artifacts"], {})

    def test_ensure_receipt(self) -> None:
        self.assertEqual(ensure_receipt("3 4 +"), "3 4 + RECEIPT")
        self.assertEqual(ensure_receipt("3 4 + RECEIPT"), "3 4 + RECEIPT")

    def test_load_canned(self) -> None:
        path = Path(__file__).resolve().parents[1] / "openresty" / "examples" / "config-01.envelope.json"
        env = load_envelope(path)
        self.assertIn("WRITE-FILE", env["program"])
        self.assertIn("app/config.py", env["artifacts"])

    def test_format_reject_is_200_with_artifacts_and_errors(self) -> None:
        text = format_turn(
            200,
            {
                "ok": False,
                "critic": "reject",
                "errors": ["stack underflow at WRITE-FILE"],
                "plan": {
                    "artifacts": {"fizzbuzz.py": "def fizzbuzz(n): ...\n"},
                    "program": 'S" fizzbuzz.py" WRITE-FILE',
                    "rationale": "land the product",
                },
            },
        )
        self.assertIn("REJECT", text)
        self.assertIn("http 200", text)
        self.assertIn("stack underflow at WRITE-FILE", text)
        self.assertIn("fizzbuzz.py", text)

    def test_reject_is_not_discharge(self) -> None:
        self.assertFalse(claims_discharged(None))
        self.assertFalse(claims_discharged({"gates": [{"name": "sources", "passed": True}]}))
        self.assertTrue(claims_discharged({"gates": [{"name": "claims", "passed": True}]}))


if __name__ == "__main__":
    unittest.main()
