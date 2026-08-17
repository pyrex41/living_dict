from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .discovery import discover_tasks, select_tasks
from .forthcheck import validate_straight_line
from .runner import run_suite
from .scoring import aggregate, compare, load_results


def _csv_set(value: str | None) -> set[str] | None:
    if not value:
        return None
    return {item.strip() for item in value.split(",") if item.strip()}


def _print(value: object) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ldeval", description="Living Dictionary harness benchmark")
    sub = parser.add_subparsers(dest="command", required=True)

    listing = sub.add_parser("list", help="list benchmark tasks")
    listing.add_argument("--family")
    listing.add_argument("--mechanism")
    listing.add_argument("--json", action="store_true")

    run = sub.add_parser("run", help="run one or more tasks")
    run.add_argument("--agent-command", help="adapter command; request.json is appended as the final argument")
    run.add_argument("--oracle", action="store_true", help="apply protected oracle solutions")
    run.add_argument("--arm", default="unlabeled")
    run.add_argument("--memory-mode", choices=["cold", "warm"], default="cold")
    run.add_argument("--tasks", help="comma-separated task IDs")
    run.add_argument("--families", help="comma-separated family names")
    run.add_argument("--mechanisms", help="comma-separated mechanism tags")
    run.add_argument("--output", type=Path, default=Path("runs"))
    run.add_argument("--inject-faults", action="store_true")
    run.add_argument("--discard-workspaces", action="store_true")

    score = sub.add_parser("score", help="aggregate result.json files")
    score.add_argument("path", type=Path)

    comp = sub.add_parser("compare", help="paired comparison of two result trees")
    comp.add_argument("left", type=Path)
    comp.add_argument("right", type=Path)

    forth = sub.add_parser("check-forth", help="validate a straight-line capability program")
    forth.add_argument("program")
    forth.add_argument("--allow", default="read,write,exec,model")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    tasks = discover_tasks()
    if args.command == "list":
        selected = select_tasks(tasks, families=_csv_set(args.family), mechanisms=_csv_set(args.mechanism))
        rows = [{
            "id": task.id,
            "family": task.family,
            "sequence": task.sequence,
            "title": task.title,
            "mechanisms": list(task.mechanisms),
        } for task in selected]
        if args.json:
            _print(rows)
        else:
            for row in rows:
                print(f"{row['id']:16} {row['family']:20} {row['title']}")
        return 0
    if args.command == "run":
        if bool(args.oracle) == bool(args.agent_command):
            raise SystemExit("choose exactly one of --oracle or --agent-command")
        selected = select_tasks(
            tasks,
            ids=_csv_set(args.tasks),
            families=_csv_set(args.families),
            mechanisms=_csv_set(args.mechanisms),
        )
        if not selected:
            raise SystemExit("no tasks selected")
        results = run_suite(
            selected, args.output, args.arm, args.agent_command, args.oracle,
            args.memory_mode, args.inject_faults, not args.discard_workspaces,
        )
        summary = aggregate([result.to_dict() for result in results])
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        _print(summary)
        return 0 if summary["overall"]["success_rate"] == 1.0 else 1
    if args.command == "score":
        _print(aggregate(load_results(args.path)))
        return 0
    if args.command == "compare":
        _print(compare(load_results(args.left), load_results(args.right)))
        return 0
    if args.command == "check-forth":
        _print(validate_straight_line(args.program, _csv_set(args.allow) or set()))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())

