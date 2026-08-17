#!/usr/bin/env python3
"""Copy this file to build an adapter for a coding-agent harness."""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def emit(request: dict[str, Any], event_type: str, data: dict[str, Any]) -> None:
    event = {
        "type": event_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "data": data,
    }
    trace = Path(request["trace_path"])
    trace.parent.mkdir(parents=True, exist_ok=True)
    with trace.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def run_harness(request: dict[str, Any]) -> int:
    """Replace this body with one harness invocation.

    The harness should read request["prompt_path"], operate only inside
    request["workspace"], and record model/tool/mutation events with emit().
    Return zero when the harness believes it has finished; the protected
    verifier, not this return value, decides benchmark success.
    """
    emit(request, "adapter.unimplemented", {"arm": request["arm"]})
    return 2


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: command_template.py REQUEST.json")
    request = json.loads(Path(sys.argv[-1]).read_text(encoding="utf-8"))
    return run_harness(request)


if __name__ == "__main__":
    raise SystemExit(main())
