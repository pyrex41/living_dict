"""Workspace path and change-policy helpers.

Glob matching matches `eval/ldeval/policy.py` so a host denial and a runner
violation agree. The runner remains authoritative after the process exits;
this module is what stops the mutation from happening in the first place.
"""

from __future__ import annotations

import fnmatch
import hashlib
from pathlib import Path


class PathPolicy:
    def __init__(
        self,
        workspace: Path,
        allowed_globs: tuple[str, ...] | list[str],
        forbidden_globs: tuple[str, ...] | list[str],
    ) -> None:
        self.workspace = workspace.resolve()
        self.allowed_globs = tuple(allowed_globs)
        self.forbidden_globs = tuple(forbidden_globs)

    def relative(self, path: str | Path) -> str:
        """Return a posix path inside the workspace, or raise ValueError."""
        raw = Path(path)
        if raw.is_absolute():
            resolved = raw.resolve()
        else:
            resolved = (self.workspace / raw).resolve()
        try:
            rel = resolved.relative_to(self.workspace)
        except ValueError as exc:
            raise ValueError(f"path escapes workspace: {path}") from exc
        if rel.as_posix() == ".":
            return ""
        return rel.as_posix()

    def resolve(self, path: str | Path) -> Path:
        rel = self.relative(path)
        return self.workspace if rel == "" else self.workspace / rel

    def write_allowed(self, rel: str) -> str | None:
        """Return a denial reason, or None if the write is in policy."""
        if _matches(rel, self.forbidden_globs):
            return f"forbidden path: {rel}"
        if not _matches(rel, self.allowed_globs):
            return f"path outside allowed change set: {rel}"
        return None


_SKIP_DIR_NAMES = {
    ".git",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "node_modules",
    "dist",
    "build",
    ".vite",
    ".livingdict-run",
    ".sb",
}


def snapshot(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    root = root.resolve()
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in _SKIP_DIR_NAMES for part in path.parts):
            continue
        if path.suffix in {".pyc", ".pyo"}:
            continue
        rel = path.relative_to(root).as_posix()
        values[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def changed_files(before: dict[str, str], after: dict[str, str]) -> list[str]:
    keys = set(before) | set(after)
    return sorted(key for key in keys if before.get(key) != after.get(key))


def workspace_digest(files: dict[str, str]) -> str:
    hasher = hashlib.sha256()
    for rel, digest in sorted(files.items()):
        hasher.update(rel.encode("utf-8"))
        hasher.update(b"\0")
        hasher.update(digest.encode("ascii"))
        hasher.update(b"\n")
    return hasher.hexdigest()


def _matches(path: str, patterns: tuple[str, ...]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)
