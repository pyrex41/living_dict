"""In-process Linda tuple space (docs/design/STORE.md Layer B).

Linda is the executor, never the planner. The critic still owns topology;
this module only moves tuples the host already decided to emit.

Thread-safe (one lock + condition). No sockets, files, daemons, or ngx.
`kind=obligation` is Layer C and is refused. `critic.reject` / `gate.result`
are reserved for Layer C concurrent consumers; the sequential planner loop
reads backpressure from the kernel event log, which stays the single
source of truth.

Waiter wakeup prefers the most specific matching pattern (most keys);
insertion-order FIFO breaks ties. Bag scan is oldest-first so a single
worker taking after lex-id `out` is deterministic.
"""

from __future__ import annotations

import json
import secrets
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

RecordFn = Callable[[str, dict[str, Any]], None]
ClockFn = Callable[[], float]

ALLOWED_KINDS = frozenset({"node.ready", "gate.result", "critic.reject"})
LAYER_C_KIND = "obligation"


class SpaceError(ValueError):
    """Typed space failure. Bad tuples, patterns, and leases use this."""


@dataclass
class Claim:
    """A leased take. Unpacks as `(tuple_id, tuple)` for the STORE.md verbs."""

    token: str
    generation: int
    worker_id: str
    tuple: dict[str, Any]
    expires_at: float
    tuple_id: str

    def __iter__(self):
        yield self.tuple_id
        yield dict(self.tuple)


@dataclass
class _Entry:
    tuple_id: str
    payload: dict[str, Any]
    generation: int = 0


@dataclass
class _Lease:
    token: str
    entry: _Entry
    worker_id: str
    generation: int
    expires_at: float
    lease_s: float
    pattern: dict[str, Any]


@dataclass
class _Waiter:
    pattern: dict[str, Any]
    seq: int
    assigned: _Entry | None = None


def subset_match(pattern: Any, data: Any) -> bool:
    """Dict-subset match. Pattern keys must be present and equal in `data`.

    Nested dicts recurse as subsets. Lists and scalars compare exactly.
    Tuple values are always data: they are never interpreted as patterns.
    `bool` is not `int`; `2` is not `"2"`.
    """
    if isinstance(pattern, dict):
        if not isinstance(data, dict):
            return False
        for key, expected in pattern.items():
            if key not in data:
                return False
            if isinstance(expected, dict) and isinstance(data[key], dict):
                if not subset_match(expected, data[key]):
                    return False
            elif not _exact(expected, data[key]):
                return False
        return True
    return _exact(pattern, data)


def _exact(left: Any, right: Any) -> bool:
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return False
        return all(_exact(left[key], right[key]) for key in left)
    if isinstance(left, list):
        if len(left) != len(right):
            return False
        return all(_exact(item, other) for item, other in zip(left, right))
    return left == right


def _specificity(pattern: dict[str, Any]) -> int:
    return _count_keys(pattern)


def _count_keys(value: Any) -> int:
    if not isinstance(value, dict):
        return 0
    return len(value) + sum(_count_keys(item) for item in value.values())


def _copy(value: dict[str, Any]) -> dict[str, Any]:
    return dict(value)


class Space:
    def __init__(
        self,
        clock: ClockFn | None = None,
        record: RecordFn | None = None,
        store: Any | None = None,
    ) -> None:
        self.clock: ClockFn = clock or time.monotonic
        self.record = record
        self.store = store
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._bag: list[_Entry] = []
        self._leases: dict[str, _Lease] = {}
        self._waiters: list[_Waiter] = []
        self._next_id = 0
        self._waiter_seq = 0

    def out(self, tuple_dict: dict[str, Any]) -> str:
        if not isinstance(tuple_dict, dict):
            raise SpaceError("tuple must be a dict")
        kind = tuple_dict.get("kind")
        if kind == LAYER_C_KIND:
            raise SpaceError("obligation tuples are Layer C")
        if kind is not None and kind not in ALLOWED_KINDS:
            raise SpaceError(f"unknown tuple kind {kind!r}")
        payload = _copy(tuple_dict)
        with self._cond:
            self._next_id += 1
            tuple_id = f"t{self._next_id}"
            entry = _Entry(tuple_id=tuple_id, payload=payload)
            self._intern(payload)
            self._bag.append(entry)
            self._emit(
                "space.out",
                {
                    "worker": "host",
                    "tuple_id": tuple_id,
                    "generation": 0,
                    "lease_s": 0,
                    "pattern_or_tuple": _copy(payload),
                    "node": payload.get("node"),
                },
            )
            self._handoff()
            self._cond.notify_all()
            return tuple_id

    def rd(self, pattern: dict[str, Any], timeout: float | None = None) -> dict[str, Any] | None:
        """Non-destructive read. Non-blocking unless `timeout` is a positive number."""
        if not isinstance(pattern, dict):
            raise SpaceError("pattern must be a dict")
        deadline = self._deadline(timeout)
        with self._cond:
            while True:
                self._reap()
                entry = self._oldest_match(pattern)
                if entry is not None:
                    return _copy(entry.payload)
                if timeout is None or timeout <= 0:
                    return None
                if self.clock() >= deadline:
                    return None
                self._wait_for(deadline)

    def take(
        self,
        pattern: dict[str, Any],
        lease_s: float,
        worker_id: str | None = None,
        timeout: float | None = None,
        *,
        stop: threading.Event | None = None,
    ) -> Claim | None:
        """Atomically remove the oldest match and lease it.

        Blocks while no match and no expired lease (`timeout=None`).
        `timeout=0` is non-blocking. `stop` lets a wave barrier wake waiters.
        """
        if not isinstance(pattern, dict):
            raise SpaceError("pattern must be a dict")
        try:
            lease = float(lease_s)
        except (TypeError, ValueError) as exc:
            raise SpaceError("lease_s must be > 0") from exc
        if lease <= 0:
            raise SpaceError("lease_s must be > 0")
        worker = "anon" if worker_id is None else str(worker_id)
        deadline = self._deadline(timeout)
        waiter: _Waiter | None = None
        with self._cond:
            try:
                while True:
                    self._reap()
                    entry = None
                    if waiter is not None and waiter.assigned is not None:
                        entry = waiter.assigned
                        waiter.assigned = None
                    if entry is None:
                        entry = self._pop_oldest_match(pattern)
                    if entry is not None:
                        return self._claim(entry, lease, worker, pattern)
                    if stop is not None and stop.is_set():
                        return None
                    if timeout is not None and timeout <= 0:
                        return None
                    if timeout is not None and self.clock() >= deadline:
                        return None
                    if waiter is None:
                        self._waiter_seq += 1
                        waiter = _Waiter(pattern=_copy(pattern), seq=self._waiter_seq)
                        self._waiters.append(waiter)
                    if not self._wait_for(deadline, stop=stop):
                        if waiter.assigned is not None:
                            self._bag.append(waiter.assigned)
                            waiter.assigned = None
                            self._handoff()
                        if timeout is not None and self.clock() >= deadline:
                            return None
                        if stop is not None and stop.is_set():
                            return None
            finally:
                if waiter is not None:
                    if waiter.assigned is not None:
                        self._bag.append(waiter.assigned)
                        waiter.assigned = None
                        self._handoff()
                    if waiter in self._waiters:
                        self._waiters.remove(waiter)

    def renew(self, token_or_id: str, lease_s: float | None = None) -> bool:
        with self._cond:
            self._reap()
            lease = self._lease_by_token_or_id(token_or_id)
            if lease is None:
                return False
            if lease_s is None:
                duration = lease.lease_s
            else:
                try:
                    duration = float(lease_s)
                except (TypeError, ValueError):
                    return False
            if duration <= 0:
                return False
            lease.lease_s = duration
            lease.expires_at = self.clock() + duration
            return True

    def ack(self, token: str) -> bool:
        """Permanent consume. False if the generation was stolen or already acked."""
        with self._cond:
            return self._ack_locked(token)

    def done(self, tuple_id: str) -> bool:
        """Ack the live claim for `tuple_id` (STORE.md `done`)."""
        with self._cond:
            lease = self._lease_by_tuple(tuple_id)
            if lease is None:
                return False
            return self._ack_locked(lease.token)

    def cancel(self, token: str) -> bool:
        """Test helper: return the tuple to the bag without `space.lease_expired`."""
        with self._cond:
            lease = self._leases.pop(token, None)
            if lease is None:
                return False
            self._bag.append(lease.entry)
            self._handoff()
            self._cond.notify_all()
            return True

    def expire(self, token: str) -> bool:
        """Force lease expiry: tuple returns, `space.lease_expired` is recorded."""
        with self._cond:
            if not self._expire_token(token):
                return False
            self._handoff()
            self._cond.notify_all()
            return True

    def is_current(self, claim: Claim | str) -> bool:
        token = claim.token if isinstance(claim, Claim) else claim
        with self._cond:
            self._reap()
            return token in self._leases

    def wake(self) -> None:
        with self._cond:
            self._cond.notify_all()

    def waiter_count(self) -> int:
        with self._lock:
            return len(self._waiters)

    def bag_size(self) -> int:
        with self._cond:
            self._reap()
            return len(self._bag)

    def leased_count(self) -> int:
        with self._cond:
            self._reap()
            return len(self._leases)

    def _deadline(self, timeout: float | None) -> float:
        if timeout is None:
            return float("inf")
        return self.clock() + max(0.0, float(timeout))

    def _wait_for(self, deadline: float, stop: threading.Event | None = None) -> bool:
        if stop is not None and stop.is_set():
            return False
        now = self.clock()
        remaining = None if deadline == float("inf") else max(0.0, deadline - now)
        nxt = self._next_expiry()
        if nxt is not None:
            slice_s = max(0.0, nxt - now)
            remaining = slice_s if remaining is None else min(remaining, slice_s)
        if remaining is not None and remaining == 0:
            return True
        self._cond.wait(timeout=remaining)
        return True

    def _next_expiry(self) -> float | None:
        if not self._leases:
            return None
        return min(item.expires_at for item in self._leases.values())

    def _oldest_match(self, pattern: dict[str, Any]) -> _Entry | None:
        for entry in self._bag:
            if subset_match(pattern, entry.payload):
                return entry
        return None

    def _pop_oldest_match(self, pattern: dict[str, Any]) -> _Entry | None:
        for index, entry in enumerate(self._bag):
            if subset_match(pattern, entry.payload):
                return self._bag.pop(index)
        return None

    def _handoff(self) -> None:
        if not self._waiters or not self._bag:
            return
        claimed: set[int] = set()
        ordered = sorted(self._waiters, key=lambda item: (-_specificity(item.pattern), item.seq))
        for waiter in ordered:
            if waiter.assigned is not None:
                continue
            match = None
            for entry in self._bag:
                if id(entry) in claimed:
                    continue
                if subset_match(waiter.pattern, entry.payload):
                    match = entry
                    break
            if match is None:
                continue
            claimed.add(id(match))
            waiter.assigned = match
        if not claimed:
            return
        self._bag = [entry for entry in self._bag if id(entry) not in claimed]
        self._waiters = [waiter for waiter in self._waiters if waiter.assigned is None]
        self._cond.notify_all()

    def _claim(
        self,
        entry: _Entry,
        lease_s: float,
        worker_id: str,
        pattern: dict[str, Any],
    ) -> Claim:
        entry.generation += 1
        token = f"{entry.tuple_id}:{entry.generation}:{secrets.token_hex(4)}"
        expires_at = self.clock() + lease_s
        self._leases[token] = _Lease(
            token=token,
            entry=entry,
            worker_id=worker_id,
            generation=entry.generation,
            expires_at=expires_at,
            lease_s=lease_s,
            pattern=_copy(pattern),
        )
        self._emit(
            "space.take",
            {
                "worker": worker_id,
                "tuple_id": entry.tuple_id,
                "generation": entry.generation,
                "lease_s": lease_s,
                "pattern_or_tuple": _copy(pattern),
                "node": entry.payload.get("node"),
            },
        )
        return Claim(
            token=token,
            generation=entry.generation,
            worker_id=worker_id,
            tuple=_copy(entry.payload),
            expires_at=expires_at,
            tuple_id=entry.tuple_id,
        )

    def _ack_locked(self, token: str) -> bool:
        lease = self._leases.pop(token, None)
        return lease is not None

    def _reap(self) -> None:
        now = self.clock()
        expired = [token for token, lease in self._leases.items() if now >= lease.expires_at]
        if not expired:
            return
        for token in expired:
            self._expire_token(token)
        self._handoff()
        self._cond.notify_all()

    def _expire_token(self, token: str) -> bool:
        lease = self._leases.pop(token, None)
        if lease is None:
            return False
        self._bag.append(lease.entry)
        payload: dict[str, Any] = {
            "worker": lease.worker_id,
            "tuple_id": lease.entry.tuple_id,
            "generation": lease.generation,
            "lease_s": lease.lease_s,
            "pattern_or_tuple": _copy(lease.entry.payload),
            "node": lease.entry.payload.get("node"),
        }
        self._emit("space.lease_expired", payload)
        return True

    def _lease_by_token_or_id(self, token_or_id: str) -> _Lease | None:
        lease = self._leases.get(token_or_id)
        if lease is not None:
            return lease
        return self._lease_by_tuple(token_or_id)

    def _lease_by_tuple(self, tuple_id: str) -> _Lease | None:
        for lease in self._leases.values():
            if lease.entry.tuple_id == tuple_id:
                return lease
        return None

    def _intern(self, payload: dict[str, Any]) -> None:
        if self.store is None:
            return
        blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.store.intern(blob)

    def _emit(self, kind: str, payload: dict[str, Any]) -> None:
        callback = self.record
        if callback is None:
            return
        callback(kind, payload)


