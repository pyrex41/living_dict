"""Backpressure gates: measured success, not a RECEIPT.

Manifest shape matches Shen-Backpressure `[[gates]]` (name, kind, run).
`kind = livingdict` is our first-step measurer: sources / build / bundle.
When `sb` is on PATH and `specs/core.shen` exists, an `sb` gate runs
`sb gates` and records that discharge too.
"""

from __future__ import annotations

import contextvars
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

try:
    from .check import _run, extend_path, find_npm, python_test_files, run_workspace_check
except ImportError:  # python3 gates.py WORKSPACE
    import sys as _sys

    _sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from livingdict.check import (  # type: ignore
        _run,
        extend_path,
        find_npm,
        python_test_files,
        run_workspace_check,
    )


SCHEMA_VERSION = 1


def _clean(value: Any) -> Any:
    """Lua encode_json is 7-bit; keep gate logs ASCII so /think receipts parse."""
    if isinstance(value, str):
        return value.encode("ascii", "replace").decode("ascii")
    if isinstance(value, list):
        return [_clean(item) for item in value]
    if isinstance(value, dict):
        return {str(k): _clean(v) for k, v in value.items()}
    return value


def find_sb() -> str | None:
    env = extend_path(os.environ.copy())
    return shutil.which("sb", path=env.get("PATH"))


def parse_gates_toml(text: str) -> list[dict[str, str]]:
    gates: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw_line in text.splitlines():
        raw = raw_line.split("#", 1)[0].strip()
        if not raw:
            continue
        if raw == "[[gates]]":
            if current:
                gates.append(current)
            current = {}
            continue
        if raw.startswith("[") and not raw.startswith("[["):
            if current:
                gates.append(current)
            current = None
            continue
        if current is None or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        current[key.strip()] = value.strip().strip('"').strip("'")
    if current:
        gates.append(current)
    return gates


def load_manifest_gates(workspace: Path) -> list[dict[str, str]]:
    for name in ("sb.toml", "gates.toml"):
        path = workspace / name
        if path.is_file():
            try:
                return parse_gates_toml(path.read_text(encoding="utf-8"))
            except OSError:
                return []
    return []


def _with_claims(gates: list[dict[str, str]]) -> list[dict[str, str]]:
    names = {g.get("name") for g in gates}
    if "claims" not in names:
        gates = list(gates) + [{"name": "claims", "kind": "livingdict", "measure": "claims"}]
    return gates


def infer_gates(workspace: Path) -> list[dict[str, str]]:
    declared = load_manifest_gates(workspace)
    if python_test_files(workspace) and not declared:
        gates = [{"name": "test", "kind": "livingdict", "measure": "build"}]
        if (workspace / "claims.json").is_file():
            return _with_claims(gates)
        return gates
    if declared:
        return _with_claims(declared)
    if (workspace / "package.json").is_file():
        return _with_claims(
            [
                {"name": "sources", "kind": "livingdict", "measure": "sources"},
                {"name": "build", "kind": "livingdict", "measure": "build"},
                {"name": "bundle", "kind": "livingdict", "measure": "bundle"},
                {"name": "look", "kind": "livingdict", "measure": "look"},
            ]
        )
    if (workspace / "claims.json").is_file():
        return [{"name": "claims", "kind": "livingdict", "measure": "claims"}]
    return []


def _ok(name: str, **extra: Any) -> dict[str, Any]:
    body = {"name": name, "passed": True, "skipped": False, "layer": extra.pop("layer", "structural")}
    body.update(extra)
    return body


def _fail(name: str, reason: str, **extra: Any) -> dict[str, Any]:
    body = {
        "name": name,
        "passed": False,
        "skipped": False,
        "reason": reason,
        "layer": extra.pop("layer", "structural"),
    }
    body.update(extra)
    return body


GOAL_LAYER = frozenset({"claims", "look", "sb"})


def load_claims(workspace: Path) -> dict[str, Any] | None:
    path = workspace / "claims.json"
    if not path.is_file():
        return None
    try:
        blob = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return blob if isinstance(blob, dict) else None


def _iter_source_text(workspace: Path) -> str:
    skip = {".git", "node_modules", "dist", "build", ".vite", ".sb", "__pycache__"}
    chunks: list[str] = []
    for path in sorted(workspace.rglob("*")):
        if not path.is_file():
            continue
        if any(part in skip for part in path.parts):
            continue
        if path.name in {"GOAL.md", "PROGRESS.md", "claims.json", "README.md"}:
            continue
        if path.suffix.lower() not in {
            ".js",
            ".jsx",
            ".ts",
            ".tsx",
            ".py",
            ".json",
            ".html",
            ".css",
            ".md",
            ".shen",
            ".fs",
            ".go",
            ".rs",
            ".toml",
        }:
            continue
        try:
            chunks.append(path.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
        if sum(len(c) for c in chunks) > 400_000:
            break
    return "\n".join(chunks).lower()


def _read_claim_file(workspace: Path, rel: str) -> tuple[Path | None, str]:
    if not rel or rel in {".", "claims.json"}:
        return None, ""
    path = workspace / rel
    if not path.is_file():
        return None, ""
    try:
        return path, path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None, ""


def _check_preflight_reason(command: str) -> str | None:
    """Reject known toolchain misconfiguration before a long child timeout."""
    lowered = command.lower()
    if "bifrost" not in lowered or "shake" not in lowered:
        return None
    launcher = os.environ.get("RATATOSKR_HOST", "").strip() or os.environ.get("BIFROST_SHEN_CL", "").strip()
    if launcher:
        return None
    # Ratatoskr may be installed while its host launcher is not configured;
    # that is precisely the slow failure mode this guard prevents.
    return "missing Shen launcher: set RATATOSKR_HOST or BIFROST_SHEN_CL"


def _workspace_fingerprint(workspace: Path) -> str:
    digest = hashlib.sha256()
    skip = {".git", ".livingdict-run", "node_modules", "dist", "build", ".sb", "__pycache__"}
    for path in sorted(workspace.rglob("*")):
        if not path.is_file() or any(part in skip for part in path.parts):
            continue
        try:
            stat = path.stat()
            digest.update(path.relative_to(workspace).as_posix().encode())
            digest.update(str(stat.st_size).encode())
            digest.update(str(stat.st_mtime_ns).encode())
        except OSError:
            continue
    return digest.hexdigest()


def _gate_cache_path(workspace: Path) -> Path:
    return workspace / ".livingdict-run" / "gates-cache.json"


def _cacheable(workspace: Path, spec: dict[str, str]) -> bool:
    measure = (spec.get("measure") or spec.get("name") or "").lower()
    if measure in {"sources", "bundle"}:
        return True
    if measure != "claims":
        return False
    blob = load_claims(workspace) or {}
    return not any(isinstance(item, dict) and str(item.get("kind", "source")).lower() == "check" for item in blob.get("claims", []))


def _cache_key(workspace: Path, spec: dict[str, str]) -> str:
    data = json.dumps({"workspace": _workspace_fingerprint(workspace), "spec": spec}, sort_keys=True)
    return hashlib.sha256(data.encode()).hexdigest()


def _load_cached_gate(workspace: Path, spec: dict[str, str]) -> dict[str, Any] | None:
    if not _cacheable(workspace, spec):
        return None
    try:
        blob = json.loads(_gate_cache_path(workspace).read_text(encoding="utf-8"))
        entry = blob.get(_cache_key(workspace, spec))
        return dict(entry) if isinstance(entry, dict) and entry.get("passed") else None
    except (OSError, json.JSONDecodeError):
        return None


def _save_cached_gate(workspace: Path, spec: dict[str, str], result: dict[str, Any]) -> None:
    if not _cacheable(workspace, spec) or not result.get("passed"):
        return
    path = _gate_cache_path(workspace)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            blob = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            blob = {}
        blob[_cache_key(workspace, spec)] = result
        path.write_text(json.dumps(blob, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except OSError:
        pass


def _start_fixture(workspace: Path, fixture: dict[str, Any]) -> tuple[Any | None, str | None]:
    command = str(fixture.get("command") or "").strip()
    if not command:
        return None, "fixture has no command"
    try:
        proc = subprocess.Popen(["sh", "-lc", command], cwd=workspace, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as exc:
        return None, f"fixture failed to start: {exc}"
    url = str(fixture.get("ready_url") or fixture.get("url") or "").strip()
    if not url:
        return proc, None
    try:
        budget = max(0.5, float(fixture.get("ready_timeout_seconds") or 5.0))
    except (TypeError, ValueError):
        budget = 5.0
    deadline = time.monotonic() + budget
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return proc, "fixture exited before readiness"
        try:
            with urllib.request.urlopen(url, timeout=0.25) as response:
                if 200 <= response.status < 500:
                    return proc, None
        except (OSError, urllib.error.URLError):
            time.sleep(0.1)
    return proc, f"fixture readiness timeout: {url}"


def _stop_fixtures(fixtures: dict[str, tuple[Any | None, str | None]]) -> None:
    for proc, _error in fixtures.values():
        if proc is None or proc.poll() is not None:
            continue
        try:
            proc.terminate()
            proc.wait(timeout=1.0)
        except (OSError, subprocess.TimeoutExpired):
            try:
                proc.kill()
            except OSError:
                pass
# check-kind claims execute a command as the judge. That authority must come
# from a human (an approved contract or a hidden --claims file), never from a
# claims.json the model wrote itself — deny by default, same rule as policy.
_ALLOW_CHECK: contextvars.ContextVar[bool] = contextvars.ContextVar(
    "livingdict_allow_check", default=False
)


def measure_claims(workspace: Path) -> dict[str, Any]:
    blob = load_claims(workspace)
    if blob is None:
        return _fail(
            "claims",
            "no claims.json — the planner must write goal-shaped success claims",
            layer="goal",
        )
    raw = blob.get("claims")
    if not isinstance(raw, list) or not raw:
        return _fail("claims", "claims.json has no claims[]", layer="goal")
    whole = _iter_source_text(workspace)
    results: list[dict[str, Any]] = []
    failed_checks: set[str] = set()
    fixtures: dict[str, tuple[Any | None, str | None]] = {}
    for item in raw:
        if not isinstance(item, dict):
            results.append({"id": "?", "passed": False, "reason": "claim is not an object"})
            continue
        cid = str(item.get("id") or "claim")
        kind = str(item.get("kind") or "source").lower()
        needles = item.get("any") or item.get("must") or []
        if isinstance(needles, str):
            needles = [needles]
        needles = [str(n).lower() for n in needles if str(n).strip()]
        rel = str(item.get("path") or "")
        try:
            floor = int(item.get("min_bytes") or 0)
        except (TypeError, ValueError):
            floor = 0
        if kind == "file":
            path, text = _read_claim_file(workspace, rel)
            ok = path is not None
            if ok and floor and path.stat().st_size < floor:
                ok = False
            if ok and needles and not any(n in text.lower() for n in needles):
                ok = False
            results.append({"id": cid, "passed": ok, "kind": kind, "path": rel})
        elif kind == "absent":
            ok = bool(rel) and not (workspace / rel).exists()
            results.append({"id": cid, "passed": ok, "kind": kind, "path": rel})
        elif kind == "check":
            command = str(item.get("command") or "").strip()
            if not command:
                results.append({"id": cid, "passed": False, "kind": kind, "reason": "check claim has no command"})
                continue
            dependencies = item.get("depends_on") or []
            if isinstance(dependencies, str):
                dependencies = [dependencies]
            blocked_by = [str(dep) for dep in dependencies if str(dep) in failed_checks]
            # Common generated HTTP checks depend on a successful build even
            # when the proposal omitted explicit depends_on metadata.
            if not blocked_by and failed_checks and ("curl" in command.lower() or "todo-server" in command.lower()):
                blocked_by = sorted(failed_checks)
            if blocked_by:
                entry = {
                    "id": cid,
                    "passed": False,
                    "kind": kind,
                    "command": command,
                    "timed_out": False,
                    "returncode": None,
                    "blocked_by": blocked_by,
                    "reason": "blocked by failed prerequisite",
                }
                results.append(entry)
                failed_checks.add(cid)
                continue
            if not _ALLOW_CHECK.get():
                results.append(
                    {
                        "id": cid,
                        "passed": False,
                        "kind": kind,
                        "command": command,
                        "reason": "check claims execute only under an approved or hidden contract",
                    }
                )
                failed_checks.add(cid)
                continue
            preflight_reason = _check_preflight_reason(command)
            if preflight_reason:
                results.append(
                    {
                        "id": cid,
                        "passed": False,
                        "kind": kind,
                        "command": command,
                        "timed_out": False,
                        "returncode": None,
                        "reason": preflight_reason,
                    }
                )
                failed_checks.add(cid)
                continue
            fixture = item.get("fixture")
            if fixture is not None:
                if not isinstance(fixture, dict):
                    entry = {"id": cid, "passed": False, "kind": kind, "command": command, "reason": "fixture must be an object"}
                    results.append(entry)
                    failed_checks.add(cid)
                    continue
                fixture_key = json.dumps(fixture, sort_keys=True)
                if fixture_key not in fixtures:
                    fixtures[fixture_key] = _start_fixture(workspace, fixture)
                _proc, fixture_error = fixtures[fixture_key]
                if fixture_error:
                    entry = {"id": cid, "passed": False, "kind": kind, "command": command, "reason": fixture_error, "timed_out": False}
                    results.append(entry)
                    failed_checks.add(cid)
                    continue
            try:
                budget = float(item.get("timeout_seconds") or 60.0)
            except (TypeError, ValueError):
                budget = 60.0
            outcome = _run(["sh", "-lc", command], workspace, budget, {})
            returncode = outcome.get("returncode")
            entry: dict[str, Any] = {
                "id": cid,
                "passed": returncode == 0 and not outcome.get("timed_out"),
                "kind": kind,
                "command": command,
                "returncode": returncode,
                "timed_out": bool(outcome.get("timed_out")),
            }
            tail = str(outcome.get("stderr") or outcome.get("stdout") or "").strip()
            if tail:
                entry["output"] = tail[-400:]
            results.append(entry)
            if not entry["passed"]:
                failed_checks.add(cid)
        else:
            if not needles:
                results.append({"id": cid, "passed": False, "reason": "source claim has no any/must"})
                continue
            if rel:
                path, text = _read_claim_file(workspace, rel)
                if path is None:
                    results.append({"id": cid, "passed": False, "kind": "source", "reason": f"missing {rel}"})
                    continue
                if floor == 0:
                    floor = 120
                if path.stat().st_size < floor:
                    results.append(
                        {
                            "id": cid,
                            "passed": False,
                            "kind": "source",
                            "reason": f"{rel} is {path.stat().st_size} bytes, need {floor}",
                        }
                    )
                    continue
                hay = text.lower()
            else:
                hay = whole
            hit = [n for n in needles if n in hay]
            results.append({"id": cid, "passed": bool(hit), "kind": "source", "hit": hit, "wanted": needles, "path": rel})
    failed = [r for r in results if not r.get("passed")]
    _stop_fixtures(fixtures)
    if failed:
        ids = ", ".join(str(r.get("id")) for r in failed)
        return _fail("claims", "failed " + ids, layer="goal", claims=results)
    return _ok("claims", layer="goal", claims=results, measure="goal claims")


def measure_look(workspace: Path, timeout: float) -> dict[str, Any]:
    dist = workspace / "dist"
    if not (dist / "index.html").is_file():
        return {
            "name": "look",
            "passed": True,
            "skipped": True,
            "layer": "goal",
            "reason": "no viewable build (not a web product, or not built)",
        }
    import http.server
    import socketserver
    import threading
    import urllib.error
    import urllib.request

    class _Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(dist), **kwargs)

        def log_message(self, *_args) -> None:
            return

    try:
        httpd = socketserver.TCPServer(("127.0.0.1", 0), _Handler)
    except OSError as exc:
        return _fail("look", str(exc), layer="goal")
    httpd.allow_reuse_address = True
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{port}/"
    try:
        with urllib.request.urlopen(url, timeout=min(15.0, max(3.0, float(timeout)))) as resp:
            code = getattr(resp, "status", 200)
            body = resp.read(12_000).decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        httpd.shutdown()
        httpd.server_close()
        return _fail("look", str(exc), layer="goal")
    httpd.shutdown()
    httpd.server_close()
    if code != 200:
        return _fail("look", f"HTTP {code}", layer="goal")
    low = body.lower()
    if "<html" not in low and "<!doctype" not in low:
        return _fail("look", "build did not serve HTML", layer="goal")
    return _ok("look", layer="goal", measure="served built product", evidence=["dist/index.html"])


def measure_sources(workspace: Path) -> dict[str, Any]:
    missing: list[str] = []
    evidence: list[str] = []
    if (workspace / "package.json").is_file():
        for rel in ("package.json", "index.html"):
            path = workspace / rel
            if path.is_file() and path.stat().st_size > 0:
                evidence.append(rel)
            else:
                missing.append(rel)
        src_dir = workspace / "src"
        entries = []
        if src_dir.is_dir():
            for pattern in ("*.jsx", "*.tsx", "*.js", "*.ts"):
                entries.extend(sorted(src_dir.glob(pattern)))
        if not entries:
            missing.append("src/*.{js,jsx,ts,tsx}")
        else:
            evidence.extend(p.relative_to(workspace).as_posix() for p in entries[:8])
        if missing:
            return _fail("sources", "missing " + ", ".join(missing), evidence=evidence)
        return _ok("sources", evidence=evidence, measure="files present")
    if python_test_files(workspace):
        py = list((workspace / "app").rglob("*.py")) if (workspace / "app").is_dir() else []
        py += list((workspace / "src").rglob("*.py")) if (workspace / "src").is_dir() else []
        if not py:
            return _fail("sources", "no Python package under app/ or src/")
        evidence = [p.relative_to(workspace).as_posix() for p in py[:8]]
        return _ok("sources", evidence=evidence, measure="files present")
    return _fail("sources", "no package.json or Python tests layout")


def measure_build(workspace: Path, timeout: float) -> dict[str, Any]:
    started = time.perf_counter()
    check = run_workspace_check(workspace, timeout)
    check["name"] = "build"
    check["duration_ms"] = int((time.perf_counter() - started) * 1000)
    if check.get("skipped"):
        check["name"] = "build"
        check["reason"] = check.get("stderr") or "no build command"
    return check


def measure_bundle(workspace: Path) -> dict[str, Any]:
    html = workspace / "dist" / "index.html"
    if not html.is_file():
        return _fail("bundle", "dist/index.html missing")
    try:
        text = html.read_text(encoding="utf-8")
    except OSError as exc:
        return _fail("bundle", str(exc))
    if "<script" not in text.lower():
        return _fail("bundle", "dist/index.html has no script tag", evidence=["dist/index.html"])
    match = re.search(r"""src=["']([^"']+\.js)["']""", text)
    if not match:
        return _fail("bundle", "dist/index.html has no .js src", evidence=["dist/index.html"])
    src = match.group(1).lstrip("/")
    if src.startswith("scene/"):
        src = src[len("scene/") :]
    asset = workspace / "dist" / src
    if not asset.is_file():
        # vite often emits /scene/assets/foo.js — try basename under dist/assets
        asset = workspace / "dist" / "assets" / Path(src).name
    if not asset.is_file():
        return _fail("bundle", f"missing bundle {src}", evidence=["dist/index.html"])
    size = asset.stat().st_size
    if size < 8:
        return _fail("bundle", f"{asset.name} is empty", evidence=[asset.relative_to(workspace).as_posix()])
    return _ok(
        "bundle",
        evidence=["dist/index.html", asset.relative_to(workspace).as_posix()],
        bytes=size,
        measure="dist js referenced and present",
    )


def measure_sb(workspace: Path, timeout: float) -> dict[str, Any]:
    binary = find_sb()
    if not binary:
        return {"name": "sb", "passed": False, "skipped": True, "reason": "sb not on PATH"}
    started = time.perf_counter()
    result = _run([binary, "gates"], workspace, timeout, {})
    result["name"] = "sb"
    result["command"] = "sb gates"
    result["duration_ms"] = int((time.perf_counter() - started) * 1000)
    report = workspace / ".sb" / "discharge_report.json"
    if report.is_file():
        result["report"] = ".sb/discharge_report.json"
    return result


MEASURES: dict[str, Callable[..., dict[str, Any]]] = {
    "sources": lambda ws, _t: measure_sources(ws),
    "build": measure_build,
    "bundle": lambda ws, _t: measure_bundle(ws),
    "claims": lambda ws, _t: measure_claims(ws),
    "look": measure_look,
    "sb": measure_sb,
}


def run_one_gate(workspace: Path, spec: dict[str, str], timeout: float) -> dict[str, Any]:
    name = spec.get("name") or spec.get("measure") or "gate"
    kind = (spec.get("kind") or "command").lower()
    measure = (spec.get("measure") or "").lower()
    started = time.perf_counter()
    if kind == "livingdict" or measure in MEASURES:
        key = measure or name
        fn = MEASURES.get(key)
        if fn is None:
            return _fail(name, f"unknown livingdict measure {key}")
        result = fn(workspace, timeout)
        result.setdefault("name", name)
        result.setdefault("duration_ms", int((time.perf_counter() - started) * 1000))
        return result
    run = spec.get("run") or ""
    if not run:
        return _fail(name, "gate has no run= command")
    argv = ["sh", "-lc", run] if any(ch in run for ch in "|&;<>") else run.split()
    if argv and argv[0] == "npm":
        argv[0] = find_npm()
    result = _run(argv, workspace, timeout, {})
    result["name"] = name
    result["command"] = run
    result["duration_ms"] = int((time.perf_counter() - started) * 1000)
    return result


def write_discharge(workspace: Path, report: dict[str, Any]) -> Path:
    target = workspace / ".sb" / "discharge_report.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    history = workspace / ".sb" / "history"
    history.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    (history / f"discharge_{stamp}.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return target


def context_markdown(report: dict[str, Any]) -> str:
    lines = ["# backpressure", ""]
    stamp = "PASS" if report.get("passed") else "FAIL"
    lines.append(f"overall **{stamp}** · {report.get('engine', 'livingdict')} · schema {report.get('schema_version')}")
    lines.append("")
    for gate in report.get("gates") or []:
        mark = "pass" if gate.get("passed") else ("skip" if gate.get("skipped") else "fail")
        name = gate.get("name") or "?"
        extra = gate.get("reason") or gate.get("command") or gate.get("measure") or ""
        dur = gate.get("duration_ms")
        bit = f" ({dur}ms)" if isinstance(dur, int) else ""
        lines.append(f"- `{name}` {mark}{bit}" + (f" — {extra}" if extra else ""))
    return "\n".join(lines) + "\n"


def run_gates(
    workspace: Path,
    timeout: float = 180.0,
    persist: bool = True,
    allow_check: bool = False,
) -> dict[str, Any]:
    token = _ALLOW_CHECK.set(bool(allow_check))
    try:
        return _run_gates_inner(workspace, timeout, persist)
    finally:
        _ALLOW_CHECK.reset(token)


def _run_gates_inner(workspace: Path, timeout: float, persist: bool) -> dict[str, Any]:
    workspace = Path(workspace)
    specs = infer_gates(workspace)
    if not specs:
        report = {
            "schema_version": SCHEMA_VERSION,
            "engine": "livingdict",
            "passed": True,
            "skipped": True,
            "command": "RUN-GATES",
            "gates": [],
            "stderr": "no gates inferred for this workspace",
            "stdout": "",
            "timed_out": False,
            "returncode": 0,
        }
        return report
    leftover = float(timeout)
    results: list[dict[str, Any]] = []
    for spec in specs:
        slice_timeout = max(5.0, leftover / max(1, len(specs) - len(results)))
        result = _load_cached_gate(workspace, spec)
        if result is None:
            result = run_one_gate(workspace, spec, slice_timeout)
            if persist:
                _save_cached_gate(workspace, spec, result)
        else:
            result = dict(result)
            result["cached"] = True
        results.append(result)
        leftover = max(5.0, leftover - float(result.get("duration_ms") or 0) / 1000.0)
        if result.get("timed_out"):
            break
    failed = [g for g in results if not g.get("passed") and not g.get("skipped")]
    report = {
        "schema_version": SCHEMA_VERSION,
        "engine": "livingdict",
        "passed": not failed,
        "skipped": False,
        "command": "RUN-GATES",
        "gates": results,
        "stdout": context_markdown({"passed": not failed, "engine": "livingdict", "schema_version": SCHEMA_VERSION, "gates": results}),
        "stderr": "\n".join(
            f"{g.get('name')}: {g.get('reason') or g.get('stderr') or 'failed'}" for g in failed
        ),
        "timed_out": any(g.get("timed_out") for g in results),
        "returncode": 0 if not failed else 1,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    if (workspace / "specs" / "core.shen").is_file() and find_sb() and not any(s.get("name") == "sb" for s in specs):
        sb_result = measure_sb(workspace, leftover)
        report["gates"].append(sb_result)
        if not sb_result.get("passed") and not sb_result.get("skipped"):
            report["passed"] = False
            report["returncode"] = 1
    if persist:
        write_discharge(workspace, report)
    return _clean(report)


def main(argv: list[str] | None = None) -> int:
    import sys

    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("usage: gates.py WORKSPACE [TIMEOUT] [--allow-check]", file=sys.stderr)
        return 2
    allow_check = "--allow-check" in args[1:]
    numeric = [item for item in args[1:] if item != "--allow-check"]
    timeout = float(numeric[0]) if numeric else 180.0
    json.dump(run_gates(Path(args[0]), timeout, allow_check=allow_check), sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
