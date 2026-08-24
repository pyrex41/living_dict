"""Common arm protocol for representation experiments.

Adapters return this record so compare reports apples-to-apples metrics while
keeping arm-specific transcripts and execution details intact.
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any, Mapping


ARM_NAMES = ("react", "json-plan", "python-plan")


@dataclass
class ArmResult:
    arm: str
    ok: bool
    exit: int = 0
    duration_ms: int = 0
    model_calls: int = 0
    tool_calls: int = 0
    input_tokens: int | None = None
    output_tokens: int | None = None
    changed_files: list[str] = field(default_factory=list)
    policy_violations: int = 0
    preflight_rejections: int = 0
    traps: int = 0
    judge: dict[str, Any] = field(default_factory=dict)
    error: str | None = None

    @classmethod
    def from_raw(cls, arm: str, raw: Mapping[str, Any]) -> "ArmResult":
        parsed = raw.get("parsed") or {}
        usage = parsed.get("usage") or {}
        return cls(
            arm=arm,
            ok=bool(raw.get("ok")),
            exit=int(raw.get("exit") or 0),
            duration_ms=int(raw.get("duration_ms") or 0),
            model_calls=int(parsed.get("model_calls") or parsed.get("turns") or 0),
            tool_calls=int(parsed.get("tool_calls") or 0),
            input_tokens=usage.get("input_tokens") if isinstance(usage, dict) else None,
            output_tokens=usage.get("output_tokens") if isinstance(usage, dict) else None,
            changed_files=list(raw.get("changed_files") or []),
            policy_violations=int(raw.get("policy_violations") or 0),
            preflight_rejections=int(raw.get("preflight_rejections") or 0),
            traps=int(raw.get("traps") or 0),
            judge=dict(raw.get("judge") or {}),
            error=raw.get("error"),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def validate_arm_name(name: str) -> str:
    value = str(name).strip().lower()
    if value not in ARM_NAMES:
        raise ValueError(f"unsupported experimental arm: {name}")
    return value
