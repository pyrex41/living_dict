"""SCUD child: livingdict run --request-file - --events jsonl."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import traceback
from contextlib import contextmanager, nullcontext
from pathlib import Path
from typing import Any, TextIO

from .cli import (
    CLIError,
    DEFAULT_MAX_TURNS,
    default_planner_cmd,
    resolve_argv_files,
    run_job,
)
from .rho import (
    EventStream,
    GrantError,
    GrantExpired,
    WireError,
    WireRequest,
    globs_from_roots,
    grant_mode_require,
    parse_rfc3339,
    parse_wire_request,
    request_sha256,
    require_wire_fields,
    utc_now,
    verify_witness,
)
from .trace import live_sink


def _read_request(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _cwd_under_absolute_roots(grant: dict[str, Any], cwd: Path) -> bool:
    """SCUD transmits the workspace as cmd.Dir, corroborated by absolute grant roots."""
    for key in ("write_roots", "read_roots"):
        roots = grant.get(key)
        if not isinstance(roots, list):
            continue
        for root in roots:
            if not isinstance(root, str) or not os.path.isabs(root):
                continue
            try:
                resolved = Path(root).resolve()
            except OSError:
                continue
            if cwd == resolved or resolved in cwd.parents:
                return True
    return False


def _workspace(req: WireRequest, *, explicit_cwd: bool = False) -> Path:
    context_dir = req.context.get("working_dir")
    if isinstance(context_dir, str) and context_dir.strip():
        return Path(context_dir).expanduser().resolve()
    cwd = Path.cwd().resolve()
    if explicit_cwd or _cwd_under_absolute_roots(req.grant, cwd):
        return cwd
    raise WireError(
        "workspace is ambiguous: set context.working_dir, pass --cwd, or run with "
        "cwd inside an absolute grant write_roots/read_roots entry"
    )


def _max_turns(req: WireRequest, override: int | None) -> int:
    if override is not None and override > 0:
        return override
    value = req.limits.get("max_turns")
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return DEFAULT_MAX_TURNS
    return value


def _emit_limit_budget(stream: EventStream, req: WireRequest) -> None:
    payload: dict[str, Any] = {}
    for key in (
        "max_turns",
        "max_input_tokens",
        "max_output_tokens",
        "max_cost_micros",
        "deadline",
    ):
        if key in req.limits and req.limits[key] is not None:
            payload[key] = req.limits[key]
    if not payload:
        return
    payload["cost_micros"] = 0
    stream.emit("budget.consumed", payload)


def _terminal_from_receipt(receipt: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    decision = str(receipt.get("decision") or "")
    reason = str(receipt.get("reason") or decision or "run ended")
    if decision == "success":
        return "run.completed", {"status": "succeeded"}
    if decision == "cancelled":
        return "run.cancelled", {"reason": reason or "cancelled"}
    if decision == "blocked":
        return "run.failed", {"code": "blocked", "message": reason}
    if decision == "halt_cap":
        return "run.failed", {"code": "halt_cap", "message": reason}
    if decision == "trap":
        return "run.failed", {"code": "trap", "message": reason}
    code = decision or "failed"
    return "run.failed", {"code": code, "message": reason}


def _forward_kernel(stream: EventStream, kind: str, payload: dict[str, Any]) -> None:
    if kind in {"run.completed", "run.failed", "run.cancelled"}:
        return
    stream.emit(kind, payload)


def _forward_trace(stream: EventStream, event: dict[str, Any]) -> None:
    typ = event.get("type")
    if not isinstance(typ, str) or not typ:
        return
    if typ in {"run.completed", "run.failed", "run.cancelled"}:
        return
    data = event.get("data")
    if data is None:
        data = {}
    stream.emit(typ, data)


def _fail(
    stream: EventStream, code: str, message: str, receipt: dict[str, Any] | None = None
) -> int:
    if receipt is not None:
        stream.emit("livingdict.receipt", receipt)
    stream.emit("run.failed", {"code": code, "message": message})
    return 0


LIVE_PLANNER_PROVIDERS = ("xai", "openai", "anthropic")


@contextmanager
def _planner_environment(provider: str, model: str):
    previous = {
        name: os.environ.get(name)
        for name in ("LIVINGDICT_PROVIDER", "LIVINGDICT_MODEL")
    }
    os.environ["LIVINGDICT_PROVIDER"] = provider
    os.environ["LIVINGDICT_MODEL"] = model
    try:
        yield
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def _grant_list(grant: dict[str, Any], key: str) -> list[str]:
    value = grant.get(key)
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if str(item).strip()]


def _provider_gate(
    req: WireRequest, planner_cmd: list[str] | None
) -> tuple[str, str] | None:
    """Refuse unrecognized providers before any planner can be spawned.

    grant.providers / grant.models are enforced whenever present. Without an
    explicit --planner-cmd, only providers the default live planner actually
    serves are accepted — an unknown provider must never silently route to
    the live model.
    """
    providers = _grant_list(req.grant, "providers")
    if providers and req.model_provider not in providers:
        return (
            "grant_invalid",
            f"provider {req.model_provider!r} is not in grant.providers",
        )
    models = _grant_list(req.grant, "models")
    if models and req.model_id not in models:
        return "grant_invalid", f"model {req.model_id!r} is not in grant.models"
    if not planner_cmd and req.model_provider not in LIVE_PLANNER_PROVIDERS:
        return (
            "provider_unmapped",
            f"no planner for provider {req.model_provider!r}: pass --planner-cmd "
            f"or use a provider in {', '.join(LIVE_PLANNER_PROVIDERS)}",
        )
    return None


def _grant_receipt(digest: str, code: str, message: str) -> dict[str, Any]:
    payload = {
        "decision": code,
        "discharged": False,
        "ok": False,
        "reason": message,
        "request_sha256": digest,
    }
    return payload


def execute_request(
    req: WireRequest,
    *,
    out: TextIO,
    planner_cmd: list[str] | None = None,
    claims: Path | None = None,
    run_dir: Path | None = None,
    wave_workers: int = 4,
    serial: bool = False,
    max_turns: int | None = None,
    explicit_cwd: bool = False,
) -> int:
    stream = EventStream(req.run_id, out)
    stream.emit(
        "run.started",
        {"provider": req.model_provider, "id": req.model_id},
    )
    digest = ""
    extra: dict[str, Any] = {}
    grant_verified = False
    try:
        digest = request_sha256(req.raw)
        extra["request_sha256"] = digest
        require_wire_fields(req)
        if grant_mode_require():
            verify_witness(req.raw)
            extra["grant_verification"] = "bip340"
            grant_verified = True
        expires = parse_rfc3339(req.grant.get("expires_at"))
        if expires is not None and utc_now() >= expires:
            return _fail(
                stream,
                "grant_expired",
                "grant expires_at is in the past",
                _grant_receipt(
                    digest, "grant_expired", "grant expires_at is in the past"
                ),
            )
        gate = _provider_gate(req, planner_cmd)
        if gate is not None:
            code, message = gate
            return _fail(stream, code, message, _grant_receipt(digest, code, message))
        deadline = parse_rfc3339(req.limits.get("deadline"))
        if deadline is not None and utc_now() >= deadline:
            _emit_limit_budget(stream, req)
            stream.emit("run.cancelled", {"reason": "deadline"})
            return 0
        _emit_limit_budget(stream, req)
        workspace = _workspace(req, explicit_cwd=explicit_cwd)
        workspace.mkdir(parents=True, exist_ok=True)
        write_globs = globs_from_roots(req.grant.get("write_roots"), workspace)
        read_globs = globs_from_roots(req.grant.get("read_roots"), workspace)
        allowed = write_globs if write_globs else read_globs
        cmd = list(planner_cmd) if planner_cmd else default_planner_cmd()

        def on_kernel(kind: str, payload: dict[str, Any]) -> None:
            _forward_kernel(stream, kind, payload)

        planner_env = (
            _planner_environment(req.model_provider, req.model_id)
            if planner_cmd is None
            else nullcontext()
        )
        with planner_env, live_sink(lambda event: _forward_trace(stream, event)):
            _code, receipt = run_job(
                req.prompt,
                workspace,
                max_turns=_max_turns(req, max_turns),
                claims=claims,
                run_dir=run_dir,
                planner_cmd=cmd,
                wave_workers=wave_workers,
                serial=serial,
                allowed_globs=allowed,
                event_sink=on_kernel,
                print_receipt=False,
                deadline=deadline,
                run_id=req.run_id,
                system_prompt=req.system,
                receipt_extra=extra,
                grant_verified=grant_verified,
            )
    except GrantExpired as exc:
        return _fail(
            stream,
            "grant_expired",
            str(exc),
            _grant_receipt(digest, "grant_expired", str(exc)),
        )
    except GrantError as exc:
        return _fail(
            stream,
            "grant_invalid",
            str(exc),
            _grant_receipt(digest, "grant_invalid", str(exc)),
        )
    except WireError as exc:
        return _fail(stream, "invalid_request", str(exc))
    except CLIError as exc:
        return _fail(stream, "planner", str(exc))
    except KeyboardInterrupt:
        stream.emit("run.cancelled", {"reason": "interrupted"})
        return 0
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        return _fail(stream, "internal", str(exc))

    stream.emit("livingdict.receipt", receipt)
    text = str(receipt.get("reason") or receipt.get("decision") or "")
    if text:
        stream.emit("message.delta", {"text": text})
    typ, data = _terminal_from_receipt(receipt)
    stream.emit(typ, data)
    return 0


def build_run_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="livingdict run",
        description="rho.run/v1 child: one JSON wireRequest on stdin, JSONL events on stdout",
    )
    parser.add_argument(
        "--request-file", default="-", help="wireRequest JSON path, or - for stdin"
    )
    parser.add_argument(
        "--events", default="jsonl", choices=("jsonl",), help="event encoding"
    )
    parser.add_argument(
        "--planner-cmd",
        nargs="+",
        metavar="ARG",
        help="argv that reads observation JSON on stdin and writes envelope JSON on stdout",
    )
    parser.add_argument(
        "--claims", type=Path, help="hidden claims.json used for discharge"
    )
    parser.add_argument("--run-dir", type=Path, help="job state directory")
    parser.add_argument(
        "--cwd", type=Path, help="process working directory (SCUD sets cmd.Dir)"
    )
    parser.add_argument("--wave-workers", type=int, default=4)
    parser.add_argument("--serial", action="store_true")
    parser.add_argument("--max-turns", type=int, default=None)
    return parser


def _resolve_user_path(value: Path | None, origin: Path) -> Path | None:
    if value is None:
        return None
    if value.is_absolute():
        return value
    return (origin / value).resolve()


def run_main(argv: list[str] | None = None) -> int:
    parser = build_run_parser()
    args = parser.parse_args(argv)
    origin = Path.cwd().resolve()
    request_file = args.request_file
    if request_file != "-" and not os.path.isabs(request_file):
        request_file = str((origin / request_file).resolve())
    claims = _resolve_user_path(args.claims, origin)
    run_dir = _resolve_user_path(args.run_dir, origin)
    planner_cmd = list(args.planner_cmd) if args.planner_cmd else None
    if planner_cmd and len(planner_cmd) == 1:
        planner_cmd = shlex.split(planner_cmd[0])
    if planner_cmd:
        planner_cmd = resolve_argv_files(planner_cmd, origin)
    if args.cwd is not None:
        target = args.cwd if args.cwd.is_absolute() else origin / args.cwd
        os.chdir(target)
    try:
        raw = _read_request(request_file)
    except json.JSONDecodeError as exc:
        print(f"decode rho.run/v1 request: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"read rho.run/v1 request: {exc}", file=sys.stderr)
        return 1
    try:
        req = parse_wire_request(raw)
    except WireError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if not req.run_id:
        print("run_id is required", file=sys.stderr)
        return 1
    return execute_request(
        req,
        out=sys.stdout,
        planner_cmd=planner_cmd,
        claims=claims,
        run_dir=run_dir,
        wave_workers=args.wave_workers,
        serial=args.serial,
        max_turns=args.max_turns,
        explicit_cwd=args.cwd is not None,
    )
