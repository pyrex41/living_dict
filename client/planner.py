#!/usr/bin/env python3
"""Grok 4.6 planner: goal + observation → plan envelope.

Auth (highest wins):
  1. XAI_API_KEY
  2. SpaceXAI OAuth session in ~/.grok/auth.json (grok login --oauth)
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from job import ensure_job_files


MODEL = os.environ.get("LIVINGDICT_MODEL", "grok-4.6")
API_BASE = os.environ.get("LIVINGDICT_API_BASE", "https://api.x.ai/v1")
TOKEN_URL = "https://auth.x.ai/oauth2/token"
AUTH_PATH = Path(os.environ.get("GROK_HOME", Path.home() / ".grok")) / "auth.json"

CLAIMS_SYSTEM = """You draft ACCEPTANCE CLAIMS for a coding goal. The user
will review them, push back, and sign off before any work starts; after
sign-off they become the frozen judge of success — you cannot weaken them
later. Emit exactly one JSON object, no markdown:
{"claims": [ ... ], "notes": "<one short paragraph for the reviewer>"}

Claim kinds, strongest first:
- {"id", "kind": "check", "command": "<sh command run in the workspace>",
   "timeout_seconds": 60} — passes iff exit 0. PREFER these: build it,
   run its tests, start it and curl it. Only use tools that exist on the
   machine or that one of your own claims installs first.
- {"id", "kind": "source", "path", "any": ["needle", ...], "min_bytes": N}
   — substring evidence in one file. Weak; use for structure only.
- {"id", "kind": "file", "path", "min_bytes": N} — existence.
- {"id", "kind": "absent", "path"} — must not exist.

3 to 8 claims. Cover behavior, not just file presence. If FEEDBACK is
given, incorporate it exactly; if PRIOR CLAIMS are given, revise them
rather than starting over.
"""

SYSTEM = """You are the planner for a general coding harness (Codex/Claude
Code class) whose plan language is Forth. Forth is the harness, not
the product. The product is whatever the GOAL names — any software.

You write a Forth program. It may:
  (1) define colon words (skills) that persist in the dictionary;
  (2) write the PRODUCT with host words.

Emit ONE JSON object only (no markdown) with keys:
  language: "forth"
  program: Forth using only host words, colon words you define here, and
    colon words already listed under HARNESS dictionary:
      READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES RECEIPT USE-ARTIFACT
      DUP DROP SWAP OVER + - * : ; IF ELSE THEN
      S" strings and integers
  artifacts: map of PRODUCT paths to FULL file contents
  rationale: one short sentence about THIS episode
  nodes: optional [{id, writes, depends_on, program}]. When present,
    top-level program may be empty; host runs node programs in Kahn
    order (lexicographic tiebreak). Example:
    [{"id":"ingest","writes":["pipeline/ingest.py"],"depends_on":[],
      "program":"RECEIPT"}]

Rules:
- Follow the GOAL. Never substitute an eval fixture (app/config.py) or
  assume a stack (Python, Solid, Three, a game engine).
- Implement ONE increment — the next missing piece.
- Do not emit a program that only reads files and writes a RECEIPT.
  Leftover product from an earlier job is not this goal being done.
- FIRST episode (or whenever claims.json is missing): write claims.json
  that states how THIS goal is done. The claims are the model's acceptance
  criteria, not a changelog. Include at least one executable behavioral
  check, for example:
    {"claims":[{"id":"tests","kind":"check","command":"python -m pytest -q","timeout_seconds":120}]}
  A behavior-oriented goal (run, execute, output, serve, HTTP/API, render,
  sample, or similar) MUST include a check that invokes the product and
  asserts an observable result. A compile command, `test -x`, source grep, or
  file-size check is structural evidence only and is insufficient. If no test
  runner exists, write a deterministic smoke command as part of this episode
  and assert its output or exit behavior. Source/file/absent claims are
  supplementary evidence only; a set without a behavioral check is incomplete
  and will be sent back for repair in benchmark mode.
  Each real feature claim MUST name a source path that is not index.html.
  A title tag is not a product. Claims are derived from the GOAL.
- Then write product files for this increment only.
- After sources exist, RUN-GATES. Structural green is not success.
  Failed claims are backpressure — keep going.
- Never weaken claims to make them pass. Grow the product until they pass.
- Do not write .livingdict-run/**, .git/**, node_modules/**, dist/**.
- End the program with RECEIPT.
"""


class PlannerError(Exception):
    pass


def extract_json_object(text: str) -> dict[str, Any]:
    raw = text.strip()
    if raw.startswith("```"):
        lines = raw.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        raw = "\n".join(lines).strip()
    try:
        value = json.loads(raw)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass
    start, end = raw.find("{"), raw.rfind("}")
    if start >= 0 and end > start:
        value = json.loads(raw[start : end + 1])
        if isinstance(value, dict):
            return value
    raise PlannerError("model did not return a JSON object")


def _normalize_nodes(value: Any) -> list[dict[str, Any]] | None:
    if value is None:
        return None
    if not isinstance(value, list):
        raise PlannerError("envelope.nodes must be an array")
    if not value:
        return None
    nodes: list[dict[str, Any]] = []
    for index, raw in enumerate(value):
        if not isinstance(raw, dict):
            raise PlannerError(f"envelope.nodes[{index}] must be an object")
        ident = raw.get("id")
        if not isinstance(ident, str) or not ident.strip():
            raise PlannerError(f"envelope.nodes[{index}].id must be a string")
        writes = raw.get("writes") or []
        if not isinstance(writes, list) or not all(isinstance(item, str) for item in writes):
            raise PlannerError(f"envelope.nodes[{index}].writes must be an array of strings")
        deps = raw.get("depends_on") or []
        if not isinstance(deps, list) or not all(isinstance(item, str) for item in deps):
            raise PlannerError(f"envelope.nodes[{index}].depends_on must be an array of strings")
        program = raw.get("program")
        if program is None:
            program = ""
        if not isinstance(program, str):
            raise PlannerError(f"envelope.nodes[{index}].program must be a string")
        item: dict[str, Any] = {
            "id": ident,
            "writes": list(writes),
            "depends_on": list(deps),
            "program": program,
        }
        if "allowed_globs" in raw:
            allowed = raw.get("allowed_globs")
            if not isinstance(allowed, list) or not all(isinstance(entry, str) for entry in allowed):
                raise PlannerError(
                    f"envelope.nodes[{index}].allowed_globs must be an array of strings"
                )
            item["allowed_globs"] = list(allowed)
        nodes.append(item)
    return nodes


def normalize_envelope(value: dict[str, Any]) -> dict[str, Any]:
    nodes = _normalize_nodes(value.get("nodes"))
    program = value.get("program")
    if program is None and nodes:
        program = ""
    if not isinstance(program, str):
        raise PlannerError("envelope.program missing")
    if not program.strip() and not nodes:
        raise PlannerError("envelope.program missing")
    artifacts = value.get("artifacts") or {}
    if not isinstance(artifacts, dict):
        raise PlannerError("envelope.artifacts must be an object")
    cleaned: dict[str, str] = {}
    for key, text in artifacts.items():
        if not isinstance(key, str) or not isinstance(text, str):
            raise PlannerError("artifact keys and values must be strings")
        cleaned[key] = text
    rationale = value.get("rationale") or ""
    if not isinstance(rationale, str):
        rationale = str(rationale)
    payload = {
        "language": "forth",
        "program": program,
        "artifacts": cleaned,
        "rationale": rationale,
    }
    if nodes:
        payload["nodes"] = nodes
    return payload


def observe_graph(root: Path, limit: int = 20_000) -> str:
    path = Path(root) / "task_graph.json"
    if not path.is_file():
        return ""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    if len(text) > limit:
        return text[:limit] + "\n…(truncated)"
    return text


def observe_workspace(root: Path, limit: int = 80_000) -> str:
    if not root.is_dir():
        return f"(no workspace at {root})"
    chunks: list[str] = []
    used = 0
    skip = {".git", "__pycache__", ".livingdict-run", "node_modules", "dist", "build", ".vite", ".sb"}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in skip for part in path.parts):
            continue
        if path.suffix in {".pyc", ".pyo", ".bin"}:
            continue
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        piece = f"--- {rel} ---\n{text}"
        if used + len(piece) > limit:
            chunks.append(f"--- {rel} --- (truncated, {len(text)} bytes)")
            break
        chunks.append(piece)
        used += len(piece)
    return "\n".join(chunks) if chunks else "(empty product workspace)"


def observe_discharge(workspace: Path, limit: int = 12_000) -> str:
    path = Path(workspace) / ".sb" / "discharge_report.json"
    if not path.is_file():
        return "(no discharge report — after sources exist, RUN-GATES)"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return "(unreadable discharge report)"
    if len(text) > limit:
        return text[:limit] + "\n…(truncated)"
    return text


def observe_dictionary(root: Path | None, limit: int = 20_000) -> str:
    if root is None:
        return "(no harness dictionary)"
    words = root / "words" if root.name != "words" else root
    if not words.is_dir():
        return "(empty dictionary — define colon words in this program to grow the harness)"
    chunks: list[str] = []
    used = 0
    for path in sorted(words.glob("*.fs")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        piece = f"--- {path.name} ---\n{text}"
        if used + len(piece) > limit:
            chunks.append(f"--- {path.name} --- (truncated)")
            break
        chunks.append(piece)
        used += len(piece)
    return "\n".join(chunks) if chunks else "(empty dictionary — define colon words in this program to grow the harness)"


def _parse_expires(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _oauth_record() -> tuple[Path, str, dict[str, Any]] | None:
    if not AUTH_PATH.is_file():
        return None
    try:
        blob = json.loads(AUTH_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(blob, dict):
        return None
    for rec_key, rec in blob.items():
        if isinstance(rec, dict) and rec.get("key") and rec.get("refresh_token"):
            return AUTH_PATH, rec_key, rec
    return None


def _refresh_oauth(path: Path, rec_key: str, rec: dict[str, Any]) -> str:
    client_id = rec.get("oidc_client_id")
    refresh = rec.get("refresh_token")
    if not client_id or not refresh:
        raise PlannerError("oauth session is missing refresh_token; run: grok login --oauth")
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": client_id,
        }
    ).encode("ascii")
    req = urllib.request.Request(
        TOKEN_URL,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise PlannerError(
            f"oauth refresh failed ({exc.code}); run: grok login --oauth"
        ) from exc
    access = payload.get("access_token")
    if not isinstance(access, str) or not access:
        raise PlannerError("oauth refresh returned no access_token")
    rec = dict(rec)
    rec["key"] = access
    if payload.get("refresh_token"):
        rec["refresh_token"] = payload["refresh_token"]
    expires_in = payload.get("expires_in")
    if isinstance(expires_in, (int, float)):
        rec["expires_at"] = datetime.fromtimestamp(
            datetime.now(timezone.utc).timestamp() + float(expires_in),
            tz=timezone.utc,
        ).isoformat().replace("+00:00", "Z")
    blob = json.loads(path.read_text(encoding="utf-8"))
    blob[rec_key] = rec
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(blob, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    tmp.replace(path)
    return access


def bearer_token() -> tuple[str, str]:
    env = os.environ.get("XAI_API_KEY", "").strip()
    if env:
        return env, "api_key"
    found = _oauth_record()
    if not found:
        raise PlannerError(
            "no planner credentials: export XAI_API_KEY or run: grok login --oauth"
        )
    path, rec_key, rec = found
    token = str(rec["key"])
    expires = _parse_expires(rec.get("expires_at") if isinstance(rec.get("expires_at"), str) else None)
    now = datetime.now(timezone.utc)
    if expires is not None and expires <= now:
        token = _refresh_oauth(path, rec_key, rec)
    return token, "oauth"


def _chat_request(payload: dict[str, Any], token: str) -> urllib.request.Request:
    return urllib.request.Request(
        f"{API_BASE.rstrip('/')}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )


def _open_chat(payload: dict[str, Any], token: str, source: str):
    try:
        return urllib.request.urlopen(_chat_request(payload, token), timeout=180)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:400]
        if exc.code == 401 and source == "oauth":
            found = _oauth_record()
            if found:
                path, rec_key, rec = found
                token = _refresh_oauth(path, rec_key, rec)
                return urllib.request.urlopen(_chat_request(payload, token), timeout=180)
            raise PlannerError(f"xAI 401: {detail}") from exc
        raise PlannerError(f"xAI HTTP {exc.code}: {detail}") from exc


def parse_stream_chunk(chunk: dict[str, Any]) -> tuple[str, str, dict[str, Any]]:
    """One SSE chunk -> (content delta, reasoning delta, usage-or-empty)."""
    usage = chunk.get("usage") or {}
    content = ""
    reasoning = ""
    for choice in chunk.get("choices") or []:
        delta = choice.get("delta") or {}
        content += delta.get("content") or ""
        reasoning += delta.get("reasoning_content") or ""
    return content, reasoning, usage


def _consume_stream(resp) -> tuple[str, dict[str, Any]]:
    """Read SSE; echo reasoning to stderr live, accumulate the envelope.

    stdout stays pure JSON — everything the model 'thinks' goes to stderr,
    which the harness forwards to the TUI as planner.stderr lines.
    """
    content: list[str] = []
    usage: dict[str, Any] = {}
    column = 0
    said_thinking = False
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").strip() if isinstance(raw, bytes) else str(raw).strip()
        if not line.startswith("data:"):
            continue
        body = line[5:].strip()
        if body == "[DONE]":
            break
        try:
            chunk = json.loads(body)
        except json.JSONDecodeError:
            continue
        delta_content, delta_reasoning, chunk_usage = parse_stream_chunk(chunk)
        if chunk_usage:
            usage = chunk_usage
        if delta_reasoning:
            if not said_thinking:
                sys.stderr.write("thinking:\n")
                said_thinking = True
            sys.stderr.write(delta_reasoning)
            if "\n" in delta_reasoning:
                column = len(delta_reasoning) - delta_reasoning.rfind("\n") - 1
            else:
                column += len(delta_reasoning)
            if column > 160 and delta_reasoning.endswith((" ", ".", ",")):
                sys.stderr.write("\n")
                column = 0
            sys.stderr.flush()
        if delta_content:
            content.append(delta_content)
    if said_thinking and column:
        sys.stderr.write("\n")
    sys.stderr.write(f"envelope: {sum(len(part) for part in content)} chars\n")
    sys.stderr.flush()
    return "".join(content), usage


def complete_json(system: str, user: str) -> tuple[dict[str, Any], dict[str, int]]:
    token, source = bearer_token()
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "response_format": {"type": "json_object"},
        "reasoning_effort": os.environ.get("LIVINGDICT_REASONING", "low"),
    }
    stream = os.environ.get("LIVINGDICT_STREAM", "1") != "0"
    if stream:
        payload["stream"] = True
        payload["stream_options"] = {"include_usage": True}
    resp = _open_chat(payload, token, source)
    if stream:
        with resp:
            content, usage = _consume_stream(resp)
    else:
        with resp:
            raw = json.loads(resp.read().decode("utf-8"))
        choices = raw.get("choices") or []
        if not choices:
            raise PlannerError("xAI returned no choices")
        content = choices[0].get("message", {}).get("content") or ""
        usage = raw.get("usage") or {}
    if not content:
        raise PlannerError("xAI returned no content")
    telemetry = {
        "input_tokens": int(usage.get("prompt_tokens") or 0),
        "output_tokens": int(usage.get("completion_tokens") or 0),
        "model": MODEL,
        "auth": source,
    }
    return extract_json_object(content), telemetry


def plan(
    goal: str,
    workspace: Path,
    extra: str = "",
    dictionary: Path | None = None,
    episode: int = 1,
    run_dir: Path | None = None,
) -> tuple[dict[str, Any], dict[str, int]]:
    goal = goal.strip()
    if not goal:
        raise PlannerError("empty goal")
    workspace = Path(workspace)
    job_root = Path(run_dir) if run_dir is not None else workspace
    ensure_job_files(job_root, goal, episode)
    observation = observe_workspace(workspace)
    user = (
        f"GOAL:\n{goal}\n\n"
        f"PRODUCT workspace {workspace}:\n{observation}\n\n"
        f"HARNESS dictionary {dictionary or '(none)'}:\n{observe_dictionary(dictionary)}\n\n"
        f"BACKPRESSURE discharge {workspace / '.sb' / 'discharge_report.json'}:\n"
        f"{observe_discharge(workspace)}"
    )
    graph = observe_graph(workspace)
    if graph:
        user += f"\n\nTASK GRAPH task_graph.json:\n{graph}"
    if run_dir is not None:
        user += f"\n\nJOB (run dir, not product) {run_dir}:\n{observe_workspace(Path(run_dir))}"
    if extra:
        user += f"\n\nCONSTRAINTS:\n{extra}"
    raw, telemetry = complete_json(SYSTEM, user)
    envelope = normalize_envelope(raw)
    return envelope, telemetry


def draft_claims(goal: str, workspace: Path, prior: Any = None, feedback: str = "") -> dict[str, Any]:
    """Contract pass: propose acceptance claims for user sign-off."""
    listing = observe_workspace(workspace, limit=8_000)
    user = [f"GOAL: {goal}", "", "WORKSPACE:", listing]
    if prior:
        user += ["", "PRIOR CLAIMS:", json.dumps(prior, ensure_ascii=False)]
    if feedback:
        user += ["", "FEEDBACK:", feedback]
    result, telemetry = complete_json(CLAIMS_SYSTEM, "\n".join(user))
    claims = result.get("claims")
    if not isinstance(claims, list) or not claims:
        raise PlannerError("claims draft has no claims[]")
    result["_telemetry"] = telemetry
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Living Dictionary Grok 4.6 planner")
    parser.add_argument("--goal", help="natural-language goal")
    parser.add_argument("--workspace", type=Path, default=Path("."))
    parser.add_argument("--stdin", action="store_true", help="read {goal, extra} JSON from stdin")
    args = parser.parse_args(argv)
    extra = ""
    goal = args.goal or ""
    dictionary: Path | None = None
    if args.stdin:
        payload = json.loads(sys.stdin.read() or "{}")
        if payload.get("mode") == "claims":
            ws = Path(str(payload.get("workspace") or "."))
            result = draft_claims(
                str(payload.get("goal") or ""),
                ws,
                prior=payload.get("prior_claims"),
                feedback=str(payload.get("feedback") or ""),
            )
            print(json.dumps(result, indent=2, sort_keys=True))
            return 0
        goal = str(payload.get("goal") or goal)
        extra = str(payload.get("extra") or "")
        ws = payload.get("workspace")
        if ws:
            args.workspace = Path(ws)
        raw_dict = payload.get("dictionary")
        if raw_dict:
            dictionary = Path(str(raw_dict))
        try:
            episode = int(payload.get("episode") or 1)
        except (TypeError, ValueError):
            episode = 1
        raw_run = payload.get("run_dir")
        run_dir = Path(str(raw_run)) if raw_run else None
    else:
        episode = 1
        run_dir = None
    envelope, telemetry = plan(goal, args.workspace, extra, dictionary, episode, run_dir)
    envelope["_telemetry"] = telemetry
    print(json.dumps(envelope, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PlannerError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        raise SystemExit(2) from exc
