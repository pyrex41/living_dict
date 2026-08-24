from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from livingdict.promotion import evidence_for, warm_run_allowed
from livingdict.shared_space import SharedSpace


class PromotionTests(unittest.TestCase):
    def test_evidence_requires_claims_and_clean_execution(self) -> None:
        item = {"word": "PATCH", "sha256": "a" * 64, "episode": 2}
        report = {"gates": [{"name": "claims", "passed": True}]}
        self.assertTrue(evidence_for(item, report=report).eligible)
        self.assertFalse(evidence_for(item, report=report, trap="timeout").eligible)

    def test_warm_thresholds(self) -> None:
        ok, reasons = warm_run_allowed(
            success_delta_points=-2,
            token_reduction_fraction=.30,
            policy_violations_increased=False,
            negative_transfer=False,
        )
        self.assertTrue(ok)
        self.assertEqual(reasons, [])
        ok, reasons = warm_run_allowed(
            success_delta_points=-6,
            token_reduction_fraction=.30,
            policy_violations_increased=False,
            negative_transfer=False,
        )
        self.assertFalse(ok)
        self.assertIn("correctness loss exceeds threshold", reasons)


class SharedSpaceTests(unittest.TestCase):
    def test_take_is_single_consumer_and_complete(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "space.db"
            first = SharedSpace(path)
            second = SharedSpace(path)
            first.out({"kind": "obligation", "id": "o1"})
            claim = second.take({"kind": "obligation"}, owner="worker-1")
            self.assertIsNotNone(claim)
            self.assertIsNone(first.take({"kind": "obligation"}, owner="worker-2"))
            self.assertTrue(second.complete(claim or {}, owner="worker-1"))
            self.assertIsNone(first.rd({"kind": "obligation"}))
            first.close()
            second.close()


if __name__ == "__main__":
    unittest.main()
