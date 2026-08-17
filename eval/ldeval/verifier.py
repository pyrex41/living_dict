from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from .models import Task, Verification


def verify(task: Task, workspace: Path, timeout: int = 60) -> Verification:
    try:
        proc = subprocess.run(
            [sys.executable, str(task.verifier_path), str(workspace)],
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return Verification(checks=[{"name": "verifier_timeout", "passed": False, "detail": "verifier timed out"}])
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        payload = {
            "checks": [{
                "name": "verifier_protocol",
                "passed": False,
                "detail": f"exit={proc.returncode}; stdout={proc.stdout[-500:]}; stderr={proc.stderr[-500:]}",
            }]
        }
    checks = payload.get("checks", [])
    if proc.returncode != 0 and all(item.get("passed") for item in checks):
        checks.append({"name": "verifier_exit", "passed": False, "detail": f"exit code {proc.returncode}"})
    return Verification(checks=checks, raw=payload)

