"""Host-owned job helpers. Product trees do not get GOAL.md / PROGRESS.md."""

from __future__ import annotations

import re
from pathlib import Path


def ensure_job_files(workspace: Path, goal: str, episode: int = 1) -> None:
    """Ensure the workspace exists. Job markdown is not written here."""
    del goal, episode
    Path(workspace).mkdir(parents=True, exist_ok=True)


def imply_artifact_writes(program: str, artifacts: dict | None) -> str:
    """S\" path\" WRITE-FILE of an artifact key becomes the USE-ARTIFACT zipper.

    The envelope already has the bytes. The model emits the write it was
    trained to emit. The host owns the stack dance.
    """
    keys = set(artifacts or {})
    if not keys or not program:
        return program
    lines: list[str] = []
    for raw in program.splitlines(keepends=True):
        nl = "\n" if raw.endswith("\n") else ""
        core = raw[:-1] if nl else raw
        match = re.match(r'\s*S"\s*([^"]+)"\s+WRITE-FILE\s*$', core, re.IGNORECASE)
        if match and match.group(1) in keys and "USE-ARTIFACT" not in core.upper():
            path = match.group(1)
            lines.append(f'S" {path}" USE-ARTIFACT S" {path}" WRITE-FILE{nl}')
            continue
        lines.append(raw)
    return "".join(lines)


def ensure_run_gates(program: str) -> str:
    text = (program or "").rstrip()
    words = text.upper().split()
    if "RUN-GATES" in words or "RUN-TESTS" in words:
        if "RECEIPT" not in words:
            return text + " RECEIPT"
        return text
    if re.search(r"(?i)\bRECEIPT\b", text):
        return re.sub(r"(?i)\bRECEIPT\b", "RUN-GATES RECEIPT", text, count=1)
    return text + "\nRUN-GATES RECEIPT"
