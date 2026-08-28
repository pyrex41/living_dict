from __future__ import annotations

import unittest

from livingdict.envelope import GraphNode, PlanEnvelope, kahn_order
from livingdict.kernel import (
    ARTIFACTS_APPLIED,
    BUDGET_CONSUMED,
    CRITIC_ACCEPTED,
    CRITIC_REJECTED,
    DECISION_BLOCKED,
    DECISION_HALT_CAP,
    DECISION_PLAN,
    DECISION_SUCCESS,
    claims_discharged,
    DICTIONARY_PROMOTED,
    EPISODE_BLOCKED_DUPLICATE,
    EPISODE_PLANNED,
    GATES_MEASURED,
    Event,
    KernelError,
    empty_state,
    fingerprint,
    reconcile,
    reduce,
    replay,
)


def _env(program: str = 'S" a" WRITE-FILE', rationale: str = "one", claims_id: str = "fn") -> PlanEnvelope:
    claims = '{"claims":[{"id":"%s","kind":"file","path":"a"}]}' % claims_id
    return PlanEnvelope(
        language="forth",
        program=program,
        artifacts={"a": "x\n", "claims.json": claims},
        rationale=rationale,
    )


class SequenceTests(unittest.TestCase):
    def test_sequence_zero_is_assigned_and_monotonic(self) -> None:
        state = empty_state()
        state = reduce(state, Event(kind=BUDGET_CONSUMED, payload={"steps": 1}))
        self.assertEqual(state.revision, 1)
        self.assertEqual(state.events[0].sequence, 1)
        state = reduce(state, Event(kind=BUDGET_CONSUMED, sequence=2, payload={"steps": 1}))
        self.assertEqual(state.revision, 2)
        self.assertEqual(state.used, 2)

    def test_out_of_sequence_rejected_without_mutation(self) -> None:
        state = reduce(empty_state(), Event(kind=BUDGET_CONSUMED, payload={"steps": 1}))
        with self.assertRaises(KernelError) as caught:
            reduce(state, Event(kind=BUDGET_CONSUMED, sequence=4, payload={"steps": 1}))
        self.assertIn("sequence", str(caught.exception))
        self.assertEqual(state.revision, 1)
        self.assertEqual(state.used, 1)

    def test_duplicate_event_id_rejected(self) -> None:
        state = reduce(empty_state(), Event(kind=BUDGET_CONSUMED, id="same", payload={"steps": 1}))
        with self.assertRaises(KernelError) as caught:
            reduce(state, Event(kind=BUDGET_CONSUMED, id="same", payload={"steps": 1}))
        self.assertIn("duplicate event id", str(caught.exception))
        self.assertEqual(state.revision, 1)

    def test_empty_event_ids_may_repeat(self) -> None:
        state = reduce(empty_state(), Event(kind=BUDGET_CONSUMED, payload={"steps": 1}))
        state = reduce(state, Event(kind=BUDGET_CONSUMED, payload={"steps": 1}))
        self.assertEqual(state.used, 2)

    def test_unknown_kind_rejected(self) -> None:
        with self.assertRaises(KernelError):
            reduce(empty_state(), Event(kind="episode.invented"))

    def test_replay_folds_from_empty(self) -> None:
        events = [
            Event(kind=EPISODE_PLANNED, payload={"fingerprint": "aa"}),
            Event(kind=CRITIC_ACCEPTED),
            Event(kind=GATES_MEASURED, payload={"report": {"gates": [{"name": "claims", "passed": True}]}}),
            Event(kind=BUDGET_CONSUMED, payload={"steps": 1}),
        ]
        state = replay(events)
        self.assertEqual(state.revision, 4)
        self.assertEqual([event.sequence for event in state.events], [1, 2, 3, 4])
        self.assertEqual(state.used, 1)
        self.assertEqual(state.last_critic, "accepted")


class FingerprintTests(unittest.TestCase):
    def test_excludes_rationale_and_status(self) -> None:
        left = _env(rationale="alpha")
        right = _env(rationale="omega")
        self.assertEqual(fingerprint(left), fingerprint(right))
        as_dict = left.to_dict()
        as_dict["rationale"] = "changed again"
        as_dict["status"] = "running"
        as_dict["continue"] = True
        self.assertEqual(fingerprint(left), fingerprint(as_dict))

    def test_program_tokens_and_keys_and_claim_ids_matter(self) -> None:
        base = fingerprint(_env())
        self.assertNotEqual(base, fingerprint(_env(program='S" b" WRITE-FILE')))
        other_keys = PlanEnvelope(
            language="forth",
            program='S" a" WRITE-FILE',
            artifacts={"b": "x\n", "claims.json": '{"claims":[{"id":"fn"}]}'},
            rationale="one",
        )
        self.assertNotEqual(base, fingerprint(other_keys))
        self.assertNotEqual(base, fingerprint(_env(claims_id="other")))

    def test_artifact_contents_change_fingerprint(self) -> None:
        base = fingerprint(_env())
        changed = _env()
        changed.artifacts["a"] = "different body"
        self.assertNotEqual(base, fingerprint(changed))

    def test_failed_gates_persist_structured_failure(self) -> None:
        report = {"passed": False, "stderr": "failed", "gates": [{"name": "claims", "claims": [{"id": "run", "kind": "check", "command": "./app", "output": "bad", "passed": False}]}]}
        state = reduce(empty_state(), Event(kind=GATES_MEASURED, payload={"report": report}))
        self.assertEqual(state.last_failure["failed_claims"][0]["id"], "run")
        self.assertEqual(len(state.attempt_history), 1)

    def test_nodes_change_fingerprint_without_affecting_absent(self) -> None:
        base = _env()
        self.assertEqual(fingerprint(base), fingerprint(base.to_dict()))
        with_nodes = PlanEnvelope(
            language="forth",
            program=base.program,
            artifacts=base.artifacts,
            rationale=base.rationale,
            nodes=[
                GraphNode(id="ingest", writes=["a"], depends_on=[], program='S" a" WRITE-FILE'),
            ],
        )
        self.assertNotEqual(fingerprint(base), fingerprint(with_nodes))
        tweaked = PlanEnvelope(
            language="forth",
            program=base.program,
            artifacts=base.artifacts,
            rationale="other wording",
            nodes=[
                GraphNode(id="ingest", writes=["a"], depends_on=[], program="RECEIPT"),
            ],
        )
        self.assertNotEqual(fingerprint(with_nodes), fingerprint(tweaked))

    def test_kahn_lexicographic_tiebreak(self) -> None:
        nodes = [
            GraphNode(id="scale", writes=["s"], depends_on=[]),
            GraphNode(id="offset", writes=["o"], depends_on=[]),
            GraphNode(id="ingest", writes=["i"], depends_on=[]),
            GraphNode(id="registry", writes=["r"], depends_on=["ingest", "scale", "offset"]),
            GraphNode(id="verify", writes=[], depends_on=["registry"]),
        ]
        ordered, leftover = kahn_order(nodes)
        self.assertEqual(leftover, [])
        self.assertEqual([node.id for node in ordered], ["ingest", "offset", "scale", "registry", "verify"])


class ReconcileTests(unittest.TestCase):
    def test_progress_failure_is_not_success(self) -> None:
        report = {
            "gates": [
                {"name": "claims", "passed": True, "skipped": False},
                {"name": "progress", "passed": False, "skipped": False},
            ]
        }
        self.assertFalse(claims_discharged(report))

    def test_contract_mutation_is_not_success(self) -> None:
        report = {"gates": [
            {"name": "claims", "passed": True, "skipped": False},
            {"name": "contract", "passed": False, "skipped": False},
        ]}
        self.assertFalse(claims_discharged(report))

    def test_empty_state_plans(self) -> None:
        decision = reconcile(empty_state(), 8)
        self.assertEqual(decision.kind, DECISION_PLAN)

    def test_success_beats_cap(self) -> None:
        state = replay(
            [
                Event(
                    kind=GATES_MEASURED,
                    payload={"report": {"passed": True, "gates": [{"name": "claims", "passed": True}]}},
                ),
                Event(kind=BUDGET_CONSUMED, payload={"steps": 3}),
            ]
        )
        decision = reconcile(state, 3)
        self.assertEqual(decision.kind, DECISION_SUCCESS)

    def test_structural_green_is_not_success(self) -> None:
        state = replay(
            [
                Event(
                    kind=GATES_MEASURED,
                    payload={
                        "report": {
                            "passed": True,
                            "gates": [
                                {"name": "sources", "passed": True},
                                {"name": "build", "passed": True},
                            ],
                        }
                    },
                ),
                Event(kind=BUDGET_CONSUMED, payload={"steps": 3}),
            ]
        )
        decision = reconcile(state, 3)
        self.assertEqual(decision.kind, DECISION_HALT_CAP)
        self.assertNotEqual(decision.kind, DECISION_SUCCESS)

    def test_two_consecutive_duplicates_block(self) -> None:
        fp = fingerprint(_env())
        state = empty_state()
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": fp}))
        self.assertTrue(state.pending_execute)
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": fp}))
        self.assertFalse(state.pending_execute)
        state = reduce(state, Event(kind=EPISODE_BLOCKED_DUPLICATE, payload={"fingerprint": fp}))
        self.assertEqual(reconcile(state, 8).kind, DECISION_PLAN)
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": fp}))
        state = reduce(state, Event(kind=EPISODE_BLOCKED_DUPLICATE, payload={"fingerprint": fp}))
        self.assertEqual(reconcile(state, 8).kind, DECISION_BLOCKED)

    def test_unique_plan_resets_duplicate_streak(self) -> None:
        first = fingerprint(_env(program="RECEIPT"))
        second = fingerprint(_env(program="RUN-GATES RECEIPT"))
        state = empty_state()
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": first}))
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": first}))
        state = reduce(state, Event(kind=EPISODE_BLOCKED_DUPLICATE, payload={"fingerprint": first}))
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": second}))
        self.assertEqual(state.consecutive_duplicates, 0)
        self.assertTrue(state.pending_execute)
        self.assertEqual(reconcile(state, 8).kind, DECISION_PLAN)

    def test_same_plan_after_workspace_change_is_retryable(self) -> None:
        fp = fingerprint(_env())
        state = empty_state()
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": fp, "dedupe_key": "a"}))
        state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": fp, "dedupe_key": "b"}))
        self.assertTrue(state.pending_execute)
        self.assertEqual(state.consecutive_duplicates, 0)

    def test_cap_is_halt_never_success(self) -> None:
        state = reduce(empty_state(), Event(kind=BUDGET_CONSUMED, payload={"steps": 2}))
        decision = reconcile(state, 2)
        self.assertEqual(decision.kind, DECISION_HALT_CAP)
        self.assertEqual(decision.reason, "cap reached")

    def test_zero_cap_is_unlimited(self) -> None:
        state = reduce(empty_state(), Event(kind=BUDGET_CONSUMED, payload={"steps": 99}))
        self.assertEqual(reconcile(state, 0).kind, DECISION_PLAN)

    def test_priority_blocked_before_halt_when_not_discharged(self) -> None:
        fp = fingerprint(_env())
        state = empty_state()
        for _ in range(2):
            state = reduce(state, Event(kind=EPISODE_PLANNED, payload={"fingerprint": fp}))
            state = reduce(state, Event(kind=EPISODE_BLOCKED_DUPLICATE, payload={"fingerprint": fp}))
        state = reduce(state, Event(kind=BUDGET_CONSUMED, payload={"steps": 4}))
        self.assertEqual(reconcile(state, 4).kind, DECISION_BLOCKED)

    def test_reject_does_not_discharge(self) -> None:
        state = replay(
            [
                Event(kind=CRITIC_REJECTED, payload={"errors": ["stack underflow at WRITE-FILE"]}),
                Event(kind=BUDGET_CONSUMED, payload={"steps": 1}),
            ]
        )
        self.assertEqual(state.last_errors, ("stack underflow at WRITE-FILE",))
        self.assertEqual(reconcile(state, 8).kind, DECISION_PLAN)
        self.assertEqual(state.last_critic, "rejected")

    def test_artifacts_applied_records_keys(self) -> None:
        state = reduce(
            empty_state(),
            Event(kind=ARTIFACTS_APPLIED, payload={"keys": ["claims.json", "fizzbuzz.py"]}),
        )
        self.assertEqual(state.last_artifact_keys, ("claims.json", "fizzbuzz.py"))

    def test_dictionary_promoted_is_recorded_without_changing_reconcile(self) -> None:
        prior = reconcile(empty_state(), 8)
        state = reduce(
            empty_state(),
            Event(kind=DICTIONARY_PROMOTED, payload={"episode": 1, "sha256": "ab", "word": "INSTALL"}),
        )
        self.assertEqual(state.revision, 1)
        self.assertEqual(state.events[0].kind, DICTIONARY_PROMOTED)
        self.assertEqual(reconcile(state, 8).kind, prior.kind)


if __name__ == "__main__":
    unittest.main()
