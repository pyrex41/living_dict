from __future__ import annotations

import tomllib
from pathlib import Path

from .models import Task


def suite_root() -> Path:
    return Path(__file__).resolve().parents[1]


def tasks_root() -> Path:
    return suite_root() / "tasks"


def load_task(path: Path) -> Task:
    manifest = path / "task.toml"
    with manifest.open("rb") as handle:
        data = tomllib.load(handle)
    fault = data.get("fault", {})
    return Task(
        root=path,
        id=data["id"],
        family=data["family"],
        sequence=int(data["sequence"]),
        title=data["title"],
        difficulty=data.get("difficulty", "small"),
        mechanisms=tuple(data.get("mechanisms", [])),
        time_limit_seconds=int(data.get("time_limit_seconds", 180)),
        allowed_effects=tuple(data.get("allowed_effects", ["read", "write", "exec"])),
        allowed_globs=tuple(data.get("allowed_globs", ["**"])),
        forbidden_globs=tuple(data.get("forbidden_globs", [])),
        fault_event=fault.get("after_event"),
        graph=data.get("graph", {}),
    )


def discover_tasks(root: Path | None = None) -> list[Task]:
    base = root or tasks_root()
    found = [load_task(p.parent) for p in base.glob("*/task.toml")]
    return sorted(found, key=lambda task: (task.family, task.sequence, task.id))


def select_tasks(
    tasks: list[Task],
    ids: set[str] | None = None,
    families: set[str] | None = None,
    mechanisms: set[str] | None = None,
) -> list[Task]:
    selected = []
    for task in tasks:
        if ids and task.id not in ids:
            continue
        if families and task.family not in families:
            continue
        if mechanisms and not mechanisms.intersection(task.mechanisms):
            continue
        selected.append(task)
    return selected

