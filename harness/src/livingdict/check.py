"""Pick and run the product's check. Used by RUN-TESTS.

Eval tasks keep `tests/test_*.py`, so they still run unittest. A JS/game/other
workspace uses npm test or npm run build when those scripts exist. An empty
studio has no runner: RUN-TESTS is a no-op pass so the six-word ABI stays.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def extra_bin_dirs() -> list[str]:
    dirs = [
        str(Path.home() / ".nix-profile" / "bin"),
        "/nix/var/nix/profiles/default/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        str(Path.home() / ".local" / "bin"),
    ]
    return [d for d in dirs if Path(d).is_dir()]


def extend_path(env: dict[str, str]) -> dict[str, str]:
    current = env.get("PATH", "")
    parts = extra_bin_dirs()
    for item in current.split(":"):
        if item and item not in parts:
            parts.append(item)
    out = dict(env)
    out["PATH"] = ":".join(parts)
    return out


def find_npm() -> str:
    env = extend_path(os.environ.copy())
    found = shutil.which("npm", path=env.get("PATH"))
    return found or "npm"


def python_test_files(workspace: Path) -> list[Path]:
    tests = workspace / "tests"
    if not tests.is_dir():
        return []
    found: list[Path] = []
    for path in tests.rglob("*"):
        if not path.is_file() or path.suffix != ".py":
            continue
        if path.name.startswith("test_") or path.name.endswith("_test.py"):
            found.append(path)
    return found


def detect_check(workspace: Path) -> dict[str, Any]:
    workspace = Path(workspace)
    if python_test_files(workspace):
        return {
            "kind": "unittest",
            "argv": [sys.executable, "-m", "unittest", "discover", "-s", "tests"],
            "label": "python -m unittest discover -s tests",
            "install": False,
            "env": {"PYTHONDONTWRITEBYTECODE": "1"},
        }
    pkg = workspace / "package.json"
    if pkg.is_file():
        scripts: dict[str, Any] = {}
        try:
            blob = json.loads(pkg.read_text(encoding="utf-8"))
            if isinstance(blob, dict) and isinstance(blob.get("scripts"), dict):
                scripts = blob["scripts"]
        except (OSError, json.JSONDecodeError):
            scripts = {}
        npm = find_npm()
        if "test" in scripts:
            argv, label = [npm, "test"], "npm test"
        elif "build" in scripts:
            argv, label = [npm, "run", "build"], "npm run build"
        else:
            argv, label = [npm, "install"], "npm install"
        return {
            "kind": "npm",
            "argv": argv,
            "label": label,
            "install": label != "npm install" and not (workspace / "node_modules").is_dir(),
            "env": {},
        }
    return {"kind": "none", "argv": [], "label": "", "install": False, "env": {}}


def _run(argv: list[str], workspace: Path, timeout: float, env_extra: dict[str, str]) -> dict[str, Any]:
    env = extend_path(os.environ.copy())
    env.update(env_extra)
    try:
        proc = subprocess.run(
            argv,
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        out, err = exc.stdout or "", exc.stderr or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        return {
            "passed": False,
            "returncode": None,
            "timed_out": True,
            "stdout": out[-4000:],
            "stderr": err[-4000:],
        }
    except FileNotFoundError as exc:
        return {
            "passed": False,
            "returncode": None,
            "timed_out": False,
            "stdout": "",
            "stderr": str(exc),
        }
    return {
        "passed": proc.returncode == 0,
        "returncode": proc.returncode,
        "timed_out": False,
        "stdout": (proc.stdout or "")[-4000:],
        "stderr": (proc.stderr or "")[-4000:],
    }


def run_workspace_check(workspace: Path, timeout: float = 60.0) -> dict[str, Any]:
    spec = detect_check(Path(workspace))
    if spec["kind"] == "none":
        return {
            "passed": True,
            "returncode": 0,
            "timed_out": False,
            "skipped": True,
            "command": None,
            "stdout": "",
            "stderr": "no test or build command in this workspace",
        }
    leftover = float(timeout)
    if spec.get("install"):
        npm = spec["argv"][0]
        installed = _run([npm, "install"], workspace, leftover, spec.get("env") or {})
        if installed["timed_out"] or not installed["passed"]:
            installed["command"] = "npm install"
            installed["skipped"] = False
            return installed
        leftover = max(5.0, leftover / 2.0)
    result = _run(spec["argv"], workspace, leftover, spec.get("env") or {})
    result["command"] = spec["label"]
    result["skipped"] = False
    return result


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("usage: check.py WORKSPACE [TIMEOUT]", file=sys.stderr)
        return 2
    timeout = float(args[1]) if len(args) > 1 else 60.0
    json.dump(run_workspace_check(Path(args[0]), timeout), sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
