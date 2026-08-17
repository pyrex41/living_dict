from __future__ import annotations

import fnmatch
import hashlib
from pathlib import Path


def snapshot(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or ".git" in path.parts:
            continue
        rel = path.relative_to(root).as_posix()
        values[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def changed_files(before: dict[str, str], after: dict[str, str]) -> list[str]:
    keys = set(before) | set(after)
    return sorted(key for key in keys if before.get(key) != after.get(key))


def _matches(path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def violations(
    changed: list[str],
    allowed_globs: tuple[str, ...],
    forbidden_globs: tuple[str, ...],
) -> list[str]:
    problems: list[str] = []
    for path in changed:
        if _matches(path, forbidden_globs):
            problems.append(f"forbidden path changed: {path}")
        elif not _matches(path, allowed_globs):
            problems.append(f"path outside allowed change set: {path}")
    return problems

