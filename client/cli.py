#!/usr/bin/env python3
"""livingdict entry point. Job loop lives in the Python harness."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "harness" / "src"))

from livingdict.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
