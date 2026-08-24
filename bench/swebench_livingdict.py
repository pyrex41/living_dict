#!/usr/bin/env python3
"""Generate SWE-bench predictions with Living Dictionary.

This script deliberately only generates patches.  Run the official SWE-bench
evaluator separately so its repository tests remain the sole score authority.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def run(argv: list[str], *, cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=cwd, text=True, capture_output=True, timeout=timeout)


def task_prompt(row: dict[str, object]) -> str:
    statement = str(row.get("problem_statement") or "").strip()
    hints = str(row.get("hints_text") or "").strip()
    suffix = f"\n\nAdditional hints:\n{hints}" if hints else ""
    return (
        "Resolve this GitHub issue in the checked-out repository. Implement the "
        "smallest correct fix, run relevant tests, and leave the changes on disk.\n\n"
        + statement
        + suffix
    )


def patch_for_workspace(workspace: Path, base_commit: str) -> tuple[str, list[str]]:
    """Return tracked plus newly-created product files as one git patch."""
    tracked = subprocess.run(
        ["git", "diff", "--binary", base_commit],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=300,
        check=False,
    )
    names = subprocess.run(
        ["git", "status", "--short", "--untracked-files=all"],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=300,
        check=False,
    )
    changed = []
    for line in names.stdout.splitlines():
        if len(line) < 4:
            continue
        rel = line[3:].strip()
        if rel == "claims.json" or rel.startswith(".livingdict-run/"):
            continue
        changed.append(rel)

    chunks = [tracked.stdout]
    for rel in changed:
        added = subprocess.run(
            ["git", "diff", "--no-index", "--binary", "/dev/null", rel],
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=300,
            check=False,
        )
        chunks.append(added.stdout)
    return "".join(chunks), changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default="SWE-bench/SWE-bench_Verified")
    parser.add_argument("--split", default="test")
    parser.add_argument("--instance", action="append", default=[])
    parser.add_argument("--limit", type=int, default=1)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path("predictions.livingdict.jsonl"))
    parser.add_argument("--max-turns", type=int, default=16)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()

    try:
        from datasets import load_dataset
    except ImportError as exc:
        raise SystemExit("Install datasets first (for example: uv run --with datasets ...)") from exc

    rows = load_dataset(args.dataset, split=args.split)
    wanted = set(args.instance)
    selected = [row for row in rows if not wanted or row["instance_id"] in wanted]
    selected = selected[: args.limit]
    if not selected:
        raise SystemExit("no matching SWE-bench instances")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as output:
        for row in selected:
            instance_id = str(row["instance_id"])
            repo = str(row["repo"])
            base_commit = str(row["base_commit"])
            with tempfile.TemporaryDirectory(prefix=f"swebench-{instance_id}-") as temp:
                workspace = Path(temp) / "repo"
                clone = run(["git", "clone", "--quiet", f"https://github.com/{repo}.git", str(workspace)], cwd=Path.cwd(), timeout=600)
                if clone.returncode:
                    raise RuntimeError(clone.stderr[-4000:])
                checkout = run(["git", "checkout", "--quiet", base_commit], cwd=workspace, timeout=300)
                if checkout.returncode:
                    raise RuntimeError(checkout.stderr[-4000:])

                env = os.environ.copy()
                env["PYTHONPATH"] = str(args.repo_root / "harness" / "src")
                command = [
                    str(args.repo_root / "bin" / "livingdict"),
                    "-p",
                    task_prompt(dict(row)),
                    "--cwd",
                    str(workspace),
                    "--max-turns",
                    str(args.max_turns),
                ]
                completed = subprocess.run(
                    command,
                    cwd=workspace,
                    env=env,
                    text=True,
                    capture_output=True,
                    timeout=args.timeout,
                )
                patch, changed_files = patch_for_workspace(workspace, base_commit)
                output.write(
                    json.dumps(
                        {
                            "instance_id": instance_id,
                            "model_name_or_path": "livingdict",
                            "model_patch": patch,
                            "changed_files": changed_files,
                            "livingdict_exit": completed.returncode,
                            "livingdict_stdout": completed.stdout[-8000:],
                            "livingdict_stderr": completed.stderr[-4000:],
                        }
                    )
                    + "\n"
                )
                output.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
