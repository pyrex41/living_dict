#!/usr/bin/env python3
"""Turn-based Living Dictionary client. Talks to OpenResty /think.

Each turn is a goal. The host asks grok-4.6 (OAuth or XAI_API_KEY) for a
Forth envelope, then Shen checks it and Forth runs. /forth sends raw Forth.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

DEFAULT_BASE = "http://127.0.0.1:8080"


class ClientError(Exception):
    pass


DEFAULT_MAX_TURNS = int(os.environ.get("LIVINGDICT_MAX_TURNS", "32"))


class LivingDictClient:
    def __init__(self, base: str, timeout: float = 240.0) -> None:
        self.base = base.rstrip("/") + "/"
        self.timeout = timeout

    def get_json(self, path: str) -> dict[str, Any]:
        return self._request("GET", path, None)

    def think(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        return self._request_status("POST", "think", payload)

    def health(self) -> dict[str, Any]:
        return self.get_json("health")

    def _request(self, method: str, path: str, payload: dict[str, Any] | None) -> dict[str, Any]:
        _, body = self._request_status(method, path, payload)
        return body

    def _request_status(
        self, method: str, path: str, payload: dict[str, Any] | None
    ) -> tuple[int, dict[str, Any]]:
        url = urljoin(self.base, path)
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8")
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            status = exc.code
        except urllib.error.URLError as exc:
            raise ClientError(f"cannot reach {url}: {exc.reason}") from exc
        try:
            body = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            body = {"ok": False, "error": raw[:500], "raw": True}
        if not isinstance(body, dict):
            body = {"ok": False, "error": "response was not an object"}
        return status, body


def envelope_from_forth(program: str, artifacts: dict[str, str] | None = None) -> dict[str, Any]:
    text = program.strip()
    if not text:
        raise ClientError("empty program")
    return {
        "language": "forth",
        "program": text,
        "artifacts": artifacts or {},
        "rationale": "",
    }


def load_envelope(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ClientError(f"bad envelope {path}: {exc}") from exc
    if not isinstance(payload, dict) or "program" not in payload:
        raise ClientError("envelope must be an object with a program field")
    payload.setdefault("language", "forth")
    payload.setdefault("artifacts", {})
    payload.setdefault("rationale", "")
    return payload


def claims_discharged(check: Any) -> bool:
    if not isinstance(check, dict):
        return False
    gates = check.get("gates")
    if not isinstance(gates, list) or not gates:
        return False
    claims = [gate for gate in gates if gate.get("name") == "claims"]
    if not claims or any(not gate.get("passed") for gate in claims):
        return False
    for gate in gates:
        if gate.get("name") == "look" and not gate.get("skipped") and not gate.get("passed"):
            return False
    return True


def format_turn(status: int, body: dict[str, Any]) -> str:
    lines: list[str] = []
    critic = body.get("critic") or "?"
    rejected = critic == "reject" or not (bool(body.get("ok")) and status < 400)
    stamp = "REJECT" if rejected else "ACCEPT"
    phase = body.get("phase")
    lines.append(f"{stamp}  http {status}  critic={critic}" + (f"  {phase}" if phase else ""))
    plan = body.get("plan") or {}
    if isinstance(plan, dict):
        if plan.get("rationale"):
            lines.append(f"  plan     {plan['rationale']}")
        artifacts = plan.get("artifacts") or {}
        if isinstance(artifacts, dict) and artifacts:
            lines.append("  artifacts " + ", ".join(sorted(artifacts)))
        if plan.get("program"):
            prog = str(plan["program"]).replace("\n", " / ")
            if len(prog) > 240:
                prog = prog[:237] + "..."
            lines.append(f"  forth    {prog}")
        if plan.get("model"):
            lines.append(f"  model    {plan['model']}" + (f"  {plan.get('auth')}" if plan.get("auth") else ""))
    if body.get("error"):
        lines.append(f"  {body['error']}")
    details = body.get("errors") or body.get("details") or []
    if isinstance(details, list):
        for item in details[:12]:
            lines.append(f"  {item}")
    result = body.get("result") or {}
    if isinstance(result, dict) and result.get("stack_depth") is not None:
        lines.append(f"  stack_depth {result['stack_depth']}")
    if isinstance(result, dict) and result.get("defined"):
        lines.append("  words     " + " ".join(str(x) for x in result["defined"]))
    if body.get("workspace"):
        lines.append(f"  product   {body['workspace']}")
    receipt = body.get("receipt") or {}
    if isinstance(receipt, dict):
        changed = receipt.get("changed_files") or []
        if changed:
            lines.append("  changed  " + ", ".join(str(x) for x in changed))
        violations = receipt.get("policy_violations") or []
        if violations:
            lines.append("  policy   " + "; ".join(str(x) for x in violations))
    return "\n".join(lines)


HELP = """\
turns
  <goal>            plan + run episodes until claims discharge or cap
  /forth <program>  skip the planner; one Forth program
  /load FILE.json   send a canned envelope
  /paste            multiline Forth until a lone '.'
  /health           GET /health
  /help             this text
  /quit             leave

Auth: grok login --oauth  (reads ~/.grok/auth.json)  or  XAI_API_KEY
Shen still rejects bad plans before any write.
"""


def ensure_receipt(program: str) -> str:
    if "RECEIPT" in program.upper().split():
        return program
    return program.rstrip() + " RECEIPT"


def repl(client: LivingDictClient) -> int:
    try:
        health = client.health()
        print(
            f"livingdict  {client.base}  "
            f"critic={health.get('critic')} shen={health.get('shen')}"
        )
        if health.get("workspace"):
            print(f"product     {health.get('workspace')}")
    except ClientError as exc:
        print(f"livingdict  {client.base}")
        print(f"offline     {exc}")
        print("start the host with:  make openresty-serve")
        return 2
    print("one goal, as many Forth episodes as it needs.  /help")
    paste: list[str] | None = None
    while True:
        try:
            prompt = "... " if paste is not None else ". "
            line = input(prompt)
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if paste is not None:
            if line.strip() == ".":
                program = "\n".join(paste)
                paste = None
                if not program.strip():
                    print("  empty paste")
                    continue
                _run_forth(client, program)
            else:
                paste.append(line)
            continue
        text = line.strip()
        if not text:
            continue
        if text in {"/quit", "/q", "/exit"}:
            return 0
        if text in {"/help", "/h", "?"}:
            print(HELP)
            continue
        if text == "/health":
            try:
                print(json.dumps(client.health(), indent=2, sort_keys=True))
            except ClientError as exc:
                print(f"  {exc}")
            continue
        if text == "/paste":
            paste = []
            print("  paste Forth, end with a line that is only .")
            continue
        if text.startswith("/forth"):
            parts = text.split(maxsplit=1)
            if len(parts) < 2:
                print("  usage: /forth PROGRAM")
                continue
            _run_forth(client, parts[1])
            continue
        if text.startswith("/load"):
            parts = text.split(maxsplit=1)
            if len(parts) < 2:
                print("  usage: /load FILE.json")
                continue
            try:
                env = load_envelope(Path(parts[1]).expanduser())
                status, body = client.think(env)
                print(format_turn(status, body))
            except (ClientError, OSError) as exc:
                print(f"  {exc}")
            continue
        if text.startswith("/"):
            print(f"  unknown command {text.split()[0]}  (/help)")
            continue
        _run_goal(client, text)


def _critic_extra(body: dict[str, Any]) -> str:
    errors = body.get("errors") or body.get("details") or []
    bits: list[str] = []
    if isinstance(errors, list):
        bits.extend(f"critic: {item}" for item in errors)
    elif body.get("critic") == "reject" and body.get("error"):
        bits.append(f"critic: {body['error']}")
    receipt = body.get("receipt") if isinstance(body.get("receipt"), dict) else {}
    check = receipt.get("check") if isinstance(receipt, dict) else None
    if isinstance(check, dict) and not check.get("passed"):
        bits.append(f"gates: {check.get('stderr') or 'not discharged'}")
    return "\n".join(bits)


def _run_goal(client: LivingDictClient, goal: str, *, max_turns: int = DEFAULT_MAX_TURNS) -> int:
    extra = ""
    last_ok = False
    for episode in range(1, max_turns + 1):
        try:
            status, body = client.think({"extra": extra, "goal": goal, "episode": episode})
        except ClientError as exc:
            print(f"  {exc}")
            return 2
        print(f"episode {episode}")
        print(format_turn(status, body))
        last_ok = bool(body.get("ok")) and status < 400 and body.get("critic") != "reject"
        receipt = body.get("receipt") if isinstance(body.get("receipt"), dict) else {}
        check = receipt.get("check") if isinstance(receipt, dict) else None
        if claims_discharged(check):
            return 0
        extra = _critic_extra(body)
    return 0 if last_ok else 2


def _run_forth(client: LivingDictClient, program: str) -> None:
    try:
        env = envelope_from_forth(ensure_receipt(program))
        status, body = client.think(env)
        print(format_turn(status, body))
    except ClientError as exc:
        print(f"  {exc}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Turn-based client for the Living Dictionary host")
    parser.add_argument("--base", default=DEFAULT_BASE, help=f"host URL (default {DEFAULT_BASE})")
    parser.add_argument("-e", "--eval", dest="program", help="send one Forth program and exit")
    parser.add_argument("-g", "--goal", help="plan with grok-4.6 then /think")
    parser.add_argument("--load", type=Path, help="send one envelope JSON and exit")
    parser.add_argument("--health", action="store_true", help="print /health and exit")
    args = parser.parse_args(argv)
    client = LivingDictClient(args.base)
    if args.health:
        print(json.dumps(client.health(), indent=2, sort_keys=True))
        return 0
    if args.load is not None:
        env = load_envelope(args.load)
        status, body = client.think(env)
        print(format_turn(status, body))
        return 0 if body.get("ok") and status < 400 else 2
    if args.goal is not None:
        return _run_goal(client, args.goal)
    if args.program is not None:
        env = envelope_from_forth(ensure_receipt(args.program))
        status, body = client.think(env)
        print(format_turn(status, body))
        return 0 if body.get("ok") and status < 400 else 2
    return repl(client)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ClientError as exc:
        print(exc, file=sys.stderr)
        raise SystemExit(2) from exc
