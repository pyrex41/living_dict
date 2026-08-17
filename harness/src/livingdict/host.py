"""Shared capability host: the only I/O a Living Dictionary arm may perform."""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .check import detect_check, run_workspace_check
from .gates import run_gates as measure_gates
from .policy import PathPolicy, changed_files, snapshot, workspace_digest
from .receipts import write_receipt
from .trace import emit, make_event
from .wave import METRIC_KEYS


class CapabilityError(Exception):
    """Typed trap. `code` is stable; arms and traces should key off it."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    def as_dict(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}


@dataclass
class CapabilityHost:
    workspace: Path
    allowed_effects: tuple[str, ...]
    allowed_globs: tuple[str, ...]
    forbidden_globs: tuple[str, ...]
    trace_path: Path | None = None
    receipt_path: Path | None = None
    run_id: str = ""
    task_id: str = ""
    test_timeout_seconds: int = 60
    node_start_hook: Callable[[str], None] | None = None
    _policy: PathPolicy = field(init=False, repr=False)
    _before: dict[str, str] = field(init=False, repr=False)
    _effects_used: set[str] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        self.workspace = Path(self.workspace).resolve()
        if not self.workspace.is_dir():
            raise CapabilityError("workspace", f"workspace is not a directory: {self.workspace}")
        self.allowed_effects = tuple(self.allowed_effects)
        self.allowed_globs = tuple(self.allowed_globs)
        self.forbidden_globs = tuple(self.forbidden_globs)
        if self.trace_path is not None:
            self.trace_path = Path(self.trace_path)
        if self.receipt_path is not None:
            self.receipt_path = Path(self.receipt_path)
        self._policy = PathPolicy(self.workspace, self.allowed_globs, self.forbidden_globs)
        self._before = snapshot(self.workspace)
        self._effects_used = set()
        self._last_check: dict[str, Any] | None = None
        self._event_sink: list[dict[str, Any]] | None = None
        self._write_receipt = True
        self._outer_policy: PathPolicy | None = None
        self.graph_metrics: dict[str, Any] = {}

    @classmethod
    def from_request(cls, request: dict[str, Any]) -> CapabilityHost:
        task = request["task"]
        return cls(
            workspace=Path(request["workspace"]),
            allowed_effects=tuple(task.get("allowed_effects", ("read", "write", "exec"))),
            allowed_globs=tuple(task["allowed_globs"]),
            forbidden_globs=tuple(task.get("forbidden_globs", ())),
            trace_path=Path(request["trace_path"]),
            receipt_path=Path(request["receipt_path"]),
            run_id=str(request.get("run_id", "")),
            task_id=str(task.get("id", "")),
        )

    def node_view(
        self,
        write_globs: tuple[str, ...] | list[str],
        extra_forbidden: tuple[str, ...] | list[str] = (),
    ) -> CapabilityHost:
        """Isolated host for one graph node. Shares the workspace, not mutable run state.

        `extra_forbidden` is sibling write-sets in the same wave so a doctored
        overlapping plan is still refused by PathPolicy (no partial mutation).
        """
        view = object.__new__(CapabilityHost)
        view.workspace = self.workspace
        view.allowed_effects = self.allowed_effects
        view.allowed_globs = tuple(write_globs)
        view.forbidden_globs = tuple(self.forbidden_globs) + tuple(extra_forbidden)
        view.trace_path = self.trace_path
        view.receipt_path = self.receipt_path
        view.run_id = self.run_id
        view.task_id = self.task_id
        view.test_timeout_seconds = self.test_timeout_seconds
        view.node_start_hook = None
        view._policy = PathPolicy(self.workspace, view.allowed_globs, view.forbidden_globs)
        view._before = self._before
        view._effects_used = set()
        view._last_check = None
        view._event_sink = []
        view._write_receipt = False
        view._outer_policy = self._outer_policy or self._policy
        view.graph_metrics = {}
        return view

    def emit_event(self, event_type: str, data: dict[str, Any] | None = None) -> None:
        if self._event_sink is not None:
            self._event_sink.append(make_event(event_type, data))
            return
        emit(self.trace_path, event_type, data)

    def absorb(self, view: CapabilityHost) -> None:
        self._effects_used.update(view._effects_used)
        if view._last_check is not None:
            self._last_check = view._last_check

    # --- words -----------------------------------------------------------

    def read_file(self, path: str) -> str:
        self._require_effect("read")
        target = self._existing_file(path)
        self._tool("READ-FILE", {"path": self._rel(path)})
        try:
            return target.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise CapabilityError("decode", f"not utf-8 text: {self._rel(path)}") from exc

    def list_dir(self, path: str = ".") -> list[str]:
        self._require_effect("read")
        target = self._existing_dir(path)
        self._tool("LIST-DIR", {"path": self._rel(path) or "."})
        names: list[str] = []
        for child in sorted(target.iterdir(), key=lambda item: item.name):
            rel = child.relative_to(self.workspace).as_posix()
            names.append(rel + ("/" if child.is_dir() else ""))
        return names

    def search(self, query: str) -> list[dict[str, Any]]:
        self._require_effect("read")
        self._tool("SEARCH", {"query": query})
        hits: list[dict[str, Any]] = []
        if query == "":
            return hits
        for file_path in sorted(self.workspace.rglob("*")):
            if not file_path.is_file() or any(
                part in {".git", "__pycache__"} for part in file_path.parts
            ):
                continue
            try:
                text = file_path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            rel = file_path.relative_to(self.workspace).as_posix()
            for number, line in enumerate(text.splitlines(), start=1):
                if query in line:
                    hits.append({"path": rel, "line": number, "text": line})
        return hits

    def write_file(self, content: str, path: str) -> dict[str, Any]:
        self._require_effect("write")
        rel = self._rel(path)
        reason = self._policy.write_allowed(rel)
        if reason is None and self._outer_policy is not None:
            reason = self._outer_policy.write_allowed(rel)
        if reason is not None:
            self._tool("WRITE-FILE", {"path": rel, "denied": True})
            self.emit_event("execution.trap", {"reason": "policy", "detail": reason, "path": rel})
            raise CapabilityError("policy", reason)
        target = self._policy.resolve(path)
        data = content.encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()
        receipt = {"path": rel, "bytes": len(data), "sha256": digest}
        if target.is_file() and target.read_bytes() == data:
            self._tool("WRITE-FILE", {"path": rel, "bytes": len(data), "idempotent": True})
            return receipt
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self._tool("WRITE-FILE", {"path": rel, "bytes": len(data)})
        self.emit_event("mutation.applied", {"path": rel, "sha256": digest})
        return receipt

    def run_gates(self, word: str = "RUN-GATES", persist: bool = True) -> dict[str, Any]:
        self._require_effect("exec")
        spec = detect_check(self.workspace)
        self._tool(word, {"command": spec.get("label") or "RUN-GATES"})
        receipt = measure_gates(self.workspace, float(self.test_timeout_seconds), persist=persist)
        self._last_check = receipt
        if receipt.get("timed_out"):
            self.emit_event("execution.trap", {"reason": "test_timeout"})
        return receipt

    def run_tests(self) -> dict[str, Any]:
        """Product check only. Does not write .sb discharge into the workspace."""
        self._require_effect("exec")
        spec = detect_check(self.workspace)
        self._tool("RUN-TESTS", {"command": spec.get("label") or "RUN-TESTS"})
        receipt = run_workspace_check(self.workspace, float(self.test_timeout_seconds))
        self._last_check = receipt
        if receipt.get("timed_out"):
            self.emit_event("execution.trap", {"reason": "test_timeout"})
        return receipt

    def receipt(self, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        after = snapshot(self.workspace)
        changed = changed_files(self._before, after)
        violations = [item for item in changed if self._policy.write_allowed(item) is not None]
        payload: dict[str, Any] = {
            "run_id": self.run_id,
            "task_id": self.task_id,
            "success": not violations,
            "workspace_before": workspace_digest(self._before),
            "workspace_after": workspace_digest(after),
            "changed_files": changed,
            "effects_used": sorted(self._effects_used),
            "policy_violations": [f"path outside policy after the fact: {item}" for item in violations],
        }
        if self._last_check is not None:
            payload["check"] = self._last_check
        for key in METRIC_KEYS:
            if key in self.graph_metrics and key not in payload:
                payload[key] = self.graph_metrics[key]
        if extra:
            payload.update(extra)
        if not self._write_receipt:
            self._tool("RECEIPT", {"path": None, "changed_files": changed})
            return payload
        target = self.receipt_path
        if target is None:
            target = self.workspace / "receipt.json"
        body = write_receipt(target, payload)
        self._tool("RECEIPT", {"path": str(target), "changed_files": changed})
        return body

    # --- internals -------------------------------------------------------

    def _require_effect(self, effect: str) -> None:
        if effect not in self.allowed_effects:
            self.emit_event("execution.trap", {"reason": "effect", "effect": effect})
            raise CapabilityError("effect", f"effect not allowed: {effect}")
        self._effects_used.add(effect)

    def _rel(self, path: str) -> str:
        try:
            return self._policy.relative(path)
        except ValueError as exc:
            self.emit_event("execution.trap", {"reason": "path", "detail": str(exc)})
            raise CapabilityError("path", str(exc)) from exc

    def _existing_file(self, path: str) -> Path:
        rel = self._rel(path)
        target = self.workspace / rel if rel else self.workspace
        if not target.is_file():
            self.emit_event("execution.trap", {"reason": "missing_file", "path": rel or "."})
            raise CapabilityError("missing_file", f"missing file: {rel or '.'}")
        return target

    def _existing_dir(self, path: str) -> Path:
        if path in {"", "."}:
            return self.workspace
        rel = self._rel(path)
        target = self.workspace / rel if rel else self.workspace
        if not target.is_dir():
            self.emit_event("execution.trap", {"reason": "missing_file", "path": rel or "."})
            raise CapabilityError("missing_file", f"missing directory: {rel or '.'}")
        return target

    def _tool(self, name: str, data: dict[str, Any]) -> None:
        payload = {"tool": name, **data}
        self.emit_event("tool.call", payload)
