"""Content-addressable objects for Layer A (docs/design/STORE.md).

Blobs live at <root>/<aa>/<sha256>. A tree is canonical JSON {path: sha256}
stored as a blob. events.jsonl stays the tx log; facts() is a derived view.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
from pathlib import Path
from typing import Any, Iterable

from .policy import snapshot

EPISODE_PLANNED = "episode.planned"
CRITIC_ACCEPTED = "critic.accepted"
CRITIC_REJECTED = "critic.rejected"
ARTIFACTS_APPLIED = "artifacts.applied"
GATES_MEASURED = "gates.measured"
DICTIONARY_PROMOTED = "dictionary.promoted"

SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
OBJECTS_ENV = "LIVINGDICT_OBJECTS"


class StoreError(ValueError):
    """Typed store failure. Missing blobs and bad arguments use this."""


class StoreCorruption(StoreError):
    """On-disk bytes do not match the addressed sha256. Never silent."""


def blob_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tree_bytes(files: dict[str, str]) -> bytes:
    cleaned = {str(path): str(digest) for path, digest in files.items()}
    return json.dumps(cleaned, sort_keys=True, separators=(",", ":")).encode("utf-8")


def tree_digest(files: dict[str, str]) -> str:
    return blob_digest(tree_bytes(files))


def objects_root(
    run_dir: str | Path | None = None,
    *,
    workspace: str | Path | None = None,
    receipt_path: str | Path | None = None,
) -> Path | None:
    """Resolve the object root.

    LIVINGDICT_OBJECTS wins. Default is run_dir/objects. A receipt inside
    the workspace parks objects under .livingdict-run so snapshots skip them.
    """
    env = os.environ.get(OBJECTS_ENV, "").strip()
    if env:
        return Path(env)
    if run_dir is not None:
        return Path(run_dir) / "objects"
    receipt = Path(receipt_path) if receipt_path is not None else None
    ws = Path(workspace).resolve() if workspace is not None else None
    if receipt is not None:
        parent = receipt.parent
        if ws is not None:
            try:
                parent.resolve().relative_to(ws)
            except ValueError:
                return parent / "objects"
            return ws / ".livingdict-run" / "objects"
        return parent / "objects"
    return None


def open_store(
    run_dir: str | Path | None = None,
    *,
    workspace: str | Path | None = None,
    receipt_path: str | Path | None = None,
) -> Store | None:
    root = objects_root(run_dir, workspace=workspace, receipt_path=receipt_path)
    if root is None:
        return None
    return Store(root)


def intern_blob(store: Store | None, data: bytes) -> str:
    if store is not None:
        return store.intern(data)
    return blob_digest(data)


def artifact_digests(
    artifacts: dict[str, str] | None,
    store: Store | None = None,
) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for key, body in (artifacts or {}).items():
        if not isinstance(key, str) or not isinstance(body, str):
            continue
        hashes[key] = intern_blob(store, body.encode("utf-8"))
    return hashes


def intern_snapshot(
    store: Store | None,
    workspace: str | Path,
    files: dict[str, str],
) -> str:
    """Intern each snapshot file (same skip set as policy.snapshot) and the tree."""
    workspace = Path(workspace)
    if store is not None:
        for rel in files:
            path = workspace / rel
            if path.is_file():
                store.intern(path.read_bytes())
        return store.intern_tree(files)
    return tree_digest(files)


def capture_tree(
    workspace: str | Path,
    store: Store | None = None,
) -> tuple[dict[str, str], str]:
    files = snapshot(Path(workspace))
    return files, intern_snapshot(store, workspace, files)


class Store:
    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)

    def intern(self, data: bytes) -> str:
        if not isinstance(data, (bytes, bytearray)):
            raise StoreError("intern expects bytes")
        payload = bytes(data)
        digest = blob_digest(payload)
        dest = self._blob_path(digest)
        if dest.is_file():
            return digest
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(f".tmp-{digest}-{os.getpid()}-{secrets.token_hex(8)}")
        try:
            tmp.write_bytes(payload)
            os.replace(tmp, dest)
        finally:
            if tmp.exists():
                tmp.unlink(missing_ok=True)
        return digest

    def intern_tree(self, files: dict[str, str]) -> str:
        return self.intern(tree_bytes(files))

    def get(self, digest: str) -> bytes:
        digest = _require_digest(digest)
        path = self._blob_path(digest)
        if not path.is_file():
            raise StoreError(f"missing blob {digest}")
        data = path.read_bytes()
        actual = blob_digest(data)
        if actual != digest:
            raise StoreCorruption(f"blob {digest} does not match payload")
        return data

    def get_tree(self, digest: str) -> dict[str, str]:
        raw = self.get(digest)
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StoreCorruption(f"tree {digest} is not canonical JSON") from exc
        if not isinstance(value, dict):
            raise StoreCorruption(f"tree {digest} is not an object")
        return {str(key): str(item) for key, item in value.items()}

    def has(self, digest: str) -> bool:
        if not SHA256_HEX.match(str(digest or "")):
            return False
        return self._blob_path(str(digest)).is_file()

    def object_count(self) -> int:
        if not self.root.is_dir():
            return 0
        count = 0
        for path in self.root.rglob("*"):
            if path.is_file() and SHA256_HEX.match(path.name):
                count += 1
        return count

    def _blob_path(self, digest: str) -> Path:
        return self.root / digest[:2] / digest


def facts(events: Iterable[Any], store: Store | None = None) -> list[tuple[str, str, Any, int]]:
    """Derive [e, a, v, tx] rows. tx is the event sequence. Never persisted."""
    rows: list[tuple[str, str, Any, int]] = []
    episode = 0
    last_artifact_sha: dict[str, str] = {}
    for event in events:
        kind, payload, seq = _event_fields(event)
        if kind == EPISODE_PLANNED:
            episode += 1
            fingerprint_hex = payload.get("fingerprint")
            if fingerprint_hex:
                rows.append((f"episode/{episode}", ":episode/fingerprint", str(fingerprint_hex), seq))
            hashes = payload.get("artifact_sha256")
            if isinstance(hashes, dict):
                last_artifact_sha = {str(key): str(value) for key, value in hashes.items()}
        elif kind == CRITIC_ACCEPTED:
            if episode:
                rows.append((f"episode/{episode}", ":critic/verdict", ":accept", seq))
        elif kind == CRITIC_REJECTED:
            if episode:
                rows.append((f"episode/{episode}", ":critic/verdict", ":reject", seq))
                errors = payload.get("errors") or []
                if not isinstance(errors, list):
                    errors = [errors]
                for item in errors:
                    rows.append((f"episode/{episode}", ":critic/error", str(item), seq))
        elif kind == ARTIFACTS_APPLIED:
            hashes = payload.get("artifact_sha256")
            if isinstance(hashes, dict):
                last_artifact_sha = {str(key): str(value) for key, value in hashes.items()}
            keys = payload.get("keys") or []
            if not isinstance(keys, list):
                keys = [keys]
            for key in keys:
                digest = last_artifact_sha.get(str(key))
                if digest:
                    rows.append((f"ws/{key}", ":file/content", f"blob:{digest}", seq))
        elif kind == GATES_MEASURED:
            rows.append(("run", ":gates/passed", _gates_passed(payload.get("report")), seq))
            files = _measured_files(payload, store)
            for path, digest in sorted(files.items()):
                rows.append((f"ws/{path}", ":file/content", f"blob:{digest}", seq))
        elif kind == DICTIONARY_PROMOTED:
            word = str(payload.get("word") or "")
            digest = payload.get("sha256")
            promo = payload.get("episode") or episode
            if word and digest:
                rows.append((f"word/{word}", ":word/content", f"blob:{digest}", seq))
                rows.append((f"word/{word}", ":word/promoted-by", f"episode/{promo}", seq))
    return rows


def as_of(
    events: Iterable[Any],
    seq: int,
    store: Store | None = None,
) -> dict[str, str]:
    """Workspace tree {path: sha256} at or before seq.

    A measured tree replaces the whole view (it sees deletions); artifacts
    applied after the last measurement overlay it, so a mid-episode seq
    (between artifacts.applied and gates.measured) reflects the applied
    files. Reject/duplicate episodes do not measure; those seqs reuse the
    last view, or {} if none.
    """
    limit = int(seq)
    current: dict[str, str] = {}
    have_tree = False
    last_hash: str | None = None
    last_artifact_sha: dict[str, str] = {}
    for event in events:
        kind, payload, event_seq = _event_fields(event)
        if event_seq > limit:
            continue
        if kind == EPISODE_PLANNED:
            hashes = payload.get("artifact_sha256")
            if isinstance(hashes, dict):
                last_artifact_sha = {str(key): str(value) for key, value in hashes.items()}
        elif kind == ARTIFACTS_APPLIED:
            hashes = payload.get("artifact_sha256")
            if isinstance(hashes, dict):
                last_artifact_sha = {str(key): str(value) for key, value in hashes.items()}
            keys = payload.get("keys") or []
            if not isinstance(keys, list):
                keys = [keys]
            for key in keys:
                digest = last_artifact_sha.get(str(key))
                if digest:
                    current[str(key)] = digest
        elif kind == GATES_MEASURED:
            files = _measured_files(payload, store)
            tree_hash = payload.get("tree_after") or payload.get("tree_before")
            if files:
                current = dict(files)
                have_tree = True
            if isinstance(tree_hash, str) and tree_hash:
                last_hash = tree_hash
    if not have_tree and not current and last_hash and store is not None:
        try:
            return store.get_tree(last_hash)
        except StoreError:
            pass
    return dict(current)


def _measured_files(payload: dict[str, Any], store: Store | None) -> dict[str, str]:
    files = payload.get("files")
    if isinstance(files, dict):
        return {str(key): str(value) for key, value in files.items()}
    tree_hash = payload.get("tree_after") or payload.get("tree_before")
    if store is not None and isinstance(tree_hash, str) and store.has(tree_hash):
        return store.get_tree(tree_hash)
    return {}


def _gates_passed(report: Any) -> bool:
    if not isinstance(report, dict):
        return False
    if "passed" in report:
        return bool(report.get("passed"))
    from .kernel import claims_discharged

    return claims_discharged(report)


def _event_fields(event: Any) -> tuple[str, dict[str, Any], int]:
    if hasattr(event, "kind") and hasattr(event, "payload"):
        try:
            seq = int(getattr(event, "sequence", 0) or 0)
        except (TypeError, ValueError):
            seq = 0
        payload = getattr(event, "payload", None) or {}
        if not isinstance(payload, dict):
            payload = {}
        return str(getattr(event, "kind")), dict(payload), seq
    if isinstance(event, dict):
        kind = str(event.get("kind") or "")
        payload = event.get("payload") or {}
        if not isinstance(payload, dict):
            payload = {}
        try:
            seq = int(event.get("sequence") or 0)
        except (TypeError, ValueError):
            seq = 0
        return kind, payload, seq
    raise StoreError("event must be an Event or object")


def _require_digest(digest: str) -> str:
    value = str(digest or "")
    if not SHA256_HEX.match(value):
        raise StoreError(f"invalid sha256 {digest!r}")
    return value
