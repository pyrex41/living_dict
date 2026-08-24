"""Evidence gates for reusable dictionary words.

Promotion is deliberately separate from writing a colon-word file.  A word
may be present as a candidate, but it is reusable evidence only after the
episode that produced it has discharged its claims and completed cleanly.
"""

from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any

from .kernel import claims_discharged


@dataclass(frozen=True)
class PromotionEvidence:
    word: str
    sha256: str
    episode: int
    critic_accepted: bool
    execution_clean: bool
    claims_discharged: bool
    policy_violations: int = 0
    trap: str | None = None
    replay_ok: bool = True

    @property
    def eligible(self) -> bool:
        return (
            bool(self.word)
            and bool(self.sha256)
            and self.critic_accepted
            and self.execution_clean
            and self.claims_discharged
            and self.policy_violations == 0
            and not self.trap
            and self.replay_ok
        )

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["eligible"] = self.eligible
        return payload


def evidence_for(
    item: dict[str, Any],
    *,
    report: dict[str, Any] | None,
    critic_accepted: bool = True,
    trap: str | None = None,
    replay_ok: bool = True,
) -> PromotionEvidence:
    """Build a deterministic evidence record from one executed episode."""
    report = report if isinstance(report, dict) else {}
    violations = report.get("policy_violations", 0)
    try:
        violations = int(violations)
    except (TypeError, ValueError):
        violations = 1
    return PromotionEvidence(
        word=str(item.get("word") or ""),
        sha256=str(item.get("sha256") or ""),
        episode=int(item.get("episode") or 0),
        critic_accepted=bool(critic_accepted),
        execution_clean=trap is None,
        claims_discharged=claims_discharged(report),
        policy_violations=violations,
        trap=trap,
        replay_ok=bool(replay_ok),
    )


def warm_run_allowed(
    *,
    success_delta_points: float,
    token_reduction_fraction: float,
    policy_violations_increased: bool,
    negative_transfer: bool,
    max_correctness_loss_points: float = 5.0,
    min_cost_reduction_fraction: float = 0.25,
) -> tuple[bool, list[str]]:
    """Apply the preregistered warm-dictionary go/no-go thresholds."""
    reasons: list[str] = []
    if success_delta_points < -max_correctness_loss_points:
        reasons.append("correctness loss exceeds threshold")
    if token_reduction_fraction < min_cost_reduction_fraction:
        reasons.append("cost reduction is below threshold")
    if policy_violations_increased:
        reasons.append("policy violations increased")
    if negative_transfer:
        reasons.append("negative transfer detected")
    return not reasons, reasons
