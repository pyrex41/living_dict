"""Benchmark task adapter primitives for Harbor/SWE-bench style runners.

The adapter owns isolation and test invocation; arms remain interchangeable
and report through ``ArmResult``.  Dataset-specific adapters can implement
``prepare`` and ``verify`` without entering the core harness.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol, Sequence


@dataclass(frozen=True)
class BenchmarkTask:
    task_id: str
    prompt: str
    base_revision: str | None = None
    test_command: tuple[str, ...] = ()
    metadata: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class BenchmarkResult:
    task_id: str
    passed: bool
    exit_code: int | None
    timed_out: bool
    changed_files: tuple[str, ...] = ()
    failure: str | None = None


class BenchmarkAdapter(Protocol):
    name: str

    def prepare(self, task: BenchmarkTask, workspace: Path) -> None: ...

    def verify(self, task: BenchmarkTask, workspace: Path, *, timeout: float) -> BenchmarkResult: ...


def validate_task(task: BenchmarkTask) -> None:
    if not task.task_id.strip():
        raise ValueError("benchmark task_id is required")
    if not task.prompt.strip():
        raise ValueError("benchmark prompt is required")
    if any(not part or Path(part).is_absolute() for part in task.test_command):
        raise ValueError("test command must use non-empty relative-safe arguments")
