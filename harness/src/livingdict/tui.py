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

from .cli import CLIError, resolve_argv_files, run_job
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

    def __init__(self, paint: Painter) -> None:
        self.paint = paint
        self.episode = 0

    def kernel(self, kind: str, payload: dict[str, Any]) -> None:
        p = self.paint
        if kind == "episode.planned":
            self.episode += 1
            keys = ",".join(payload.get("artifact_keys") or []) or "-"
            fp = str(payload.get("fingerprint") or "")[:8]
            p.line(p.dim(f"∙ e{self.episode} plan  fp={fp}  artifacts={keys}"))
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
            p.line(f"⚖ gates {verdict}  ({', '.join(str(n) for n in names) or 'none'})")
        elif kind == "dictionary.promoted":
            p.line(p.dim(f"※ word {payload.get('word')} promoted"))

    def trace(self, event: dict[str, Any]) -> None:
        p = self.paint
        typ = event.get("type") or ""
        data = event.get("data") or {}
        if typ == "planner.call":
            p.line(p.dim(f"… planning e{data.get('episode')} (model call)"))
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


def run_goal(goal: str, paint: Painter, args: argparse.Namespace) -> int:
    render = Renderer(paint)
    started = time.monotonic()
    try:
        with live_sink(render.trace):
            code, receipt = run_job(
                goal,
                args.cwd,
                max_turns=args.max_turns,
                claims=args.claims,
                run_dir=args.run_dir,
                planner_cmd=args.resolved_planner,
                wave_workers=args.wave_workers,
                serial=args.serial,
                event_sink=render.kernel,
                print_receipt=False,
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
        paint.line(paint.dim("type a goal; /quit to exit"))

    last = 0
    while True:
        if interactive:
            try:
                line = input(paint.bold("goal> ") if paint.color else "goal> ")
            except (EOFError, KeyboardInterrupt):
                paint.line()
                return last
        else:
            raw = sys.stdin.readline()
            if raw == "":
                return last
            line = raw.rstrip("\n")
        goal = line.strip()
        if not goal:
            continue
        if goal in {"/quit", "/exit", "/q"}:
            return last
        last = run_goal(goal, paint, args)
        if not interactive and last != 0:
            return last
