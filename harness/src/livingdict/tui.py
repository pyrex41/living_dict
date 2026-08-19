"""livingdict tui — a shell, not an IDE.

Line-oriented live view over run_job: type a goal, watch episodes stream
(plan → critic → installs → waves → gates → verdict). Reads goals from
stdin, so it pipes: `echo 'write hello.txt' | livingdict tui --cwd /tmp/x`.
Stdlib only, ANSI only, no curses.
"""

from __future__ import annotations

import argparse
import os
import shlex
import sys
import time
from pathlib import Path
from typing import Any, TextIO

import hashlib
import json

from .cli import CLIError, call_planner_json, resolve_argv_files, run_job
from .envelope import EnvelopeError
from .kernel import KernelError
from .trace import live_sink


def _want_color(stream: TextIO, flag: bool) -> bool:
    if not flag or os.environ.get("NO_COLOR"):
        return False
    return bool(getattr(stream, "isatty", lambda: False)())


class Painter:
    def __init__(self, out: TextIO, color: bool) -> None:
        self.out = out
        self.color = color

    def _c(self, code: str, text: str) -> str:
        if not self.color:
            return text
        return f"\x1b[{code}m{text}\x1b[0m"

    def dim(self, text: str) -> str:
        return self._c("2", text)

    def green(self, text: str) -> str:
        return self._c("32", text)

    def red(self, text: str) -> str:
        return self._c("31", text)

    def yellow(self, text: str) -> str:
        return self._c("33", text)

    def bold(self, text: str) -> str:
        return self._c("1", text)

    def line(self, text: str = "") -> None:
        self.out.write(text + "\n")
        self.out.flush()


class Renderer:
    """One event, one line. Kernel events and trace events share this."""

    def __init__(self, paint: Painter, verbose: bool = False) -> None:
        self.paint = paint
        self.verbose = verbose
        self.episode = 0
        self._plan_started: float | None = None

    def kernel(self, kind: str, payload: dict[str, Any]) -> None:
        p = self.paint
        if kind == "episode.planned":
            self.episode += 1
            took = ""
            if self._plan_started is not None:
                took = f"  ({time.monotonic() - self._plan_started:.1f}s)"
                self._plan_started = None
            keys = ",".join(payload.get("artifact_keys") or []) or "-"
            fp = str(payload.get("fingerprint") or "")[:8]
            p.line(p.dim(f"∙ e{self.episode} plan  fp={fp}  artifacts={keys}{took}"))
            rationale = str(payload.get("rationale") or "").strip()
            if rationale:
                p.line(p.dim(f'  "{rationale[:200]}"'))
            nodes = payload.get("nodes") or []
            if nodes:
                for node in nodes:
                    deps = ",".join(node.get("depends_on") or []) or "-"
                    writes = ",".join(node.get("writes") or []) or "-"
                    p.line(p.dim(f"  ▤ {node.get('id')}  after: {deps}  writes: {writes}"))
            if self.verbose:
                program = str(payload.get("program") or "").strip()
                for src_line in program.splitlines()[:12]:
                    p.line(p.dim(f"  ¦ {src_line}"))
        elif kind == "critic.accepted":
            p.line(p.green("✓ critic accept"))
        elif kind == "critic.rejected":
            p.line(p.red("✗ critic reject"))
            for err in payload.get("errors") or []:
                p.line(p.red(f"    {err}"))
        elif kind == "episode.blocked_duplicate":
            p.line(p.yellow("⊘ duplicate plan blocked (fingerprint seen)"))
        elif kind == "artifacts.applied":
            keys = payload.get("keys") or []
            if keys:
                p.line(f"+ installed {', '.join(keys)}")
        elif kind == "gates.measured":
            report = payload.get("report") or {}
            names = [g.get("name") for g in report.get("gates") or []]
            verdict = p.green("pass") if report.get("passed") else p.red("fail")
            judge = ""
            if payload.get("claims_source") == "workspace":
                judge = p.yellow("  [model-authored claims]")
            elif payload.get("claims_source") == "approved":
                judge = p.dim("  [approved contract]")
            p.line(f"⚖ gates {verdict}  ({', '.join(str(n) for n in names) or 'none'}){judge}")
            if not report.get("passed"):
                self._gate_failures(report)
        elif kind == "dictionary.promoted":
            p.line(p.dim(f"※ word {payload.get('word')} promoted"))

    def _gate_failures(self, report: dict[str, Any]) -> None:
        p = self.paint
        for gate in report.get("gates") or []:
            if gate.get("passed") or gate.get("skipped"):
                continue
            claims = gate.get("claims")
            if claims:
                for claim in claims:
                    if claim.get("passed"):
                        continue
                    wanted = ", ".join(claim.get("wanted") or []) or "presence"
                    where = claim.get("path") or "workspace"
                    p.line(p.red(f"    ✗ claim {claim.get('id')}: wanted {wanted} in {where}"))
                continue
            detail = str(gate.get("stderr") or gate.get("stdout") or "").strip()
            if detail:
                first = detail.splitlines()[0][:200]
                p.line(p.red(f"    ✗ {gate.get('name')}: {first}"))

    def trace(self, event: dict[str, Any]) -> None:
        p = self.paint
        typ = event.get("type") or ""
        data = event.get("data") or {}
        if typ == "planner.call":
            self._plan_started = time.monotonic()
            p.line(p.dim(f"… planning e{data.get('episode')} (model call)"))
        elif typ == "planner.stderr":
            p.line(p.dim(f"│ {data.get('line')}"))
        elif typ == "mutation.applied":
            p.line(f"  w {data.get('path')}  {str(data.get('sha256') or '')[:8]}")
        elif typ == "graph.node.start":
            p.line(p.dim(f"  ▸ {data.get('node')} [{data.get('worker')}]"))
        elif typ == "graph.node.finish":
            status = data.get("status")
            mark = p.green("ok") if status == "ok" else p.red(str(status))
            p.line(p.dim(f"  ▪ {data.get('node')} {mark}"))
        elif typ == "graph.wave.gates":
            verdict = "pass" if data.get("passed") else "fail"
            p.line(p.dim(f"  ~ wave {data.get('wave')} gates {verdict}"))
        elif typ == "space.lease_expired":
            p.line(p.yellow(f"  ! lease expired: {data.get('node')} [{data.get('worker')}]"))
        elif typ == "execution.trap":
            p.line(p.red(f"  ✗ trap {data.get('reason')}: {data.get('detail') or ''}"))
        elif typ == "preflight.rejected":
            pass  # kernel critic.rejected already renders the errors
        elif self.verbose and typ == "tool.call":
            p.line(p.dim(f"  · {data.get('tool')} {data.get('path') or ''}"))


def render_claims(claims: list[dict[str, Any]], notes: str, paint: Painter) -> None:
    p = paint
    if notes:
        p.line(p.dim(f'  "{notes.strip()[:300]}"'))
    for claim in claims:
        kind = str(claim.get("kind") or "source")
        cid = claim.get("id")
        if kind == "check":
            p.line(p.yellow(f"  ▢ {cid} [check] will EXECUTE: {claim.get('command')}"))
        elif kind == "absent":
            p.line(f"  ▢ {cid} [absent] {claim.get('path')}")
        elif kind == "file":
            p.line(f"  ▢ {cid} [file] {claim.get('path')}")
        else:
            needles = ", ".join(claim.get("any") or claim.get("must") or [])
            p.line(f"  ▢ {cid} [source] {claim.get('path') or '<workspace>'}: {needles}")


def negotiate_contract(
    goal: str,
    paint: Painter,
    args: argparse.Namespace,
    ask,
) -> tuple[Path, dict[str, Any]] | None:
    """Model drafts claims; the user amends and signs off. Returns the
    approved claims path + contract metadata, or None on skip."""
    p = paint
    workspace = Path(args.cwd).resolve()
    render = Renderer(p)
    prior: Any = None
    feedback = ""
    for round_no in range(1, 6):
        p.line(p.dim(f"… drafting claims (round {round_no}, model call)"))
        observation = {
            "mode": "claims",
            "goal": goal,
            "workspace": str(workspace),
            "prior_claims": prior,
            "feedback": feedback,
        }
        try:
            with live_sink(render.trace):
                result = call_planner_json(args.resolved_planner or _default_cmd(), observation, workspace=workspace)
        except CLIError as exc:
            p.line(p.red(f"claims draft failed: {exc}"))
            return None
        claims = result.get("claims") if isinstance(result.get("claims"), list) else []
        if not claims:
            p.line(p.red("planner proposed no claims"))
            return None
        p.line(p.bold("proposed contract:"))
        render_claims(claims, str(result.get("notes") or ""), p)
        answer = ask("contract> approve / skip / <feedback>: ")
        if answer is None:
            return None
        answer = answer.strip()
        if answer.lower() in {"a", "approve", "y", "yes"}:
            run_dir = Path(args.run_dir) if args.run_dir else workspace / ".livingdict-run"
            run_dir.mkdir(parents=True, exist_ok=True)
            path = run_dir / "claims.approved.json"
            body = json.dumps({"claims": claims}, indent=2, sort_keys=True) + "\n"
            path.write_text(body, encoding="utf-8")
            contract = {
                "claims": claims,
                "fingerprint": hashlib.sha256(body.encode("utf-8")).hexdigest(),
                "iterations": round_no,
            }
            p.line(p.green(f"✎ contract approved ({len(claims)} claims) → {path.name}"))
            return path, contract
        if answer.lower() in {"s", "skip"}:
            p.line(p.yellow("contract skipped — discharge will rely on model-authored claims"))
            return None
        prior = claims
        feedback = answer
    p.line(p.yellow("contract not approved after 5 rounds — skipping"))
    return None


def _default_cmd() -> list[str]:
    from .cli import default_planner_cmd

    return default_planner_cmd()


def run_goal(
    goal: str,
    paint: Painter,
    args: argparse.Namespace,
    claims_override: Path | None = None,
    contract: dict[str, Any] | None = None,
) -> int:
    render = Renderer(paint, verbose=bool(getattr(args, "verbose", False)))
    started = time.monotonic()
    try:
        with live_sink(render.trace):
            code, receipt = run_job(
                goal,
                args.cwd,
                max_turns=args.max_turns,
                claims=claims_override or args.claims,
                run_dir=args.run_dir,
                planner_cmd=args.resolved_planner,
                wave_workers=args.wave_workers,
                serial=args.serial,
                event_sink=render.kernel,
                print_receipt=False,
                contract=contract,
            )
    except (CLIError, EnvelopeError, KernelError) as exc:
        paint.line(paint.red(f"error: {exc}"))
        return 2
    elapsed = int((time.monotonic() - started) * 1000)
    changed = receipt.get("changed_files") or []
    verdict = receipt.get("decision")
    reason = receipt.get("reason")
    tail = f"{verdict}: {reason}  ({len(changed)} files, e{receipt.get('episodes')}, {elapsed}ms)"
    if code == 0:
        paint.line(paint.bold(paint.green(f"● {tail}")))
        if receipt.get("claims_source") == "workspace":
            paint.line(
                paint.yellow(
                    "  ⚠ discharged against MODEL-AUTHORED claims (substring checks it wrote"
                    " itself). Nothing was built, served, or tested. Pass --claims <file>"
                    " to judge against your own criteria."
                )
            )
    else:
        paint.line(paint.bold(paint.red(f"● {tail}")))
    return code


def build_tui_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="livingdict tui",
        description="line TUI over the livingdict loop; goals come from stdin",
    )
    parser.add_argument("--cwd", type=Path, default=Path("."), help="product workspace")
    parser.add_argument("--max-turns", type=int, default=8)
    parser.add_argument("--claims", type=Path, help="hidden claims.json used for discharge")
    parser.add_argument("--run-dir", type=Path, help="job state directory")
    parser.add_argument(
        "--planner-cmd",
        nargs="+",
        metavar="ARG",
        help="argv that reads observation JSON on stdin and writes envelope JSON on stdout",
    )
    parser.add_argument("--wave-workers", type=int, default=4)
    parser.add_argument("--serial", action="store_true")
    parser.add_argument("--no-color", dest="color", action="store_false", default=True)
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="also show program source, tool calls, and node detail",
    )
    contract = parser.add_mutually_exclusive_group()
    contract.add_argument(
        "--contract",
        action="store_true",
        help="negotiate claims before running even when stdin is a pipe",
    )
    contract.add_argument(
        "--no-contract",
        action="store_true",
        help="skip the claims sign-off pass",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_tui_parser().parse_args(argv)
    planner_cmd = list(args.planner_cmd) if args.planner_cmd else None
    if planner_cmd and len(planner_cmd) == 1:
        planner_cmd = shlex.split(planner_cmd[0])
    if planner_cmd:
        planner_cmd = resolve_argv_files(planner_cmd)
    args.resolved_planner = planner_cmd

    interactive = bool(getattr(sys.stdin, "isatty", lambda: False)())
    paint = Painter(sys.stdout, _want_color(sys.stdout, args.color))
    workspace = Path(args.cwd).resolve()
    paint.line(paint.dim(f"livingdict tui — workspace {workspace}"))
    if interactive:
        paint.line(paint.dim("type a goal; the model drafts claims for your sign-off first; /verbose, /quit"))

    def ask(prompt: str) -> str | None:
        if interactive:
            try:
                return input(paint.bold(prompt) if paint.color else prompt)
            except (EOFError, KeyboardInterrupt):
                return None
        raw = sys.stdin.readline()
        if raw == "":
            return None
        return raw.rstrip("\n")

    want_contract = not args.no_contract and (interactive or args.contract)

    last = 0
    while True:
        line = ask("goal> ")
        if line is None:
            if interactive:
                paint.line()
            return last
        goal = line.strip()
        if not goal:
            continue
        if goal in {"/quit", "/exit", "/q"}:
            return last
        if goal == "/verbose":
            args.verbose = not bool(getattr(args, "verbose", False))
            paint.line(paint.dim(f"verbose {'on' if args.verbose else 'off'}"))
            continue
        claims_override: Path | None = None
        contract: dict[str, Any] | None = None
        if want_contract and args.claims is None:
            agreed = negotiate_contract(goal, paint, args, ask)
            if agreed is not None:
                claims_override, contract = agreed
        last = run_goal(goal, paint, args, claims_override=claims_override, contract=contract)
        if not interactive and last != 0:
            return last
