#!/usr/bin/env python3
"""Protocol smoke-test adapter. It intentionally makes no repository changes."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    request = json.loads(Path(sys.argv[-1]).read_text(encoding="utf-8"))
    trace = Path(request["trace_path"])
    trace.parent.mkdir(parents=True, exist_ok=True)
    with trace.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "adapter.started", "data": {"name": "noop"}}) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

