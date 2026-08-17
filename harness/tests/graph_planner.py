#!/usr/bin/env python3
"""Emit a canned envelope. Default is the graph-01 fixture."""

from __future__ import annotations

import os
import sys
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "graph-01.envelope.json"


def main() -> int:
    sys.stdin.read()
    override = os.environ.get("LIVINGDICT_TEST_ENVELOPE")
    path = Path(override) if override else FIXTURE
    text = path.read_text(encoding="utf-8")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
