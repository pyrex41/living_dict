#!/usr/bin/env python3
"""Metadata-first OpenAI-compatible forwarding proxy for planner diagnostics."""

from __future__ import annotations

import argparse
import hashlib
import json
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def digest(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def safe_json(body: bytes):
    try:
        return json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


class Recorder:
    def __init__(self, path: Path, capture_bodies: bool):
        self.path = path
        self.capture_bodies = capture_bodies
        self.lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, event: dict) -> None:
        line = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
        with self.lock, self.path.open("a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()


class Handler(BaseHTTPRequestHandler):
    server_version = "livingdict-flight-recorder/1"

    def do_POST(self):  # noqa: N802
        request_started = time.monotonic_ns()
        body = self.rfile.read(int(self.headers.get("content-length", "0")))
        parsed = safe_json(body)
        request_id = f"r{time.time_ns()}-{threading.get_ident()}"

        event = {
            "type": "llm.request",
            "timestamp": utc_now(),
            "request_id": request_id,
            "method": "POST",
            "path": self.path,
            "bytes": len(body),
            "sha256": digest(body),
            "model": parsed.get("model") if isinstance(parsed, dict) else None,
            "message_count": len(parsed.get("messages", [])) if isinstance(parsed, dict) else None,
            "prompt_chars": sum(
                len(str(message.get("content", "")))
                for message in parsed.get("messages", [])
                if isinstance(message, dict)
            ) if isinstance(parsed, dict) else None,
            "tool_count": len(parsed.get("tools", [])) if isinstance(parsed, dict) else None,
            "parameters": {
                key: parsed[key]
                for key in ("temperature", "top_p", "max_tokens", "reasoning_effort", "stream")
                if isinstance(parsed, dict) and key in parsed
            },
        }
        if self.server.recorder.capture_bodies:
            event["body"] = parsed if parsed is not None else body.decode("utf-8", "replace")
        self.server.recorder.write(event)

        upstream = self.server.upstream.rstrip("/") + self.path
        headers = {"content-type": self.headers.get("content-type", "application/json")}
        authorization = self.headers.get("authorization")
        if authorization:
            headers["authorization"] = authorization
        req = urllib.request.Request(upstream, data=body, headers=headers, method="POST")

        status = 502
        response_body = b""
        response_headers = {}
        headers_ns = None
        error = None
        try:
            with urllib.request.urlopen(req, timeout=self.server.timeout_seconds) as response:
                headers_ns = time.monotonic_ns()
                status = response.status
                response_body = response.read()
                response_headers = dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            headers_ns = time.monotonic_ns()
            status = exc.code
            response_body = exc.read()
            response_headers = dict(exc.headers.items()) if exc.headers else {}
        except Exception as exc:
            error = f"{type(exc).__name__}: {exc}"
            response_body = json.dumps({"error": "upstream transport failure"}).encode()

        finished_ns = time.monotonic_ns()
        response_json = safe_json(response_body)
        response_event = {
            "type": "llm.response",
            "timestamp": utc_now(),
            "request_id": request_id,
            "status": status,
            "bytes": len(response_body),
            "sha256": digest(response_body),
            "headers_ms": round((headers_ns - request_started) / 1_000_000, 3) if headers_ns else None,
            "total_ms": round((finished_ns - request_started) / 1_000_000, 3),
            "usage": response_json.get("usage") if isinstance(response_json, dict) else None,
            "choice_count": len(response_json.get("choices", [])) if isinstance(response_json, dict) else None,
            "error": error,
        }
        if self.server.recorder.capture_bodies:
            response_event["body"] = response_json if response_json is not None else response_body.decode("utf-8", "replace")
        self.server.recorder.write(response_event)

        self.send_response(status)
        self.send_header("content-type", response_headers.get("content-type", "application/json"))
        self.send_header("content-length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)

    def log_message(self, _format, *_args):
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0:8765")
    parser.add_argument("--upstream", default="https://api.x.ai")
    parser.add_argument("--log", default="/logs/llm.jsonl")
    parser.add_argument("--timeout-seconds", type=int, default=660)
    parser.add_argument("--capture-bodies", action="store_true")
    args = parser.parse_args()
    host, port = args.listen.rsplit(":", 1)
    server = ThreadingHTTPServer((host, int(port)), Handler)
    server.upstream = args.upstream
    server.timeout_seconds = args.timeout_seconds
    server.recorder = Recorder(Path(args.log), args.capture_bodies)
    server.serve_forever()


if __name__ == "__main__":
    main()
