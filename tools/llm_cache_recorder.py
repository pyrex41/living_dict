#!/usr/bin/env python3
"""Metadata-only reverse proxy for auditing LLM prompt-cache behavior.

Point a client base URL at this server and pass the real provider origin as
--upstream. The JSONL ledger stores hashes, sizes, roles, timing, and usage;
it never stores prompt text, tool payloads, authorization, or header values.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def request_metadata(body: bytes, headers: dict[str, str]) -> dict[str, Any]:
    try:
        payload = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = {}
    messages = payload.get("messages") if isinstance(payload, dict) else None
    tools = payload.get("tools") if isinstance(payload, dict) else None
    lowered = {key.lower(): value for key, value in headers.items()}
    affinity = lowered.get("x-grok-conv-id")
    rows: list[dict[str, Any]] = []
    if isinstance(messages, list):
        for message in messages:
            encoded = json.dumps(message, sort_keys=True, separators=(",", ":")).encode()
            rows.append(
                {
                    "role": message.get("role") if isinstance(message, dict) else None,
                    "bytes": len(encoded),
                    "sha256": sha256(encoded),
                }
            )
    tool_bytes = json.dumps(tools, sort_keys=True, separators=(",", ":")).encode()
    return {
        "request_bytes": len(body),
        "request_sha256": sha256(body),
        "model": payload.get("model") if isinstance(payload, dict) else None,
        "stream": bool(payload.get("stream")) if isinstance(payload, dict) else False,
        "tool_choice": payload.get("tool_choice") if isinstance(payload, dict) else None,
        "messages": rows,
        "tool_schema_bytes": len(tool_bytes) if tools is not None else 0,
        "tool_schema_sha256": sha256(tool_bytes) if tools is not None else None,
        "header_names": sorted(
            key.lower() for key in headers if key.lower() not in {"authorization", "host"}
        ),
        "has_x_grok_conv_id": affinity is not None,
        "routing_key_fingerprint": sha256(affinity.encode()) if affinity else None,
    }


def usage_from_bytes(data: bytes) -> dict[str, Any] | None:
    candidates: list[dict[str, Any]] = []
    try:
        value = json.loads(data)
        if isinstance(value, dict):
            candidates.append(value)
    except (UnicodeDecodeError, json.JSONDecodeError):
        for line in data.splitlines():
            if not line.startswith(b"data:"):
                continue
            raw = line[5:].strip()
            if raw == b"[DONE]":
                continue
            try:
                value = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(value, dict):
                candidates.append(value)
    for candidate in reversed(candidates):
        usage = candidate.get("usage")
        if isinstance(usage, dict) and usage:
            return usage
    return None


class Recorder(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream = ""
    ledger = Path("llm-cache.jsonl")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        size = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(size)
        metadata = request_metadata(body, dict(self.headers.items()))
        target = self.upstream.rstrip("/") + self.path
        forwarded = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_HEADERS and key.lower() != "content-length"
        }
        request = urllib.request.Request(target, data=body, headers=forwarded, method="POST")
        started = time.monotonic()
        first_byte_ms: int | None = None
        response_data = bytearray()
        try:
            response = urllib.request.urlopen(request, timeout=900)
        except urllib.error.HTTPError as error:
            response = error
        self.send_response(response.status)
        for key, value in response.headers.items():
            if key.lower() not in HOP_HEADERS and key.lower() != "content-length":
                self.send_header(key, value)
        self.send_header("Connection", "close")
        self.end_headers()
        while True:
            chunk = response.read(64 * 1024)
            if not chunk:
                break
            if first_byte_ms is None:
                first_byte_ms = round((time.monotonic() - started) * 1000)
            self.wfile.write(chunk)
            self.wfile.flush()
            if len(response_data) < 4 * 1024 * 1024:
                response_data.extend(chunk[: 4 * 1024 * 1024 - len(response_data)])
        record = {
            "timestamp_unix_ms": int(time.time() * 1000),
            "path": self.path,
            "status": response.status,
            "first_byte_ms": first_byte_ms,
            "duration_ms": round((time.monotonic() - started) * 1000),
            "response_sample_bytes": len(response_data),
            "usage": usage_from_bytes(bytes(response_data)),
            **metadata,
        }
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        with self.ledger.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        self.close_connection = True

    def log_message(self, _format: str, *_args: Any) -> None:
        return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="127.0.0.1:8765")
    parser.add_argument("--upstream", default="https://api.x.ai")
    parser.add_argument("--ledger", type=Path, required=True)
    args = parser.parse_args()
    host, port_text = args.listen.rsplit(":", 1)
    Recorder.upstream = args.upstream
    Recorder.ledger = args.ledger
    server = ThreadingHTTPServer((host, int(port_text)), Recorder)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
