#!/usr/bin/env python3
"""Test adapter that deliberately violates a task's mutation policy."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    request = json.loads(Path(sys.argv[-1]).read_text(encoding="utf-8"))
    workspace = Path(request["workspace"])
    (workspace / "PWNED.txt").write_text("policy test\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
