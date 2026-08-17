#!/usr/bin/env python3
"""Test adapter that survives the configured config-05 crash boundary."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path


SOLUTION = '''\
DEFAULTS = {"structured_logging": False, "retries": 2}
ALIASES = {"log_json": "structured_logging"}

def normalize(user):
    result = DEFAULTS.copy()
    has_new = "structured_logging" in user
    for key, value in user.items():
        if key == "log_json" and has_new:
            continue
        target = ALIASES.get(key, key)
        if target not in result:
            raise KeyError(key)
        result[target] = value
    return result
'''


def emit(trace: Path, event_type: str, data: dict) -> None:
    with trace.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": event_type, "data": data}) + "\n")


def main() -> int:
    request = json.loads(Path(sys.argv[-1]).read_text(encoding="utf-8"))
    if request["task"]["id"] != "config-05":
        return 2
    workspace = Path(request["workspace"])
    trace = Path(request["trace_path"])
    if request["resume"]:
        emit(trace, "adapter.resume.complete", {"idempotent": True})
        return 0
    (workspace / "app/config.py").write_text(SOLUTION, encoding="utf-8")
    emit(trace, "mutation.applied", {"path": "app/config.py"})
    time.sleep(5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
