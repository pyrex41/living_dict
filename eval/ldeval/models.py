from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Task:
    root: Path
    id: str
    family: str
    sequence: int
    title: str
    difficulty: str
    mechanisms: tuple[str, ...]
    time_limit_seconds: int
    allowed_effects: tuple[str, ...]
    allowed_globs: tuple[str, ...]
    forbidden_globs: tuple[str, ...]
    fault_event: str | None = None
    graph: dict[str, Any] = field(default_factory=dict)

    @property
    def repo_dir(self) -> Path:
        return self.root / "repo"

    @property
    def prompt_path(self) -> Path:
        return self.root / "prompt.md"

    @property
    def verifier_path(self) -> Path:
        return self.root / "protected" / "verify.py"

    @property
    def oracle_files(self) -> Path:
        return self.root / "protected" / "oracle" / "files"


@dataclass
class Verification:
    checks: list[dict[str, Any]]
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def passed(self) -> bool:
        return bool(self.checks) and all(bool(item.get("passed")) for item in self.checks)


@dataclass
class Telemetry:
    model_calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    tool_calls: int = 0
    mutations: int = 0
    traps: int = 0
    replans: int = 0
    preflight_rejections: int = 0
    dictionary_retrievals: int = 0
    dictionary_reuses: int = 0
    dictionary_promotions: int = 0
    graph_nodes_started: int = 0
    graph_nodes_finished: int = 0
    crash_injected: bool = False
    resumed: bool = False


@dataclass
class RunResult:
    run_id: str
    task_id: str
    family: str
    sequence: int
    arm: str
    memory_mode: str
    success: bool
    verifier_passed: bool
    agent_exit_code: int
    timed_out: bool
    elapsed_seconds: float
    changed_files: list[str]
    policy_violations: list[str]
    verification: dict[str, Any]
    telemetry: dict[str, Any]
    workspace: str
    trace_path: str
    receipt_path: str

    def to_dict(self) -> dict[str, Any]:
        return self.__dict__.copy()

