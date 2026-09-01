#!/usr/bin/env python3
"""Same prompt, three harnesses: grok headless, pi headless, Living Dictionary.

Each arm gets an isolated copy of a seed workspace. Results land under
compare/runs/<stamp>/ with per-arm logs, a file diff, and summary.json.

The prompt string is identical. Isolation is the workspace (and, for Living
Dictionary, a private dictionary + run dir). Scoring is shared: file diffs
always; optional --claims is a hidden verifier applied to every arm.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from arms import ArmResult

REPO = Path(__file__).resolve().parents[1]
GATES_PY = REPO / "harness" / "src" / "livingdict" / "gates.py"
SKIP = {".git", "node_modules", "dist", "build", ".vite", ".sb", "__pycache__", ".pi", ".dictionary", ".livingdict-run"}
BIN_DIRS = [
    str(Path.home() / ".grok" / "bin"),
    str(Path.home() / ".local" / "bin"),
    str(Path.home() / ".nix-profile" / "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
]


def which(name: str) -> str | None:
    extra = os.pathsep.join(d for d in BIN_DIRS if Path(d).is_dir())
    path = os.environ.get("PATH", "")
    return shutil.which(name, path=f"{extra}{os.pathsep}{path}" if extra else path)


def snapshot(root: Path) -> dict[str, tuple[int, int]]:
    files: dict[str, tuple[int, int]] = {}
    if not root.is_dir():
        return files
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP for part in path.parts):
            continue
        if path.name.startswith("_compare") or path.name.startswith("_stdout") or path.name.startswith("_stderr"):
            continue
        rel = path.relative_to(root).as_posix()
        try:
            st = path.stat()
            files[rel] = (st.st_size, st.st_mtime_ns)
        except OSError:
            continue
    return files


def changed(before: dict[str, tuple[int, int]], after: dict[str, tuple[int, int]]) -> list[str]:
    keys = set(before) | set(after)
    return sorted(k for k in keys if before.get(k) != after.get(k))


def seed_copy(src: Path | None, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    if src is None or not src.is_dir():
        (dest / "README.md").write_text(
            "Isolated compare workspace. The prompt is the product.\n",
            encoding="utf-8",
        )
        return
    shutil.copytree(
        src,
        dest,
        dirs_exist_ok=True,
        ignore=shutil.ignore_patterns(
            "node_modules", "dist", ".git", ".sb", ".vite", ".dictionary", ".livingdict-run"
        ),
    )


def run_cmd(
    argv: list[str],
    *,
    cwd: Path,
    timeout: float,
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    started = time.perf_counter()
    merged = os.environ.copy()
    extra = [d for d in BIN_DIRS if Path(d).is_dir()]
    merged["PATH"] = os.pathsep.join(extra + [merged.get("PATH", "")])
    if env:
        merged.update(env)
    try:
        proc = subprocess.run(
            argv,
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
            env=merged,
        )
        return {
            "argv": argv,
            "exit": proc.returncode,
            "stdout": (proc.stdout or "")[-80_000:],
            "stderr": (proc.stderr or "")[-20_000:],
            "timed_out": False,
            "duration_ms": int((time.perf_counter() - started) * 1000),
        }
    except FileNotFoundError as exc:
        return {
            "argv": argv,
            "exit": 127,
            "stdout": "",
            "stderr": str(exc),
            "timed_out": False,
            "duration_ms": int((time.perf_counter() - started) * 1000),
        }
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        err = exc.stderr or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        return {
            "argv": argv,
            "exit": 124,
            "stdout": out[-80_000:],
            "stderr": (err or "timeout")[-20_000:],
            "timed_out": True,
            "duration_ms": int((time.perf_counter() - started) * 1000),
        }


def parse_grok_json(stdout: str) -> dict[str, Any]:
    raw = stdout.strip()
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        start, end = raw.find("{"), raw.rfind("}")
        if start < 0 or end <= start:
            return {"text": raw[-4000:]}
        try:
            value = json.loads(raw[start : end + 1])
        except json.JSONDecodeError:
            return {"text": raw[-4000:]}
    if not isinstance(value, dict):
        return {"text": raw[-4000:]}
    return {
        "text": value.get("text") or value.get("result") or "",
        "stop": value.get("stopReason") or value.get("stop_reason"),
        "turns": value.get("num_turns"),
        "usage": value.get("usage"),
        "model": (value.get("modelUsage") or {}),
        "session": value.get("sessionId") or value.get("session_id"),
    }


def _pi_text_parts(message: Any) -> list[str]:
    if not isinstance(message, dict):
        return []
    block = message.get("content")
    if isinstance(block, str):
        return [block]
    texts: list[str] = []
    if isinstance(block, list):
        for item in block:
            if isinstance(item, dict) and item.get("text"):
                texts.append(str(item["text"]))
            elif isinstance(item, str):
                texts.append(item)
    elif message.get("text"):
        texts.append(str(message["text"]))
    return texts


def parse_pi_json(stdout: str) -> dict[str, Any]:
    texts: list[str] = []
    last: dict[str, Any] = {}
    tool_calls = 0
    for line in stdout.splitlines():
        line = line.strip()
        if not line or line[0] not in "{[":
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        last = event
        kind = event.get("type") or event.get("event")
        if kind == "tool_execution_start":
            tool_calls += 1
        if kind in {"message_end", "turn_end"}:
            msg = event.get("message") or {}
            if isinstance(msg, dict) and msg.get("role") in {None, "assistant"}:
                texts.extend(_pi_text_parts(msg))
        elif kind == "agent_end" and not texts:
            for msg in event.get("messages") or []:
                if isinstance(msg, dict) and msg.get("role") == "assistant":
                    texts.extend(_pi_text_parts(msg))
        elif kind in {"text", "message"} and event.get("text"):
            texts.append(str(event["text"]))
        else:
            content = event.get("message") or event.get("result")
            if isinstance(content, str) and kind not in {"message_start", "message_update"}:
                texts.append(content)
    text = "".join(texts).strip() or (stdout.strip()[-4000:] if stdout.strip() else "")
    return {
        "text": text,
        "turns": tool_calls or None,
        "tool_calls": tool_calls,
        "last": {k: last.get(k) for k in list(last)[:12]},
    }


def grok_argv(prompt: str, cwd: Path, *, model: str, max_turns: int) -> list[str]:
    grok = which("grok") or "grok"
    argv = [
        grok,
        "-p",
        prompt,
        "--cwd",
        str(cwd),
        "--output-format",
        "json",
        "--always-approve",
        "--no-auto-update",
        "--max-turns",
        str(max_turns),
    ]
    if model:
        argv.extend(["-m", model])
    return argv


def pi_argv(prompt: str, *, model: str, provider: str) -> list[str]:
    pi = which("pi") or "pi"
    argv = [
        pi,
        "-p",
        "--no-session",
        "--no-approve",
        "--no-context-files",
        "--mode",
        "json",
    ]
    if provider:
        argv.extend(["--provider", provider])
    if model:
        argv.extend(["--model", model])
    argv.append(prompt)
    return argv


def run_grok(prompt: str, cwd: Path, *, model: str, max_turns: int, timeout: float) -> dict[str, Any]:
    raw = run_cmd(grok_argv(prompt, cwd, model=model, max_turns=max_turns), cwd=cwd, timeout=timeout)
    parsed = parse_grok_json(raw.get("stdout") or "")
    raw["parsed"] = parsed
    raw["ok"] = raw.get("exit") == 0 and not raw.get("timed_out")
    return raw


def run_pi(
    prompt: str,
    cwd: Path,
    *,
    model: str,
    provider: str,
    timeout: float,
) -> dict[str, Any]:
    raw = run_cmd(pi_argv(prompt, model=model, provider=provider), cwd=cwd, timeout=timeout)
    parsed = parse_pi_json(raw.get("stdout") or "")
    raw["parsed"] = parsed
    raw["ok"] = raw.get("exit") == 0 and not raw.get("timed_out")
    return raw


def livingdict_bin() -> str:
    local = REPO / "bin" / "livingdict"
    if local.is_file():
        return str(local)
    return which("livingdict") or "livingdict"


def livingdict_argv(prompt: str, cwd: Path, *, max_turns: int, run_dir: Path) -> list[str]:
    return [
        livingdict_bin(),
        "-p",
        prompt,
        "--cwd",
        str(cwd),
        "--max-turns",
        str(max_turns),
        "--run-dir",
        str(run_dir),
        "--cache-scope",
        "run",
    ]


def parse_livingdict_json(stdout: str) -> dict[str, Any]:
    raw = stdout.strip()
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        start, end = raw.find("{"), raw.rfind("}")
        if start < 0 or end <= start:
            return {"text": raw[-4000:]}
        try:
            value = json.loads(raw[start : end + 1])
        except json.JSONDecodeError:
            return {"text": raw[-4000:]}
    if not isinstance(value, dict):
        return {"text": raw[-4000:]}
    return {
        "text": value.get("reason") or value.get("decision") or "",
        "turns": value.get("episodes"),
        "discharged": value.get("discharged"),
        "decision": value.get("decision"),
        "ok": value.get("ok"),
    }


def run_livingdict(
    prompt: str,
    cwd: Path,
    *,
    max_turns: int,
    timeout: float,
) -> dict[str, Any]:
    run_dir = cwd / ".livingdict-run"
    run_dir.mkdir(parents=True, exist_ok=True)
    raw = run_cmd(
        livingdict_argv(prompt, cwd, max_turns=max_turns, run_dir=run_dir),
        cwd=cwd,
        timeout=timeout,
    )
    parsed = parse_livingdict_json(raw.get("stdout") or "")
    raw["parsed"] = parsed
    raw["ok"] = raw.get("exit") == 0 and not raw.get("timed_out")
    return raw


def run_external_arm(
    command: list[str],
    prompt: str,
    cwd: Path,
    *,
    timeout: float,
) -> dict[str, Any]:
    """Run an experimental arm command with the shared prompt on stdin.

    The command is responsible for its representation (ReAct, JSON, or
    restricted Python) and must mutate only ``cwd``.  JSON stdout is parsed
    when available; raw output is retained for auditability.
    """
    raw = run_cmd(command, cwd=cwd, timeout=timeout, env={"LIVINGDICT_PROMPT": prompt})
    parsed = parse_grok_json(raw.get("stdout") or "")
    raw["parsed"] = parsed
    raw["ok"] = raw.get("exit") == 0 and not raw.get("timed_out")
    return raw


def measure_hidden_claims(workspace: Path, claims_path: Path, *, allow_check: bool = False) -> dict[str, Any]:
    dest = workspace / "claims.json"
    backup: str | None = None
    existed = dest.is_file()
    if existed:
        backup = dest.read_text(encoding="utf-8")
    dest.write_text(claims_path.read_text(encoding="utf-8"), encoding="utf-8")
    try:
        return run_gates_report(workspace, allow_check=allow_check)
    finally:
        if existed and backup is not None:
            dest.write_text(backup, encoding="utf-8")
        elif dest.is_file() and not existed:
            dest.unlink()


def run_gates_report(workspace: Path, timeout: float = 180.0, *, allow_check: bool = False) -> dict[str, Any]:
    if not GATES_PY.is_file():
        return {"passed": False, "error": f"missing {GATES_PY}"}
    argv = [sys.executable, str(GATES_PY), str(workspace), str(int(timeout))]
    if allow_check:
        argv.append("--allow-check")
    raw = run_cmd(
        argv,
        cwd=workspace,
        timeout=timeout + 30,
    )
    try:
        report = json.loads(raw.get("stdout") or "")
    except json.JSONDecodeError:
        return {
            "passed": False,
            "error": (raw.get("stderr") or "gates produced no json")[:2000],
            "exit": raw.get("exit"),
        }
    if not isinstance(report, dict):
        return {"passed": False, "error": "gates returned a non-object"}
    return report


def write_summary(out: Path, prompt: str, rows: list[dict[str, Any]]) -> None:
    payload = {
        "prompt": prompt,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "arms": [
            {
                "arm": r.get("arm"),
                "ok": r.get("ok"),
                "exit": r.get("exit"),
                "duration_ms": r.get("duration_ms"),
                "changed_files": r.get("changed_files"),
                "parsed": r.get("parsed"),
                "judge": r.get("judge"),
                "error": r.get("error") or ((r.get("stderr") or "")[:200] if not r.get("ok") else None),
                "workspace": r.get("workspace"),
                "metrics": ArmResult.from_raw(str(r.get("arm") or "unknown"), r).to_dict(),
            }
            for r in rows
        ],
    }
    (out / "summary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# compare",
        "",
        f"prompt: {prompt}",
        "",
        "| arm | ran | ms | files | judge | note |",
        "|---|---|---|---|---|---|",
    ]
    for row in rows:
        note = ""
        parsed = row.get("parsed") or {}
        if parsed.get("turns") is not None:
            note = f"{parsed.get('turns')} turns"
        if parsed.get("discharged"):
            note = (note + " — " if note else "") + "claims discharged"
        if parsed.get("text"):
            note = (note + " — " if note else "") + str(parsed["text"]).replace("\n", " ")[:80]
        if row.get("error"):
            note = str(row["error"])[:80]
        elif not row.get("ok") and row.get("stderr"):
            note = str(row["stderr"]).replace("\n", " ")[:80]
        files = ", ".join(row.get("changed_files") or []) or "—"
        judge = row.get("judge") or {}
        if "passed" in judge:
            judge_bit = "pass" if judge.get("passed") else "fail"
        else:
            judge_bit = "—"
        lines.append(
            f"| {row['arm']} | {row.get('ok')} | {row.get('duration_ms')} | {files} | {judge_bit} | {note} |"
        )
    (out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def ensure_xai_env() -> str:
    """If pi has no key, reuse the grok/Living Dictionary OAuth bearer."""
    if os.environ.get("XAI_API_KEY", "").strip():
        return "env"
    try:
        from planner import bearer_token
    except ImportError:
        return ""
    try:
        token, source = bearer_token()
    except Exception:
        return ""
    if not token:
        return ""
    os.environ["XAI_API_KEY"] = token
    return source


def dry_run(args: argparse.Namespace) -> int:
    grok = which("grok")
    pi = which("pi")
    print("grok", grok or "MISSING")
    if grok:
        ver = run_cmd([grok, "--version"], cwd=Path("."), timeout=10)
        print(" ", (ver.get("stdout") or ver.get("stderr") or "").strip().splitlines()[:1])
    print("pi", pi or "MISSING")
    if pi:
        ver = run_cmd([pi, "--version"], cwd=Path("."), timeout=10)
        print(" ", (ver.get("stdout") or ver.get("stderr") or "").strip().splitlines()[:1])
    ld = livingdict_bin()
    print("livingdict", ld if Path(ld).is_file() or which("livingdict") else "MISSING")
    if args.prompt or args.prompt_file:
        prompt = (args.prompt_file.read_text(encoding="utf-8") if args.prompt_file else args.prompt or "").strip()
        fake = Path("/tmp/compare-arm")
        print("grok argv:", grok_argv(prompt or "<prompt>", fake, model=args.grok_model, max_turns=args.max_turns))
        print("pi argv:", pi_argv(prompt or "<prompt>", model=args.pi_model, provider=args.pi_provider))
        print(
            "livingdict argv:",
            livingdict_argv(prompt or "<prompt>", fake, max_turns=args.max_turns, run_dir=fake / ".livingdict-run"),
        )
    missing = [name for name, path in (("grok", grok), ("pi", pi)) if not path]
    if not Path(ld).is_file() and not which("livingdict"):
        missing.append("livingdict")
    return 0 if not missing else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Same prompt on grok, pi, and livingdict")
    parser.add_argument("--prompt", "-p", help="shared goal")
    parser.add_argument("--prompt-file", type=Path, help="read prompt from a file")
    parser.add_argument("--seed", type=Path, help="copy this tree into each arm (default: empty)")
    parser.add_argument("--out", type=Path, help="output directory")
    parser.add_argument("--arms", default="grok,pi,livingdict", help="comma list of arm names")
    parser.add_argument(
        "--arm-cmd",
        action="append",
        default=[],
        metavar="NAME=COMMAND",
        help="external experimental arm command (repeatable; prompt is in LIVINGDICT_PROMPT)",
    )
    parser.add_argument("--parallel", action="store_true", help="run arms concurrently (default: serial)")
    parser.add_argument("--serial", action="store_true", help="run arms one after another (default)")
    parser.add_argument("--timeout", type=float, default=600.0, help="seconds per arm")
    parser.add_argument("--max-turns", type=int, default=8)
    parser.add_argument("--grok-model", default=os.environ.get("LIVINGDICT_MODEL", "grok-4.6"))
    parser.add_argument("--pi-model", default=os.environ.get("COMPARE_PI_MODEL", ""))
    parser.add_argument("--pi-provider", default=os.environ.get("COMPARE_PI_PROVIDER", ""))
    parser.add_argument("--claims", type=Path, help="hidden claims.json scored on every arm after it runs")
    parser.add_argument("--gates", action="store_true", help="run livingdict RUN-GATES on each arm workspace")
    parser.add_argument("--dry-run", action="store_true", help="check CLIs / host, do not run")
    args = parser.parse_args(argv)
    xai_source = ensure_xai_env()
    if xai_source and not args.pi_provider:
        args.pi_provider = "xai"
    if xai_source and not args.pi_model:
        args.pi_model = os.environ.get("LIVINGDICT_MODEL", "grok-4.6")

    if args.dry_run:
        if xai_source:
            print("xai", "from", xai_source, "(not printed)")
        return dry_run(args)

    prompt = args.prompt or ""
    if args.prompt_file:
        prompt = args.prompt_file.read_text(encoding="utf-8")
    prompt = prompt.strip()
    if not prompt:
        print("compare: pass --prompt or --prompt-file", file=sys.stderr)
        return 2

    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    external: dict[str, list[str]] = {}
    for spec in args.arm_cmd:
        if "=" not in spec:
            print("compare: --arm-cmd must be NAME=COMMAND", file=sys.stderr)
            return 2
        name, command = spec.split("=", 1)
        name = name.strip()
        if name not in {"react", "json-plan", "python-plan"} or not command.strip():
            print(f"compare: invalid experimental arm command {name!r}", file=sys.stderr)
            return 2
        external[name] = shlex.split(command)
    known = {"grok", "pi", "livingdict", *external}
    unknown = [a for a in arms if a not in known]
    if unknown:
        print(f"compare: unknown arm(s): {', '.join(unknown)}", file=sys.stderr)
        return 2

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = (args.out or (REPO / "compare" / "runs" / stamp)).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "prompt.txt").write_text(prompt + "\n", encoding="utf-8")

    def work(name: str) -> dict[str, Any]:
        arm_dir = out / name
        seed_copy(args.seed, arm_dir)
        before = snapshot(arm_dir)
        if name == "grok":
            raw = run_grok(
                prompt,
                arm_dir,
                model=args.grok_model,
                max_turns=args.max_turns,
                timeout=args.timeout,
            )
        elif name == "pi":
            raw = run_pi(
                prompt,
                arm_dir,
                model=args.pi_model,
                provider=args.pi_provider,
                timeout=args.timeout,
            )
        elif name == "livingdict":
            raw = run_livingdict(
                prompt,
                arm_dir,
                max_turns=args.max_turns,
                timeout=args.timeout,
            )
        elif name in external:
            raw = run_external_arm(external[name], prompt, arm_dir, timeout=args.timeout)
        else:
            raw = {"ok": False, "exit": 2, "stderr": f"unknown arm {name}", "stdout": ""}
        after = snapshot(arm_dir)
        raw["arm"] = name
        raw["workspace"] = str(arm_dir)
        raw["changed_files"] = changed(before, after)
        if args.claims:
            try:
                claim_blob = json.loads(args.claims.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                claim_blob = {}
            has_checks = any(item.get("kind") == "check" for item in (claim_blob.get("claims") or []) if isinstance(item, dict))
            raw["judge"] = measure_hidden_claims(arm_dir, args.claims, allow_check=has_checks)
        elif args.gates:
            raw["judge"] = run_gates_report(arm_dir)
        slim = {
            "arm": raw.get("arm"),
            "ok": raw.get("ok"),
            "exit": raw.get("exit"),
            "timed_out": raw.get("timed_out"),
            "duration_ms": raw.get("duration_ms"),
            "changed_files": raw.get("changed_files"),
            "parsed": raw.get("parsed"),
            "judge": raw.get("judge"),
            "error": raw.get("error"),
            "workspace": raw.get("workspace"),
            "argv": raw.get("argv"),
        }
        (arm_dir / "_compare.json").write_text(json.dumps(slim, indent=2) + "\n", encoding="utf-8")
        (arm_dir / "_stdout.txt").write_text(str(raw.get("stdout") or ""), encoding="utf-8")
        (arm_dir / "_stderr.txt").write_text(str(raw.get("stderr") or ""), encoding="utf-8")
        if raw.get("episodes"):
            (arm_dir / "_episodes.json").write_text(
                json.dumps(raw["episodes"], indent=2) + "\n", encoding="utf-8"
            )
        return raw

    rows: list[dict[str, Any]] = []
    parallel = args.parallel and not args.serial and len(arms) > 1
    if not parallel:
        for name in arms:
            print(f"compare: start {name}", flush=True)
            rows.append(work(name))
            print(f"compare: done  {name} ok={rows[-1].get('ok')} {rows[-1].get('duration_ms')}ms", flush=True)
    else:
        with ThreadPoolExecutor(max_workers=len(arms)) as pool:
            futs = {pool.submit(work, name): name for name in arms}
            for fut in as_completed(futs):
                name = futs[fut]
                try:
                    row = fut.result()
                except Exception as exc:  # noqa: BLE001
                    row = {"arm": name, "ok": False, "error": str(exc), "duration_ms": 0, "changed_files": []}
                rows.append(row)
                print(f"compare: done  {name} ok={row.get('ok')} {row.get('duration_ms')}ms", flush=True)
        order = {name: i for i, name in enumerate(arms)}
        rows.sort(key=lambda r: order.get(r.get("arm"), 99))

    write_summary(out, prompt, rows)
    print(out / "summary.md")
    print((out / "summary.md").read_text(encoding="utf-8"))
    return 0 if all(r.get("ok") for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
