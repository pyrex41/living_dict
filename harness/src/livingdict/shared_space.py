"""Small cross-process tuple space used by Layer C.

SQLite supplies the atomic claim boundary and durable lease state without
introducing a daemon or changing the model-facing ABI.  The event ledger
remains the audit/replay source; this module is only the liveness backend.
"""

from __future__ import annotations

import json
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any


class SharedSpace:
    def __init__(self, path: str | Path, *, clock=None) -> None:
        self.path = str(path)
        self.clock = clock or time.time
        self.db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS tuples ("
            "id TEXT PRIMARY KEY, payload TEXT NOT NULL, available REAL NOT NULL, "
            "lease_token TEXT, lease_owner TEXT, lease_until REAL, generation INTEGER NOT NULL)"
        )
        self.db.execute("CREATE INDEX IF NOT EXISTS tuples_available ON tuples(available)")

    def close(self) -> None:
        self.db.close()

    @staticmethod
    def _match(pattern: dict[str, Any], payload: dict[str, Any]) -> bool:
        for key, value in pattern.items():
            if isinstance(value, dict) and isinstance(payload.get(key), dict):
                if not SharedSpace._match(value, payload[key]):
                    return False
            elif payload.get(key) != value or key not in payload:
                return False
        return True

    def _reclaim(self, now: float) -> None:
        self.db.execute(
            "UPDATE tuples SET available=?, lease_token=NULL, lease_owner=NULL, lease_until=NULL "
            "WHERE lease_until IS NOT NULL AND lease_until <= ?",
            (now, now),
        )

    def out(self, payload: dict[str, Any]) -> str:
        if not isinstance(payload, dict) or not payload.get("kind"):
            raise ValueError("tuple must be an object with kind")
        ident = uuid.uuid4().hex
        self.db.execute(
            "INSERT INTO tuples(id,payload,available,generation) VALUES(?,?,?,0)",
            (ident, json.dumps(payload, sort_keys=True), self.clock()),
        )
        return ident

    def rd(self, pattern: dict[str, Any]) -> dict[str, Any] | None:
        now = self.clock()
        self._reclaim(now)
        for ident, raw in self.db.execute("SELECT id,payload FROM tuples WHERE available<=? ORDER BY rowid", (now,)):
            payload = json.loads(raw)
            if self._match(pattern, payload):
                return payload
        return None

    def take(self, pattern: dict[str, Any], *, owner: str, lease_s: float = 30.0) -> dict[str, Any] | None:
        now = self.clock()
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self._reclaim(now)
            rows = self.db.execute(
                "SELECT id,payload,generation FROM tuples WHERE available<=? ORDER BY rowid", (now,)
            ).fetchall()
            for ident, raw, generation in rows:
                payload = json.loads(raw)
                if not self._match(pattern, payload):
                    continue
                token = uuid.uuid4().hex
                self.db.execute(
                    "UPDATE tuples SET available=?,lease_token=?,lease_owner=?,lease_until=?,generation=? WHERE id=?",
                    (now + lease_s, token, owner, now + lease_s, generation + 1, ident),
                )
                self.db.execute("COMMIT")
                return {**payload, "_tuple_id": ident, "_lease": token, "_generation": generation + 1}
            self.db.execute("COMMIT")
            return None
        except Exception:
            self.db.execute("ROLLBACK")
            raise

    def complete(self, claim: dict[str, Any], *, owner: str) -> bool:
        cur = self.db.execute(
            "DELETE FROM tuples WHERE id=? AND lease_token=? AND lease_owner=?",
            (claim.get("_tuple_id"), claim.get("_lease"), owner),
        )
        return cur.rowcount == 1

