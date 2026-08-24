"""Pure event-sourced episode kernel (scud-v2 style).

No I/O, no clocks, no model calls. Reduce clones then applies; a bad
event leaves the input state untouched. reconcile is a total function.
"""

from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass, field
from typing import Any

from .forth import tokenize


EPISODE_PLANNED = "episode.planned"
CRITIC_ACCEPTED = "critic.accepted"
CRITIC_REJECTED = "critic.rejected"
ARTIFACTS_APPLIED = "artifacts.applied"
GATES_MEASURED = "gates.measured"
BUDGET_CONSUMED = "budget.consumed"
EPISODE_BLOCKED_DUPLICATE = "episode.blocked_duplicate"
DICTIONARY_PROMOTED = "dictionary.promoted"
PROMOTION_EVIDENCE = "dictionary.promotion_evidence"
CONTRACT_APPROVED = "contract.approved"

EVENT_KINDS = frozenset(
    {
        EPISODE_PLANNED,
        CRITIC_ACCEPTED,
        CRITIC_REJECTED,
        ARTIFACTS_APPLIED,
        GATES_MEASURED,
        BUDGET_CONSUMED,
        EPISODE_BLOCKED_DUPLICATE,
        DICTIONARY_PROMOTED,
        PROMOTION_EVIDENCE,
        CONTRACT_APPROVED,
    }
)

DECISION_PLAN = "plan"
DECISION_SUCCESS = "success"
DECISION_HALT_CAP = "halt_cap"
DECISION_BLOCKED = "blocked"


class KernelError(ValueError):
    pass


@dataclass(frozen=True)
class Event:
    kind: str
    sequence: int = 0
    id: str = ""
    payload: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class Decision:
    kind: str
    reason: str = ""


@dataclass(frozen=True)
class State:
    revision: int = 0
    events: tuple[Event, ...] = ()
    seen_plans: tuple[str, ...] = ()
    consecutive_duplicates: int = 0
    last_fingerprint: str = ""
    last_errors: tuple[str, ...] = ()
    last_gates: dict[str, Any] | None = None
    used: int = 0
    last_critic: str = ""
    pending_execute: bool = False
    last_artifact_keys: tuple[str, ...] = ()
    last_failure: dict[str, Any] | None = None


def empty_state() -> State:
    return State()


def event_to_dict(event: Event) -> dict[str, Any]:
    return {
        "id": event.id,
        "kind": event.kind,
        "payload": copy.deepcopy(event.payload),
        "sequence": event.sequence,
    }


def event_from_dict(value: Any) -> Event:
    if not isinstance(value, dict):
        raise KernelError("event must be an object")
    kind = value.get("kind")
    if not isinstance(kind, str) or not kind:
        raise KernelError("event.kind must be a string")
    payload = value.get("payload") or {}
    if not isinstance(payload, dict):
        raise KernelError("event.payload must be an object")
    ident = value.get("id") or ""
    if not isinstance(ident, str):
        ident = str(ident)
    try:
        sequence = int(value.get("sequence") or 0)
    except (TypeError, ValueError) as exc:
        raise KernelError("event.sequence must be an integer") from exc
    return Event(kind=kind, sequence=sequence, id=ident, payload=dict(payload))


def clone_state(state: State) -> State:
    return State(
        revision=state.revision,
        events=state.events,
        seen_plans=state.seen_plans,
        consecutive_duplicates=state.consecutive_duplicates,
        last_fingerprint=state.last_fingerprint,
        last_errors=state.last_errors,
        last_gates=copy.deepcopy(state.last_gates),
        used=state.used,
        last_critic=state.last_critic,
        pending_execute=state.pending_execute,
        last_artifact_keys=state.last_artifact_keys,
        last_failure=copy.deepcopy(state.last_failure),
    )


def _payload(event: Event) -> dict[str, Any]:
    return dict(event.payload or {})


def reduce(state: State, event: Event) -> State:
    """Apply one event. Sequence 0 is assigned; nonzero must be Revision+1."""
    if event.kind not in EVENT_KINDS:
        raise KernelError(f"invalid event kind {event.kind!r}")
    if event.sequence != 0 and event.sequence != state.revision + 1:
        raise KernelError(
            f"event sequence {event.sequence} does not follow revision {state.revision}"
        )
    if event.id:
        for prior in state.events:
            if prior.id == event.id:
                raise KernelError(f"duplicate event id {event.id!r}")

    new = clone_state(state)
    payload = _payload(event)
    if event.kind == EPISODE_PLANNED:
        fingerprint_hex = str(payload.get("fingerprint") or "")
        # A repeated plan is only a duplicate when it is proposed against the
        # same product state.  A model may legitimately reuse a repair plan
        # after an earlier episode changed the workspace.
        dedupe_key = str(payload.get("dedupe_key") or fingerprint_hex)
        new = State(
            **{
                **new.__dict__,
                "last_fingerprint": fingerprint_hex,
            }
        )
        if dedupe_key and dedupe_key in new.seen_plans:
            new = State(**{**new.__dict__, "pending_execute": False})
        else:
            seen = new.seen_plans
            if dedupe_key:
                seen = seen + (dedupe_key,)
            new = State(
                **{
                    **new.__dict__,
                    "seen_plans": seen,
                    "consecutive_duplicates": 0,
                    "pending_execute": True,
                }
            )
    elif event.kind == EPISODE_BLOCKED_DUPLICATE:
        new = State(
            **{
                **new.__dict__,
                "pending_execute": False,
                "consecutive_duplicates": new.consecutive_duplicates + 1,
            }
        )
    elif event.kind == CRITIC_ACCEPTED:
        new = State(**{**new.__dict__, "last_critic": "accepted", "last_errors": ()})
    elif event.kind == CRITIC_REJECTED:
        errors = payload.get("errors") or []
        if not isinstance(errors, list):
            errors = [errors]
        new = State(
            **{
                **new.__dict__,
                "last_critic": "rejected",
                "last_errors": tuple(str(item) for item in errors),
                "pending_execute": False,
            }
        )
    elif event.kind == ARTIFACTS_APPLIED:
        keys = payload.get("keys") or []
        if not isinstance(keys, list):
            keys = [keys]
        new = State(
            **{
                **new.__dict__,
                "last_artifact_keys": tuple(str(item) for item in keys),
            }
        )
    elif event.kind == GATES_MEASURED:
        report = payload.get("report")
        if report is not None and not isinstance(report, dict):
            raise KernelError("gates.measured report must be an object")
        failure = None
        if isinstance(report, dict) and not report.get("passed"):
            failed = []
            for gate in report.get("gates") or []:
                for claim in gate.get("claims") or []:
                    if isinstance(claim, dict) and not claim.get("passed"):
                        failed.append({key: claim.get(key) for key in ("id", "kind", "command", "reason", "returncode", "output", "timed_out") if key in claim})
            failure = {"failed_claims": failed, "stderr": report.get("stderr", "")}
        new = State(**{**new.__dict__, "last_gates": copy.deepcopy(report), "last_failure": failure})
    elif event.kind == BUDGET_CONSUMED:
        try:
            steps = int(payload.get("steps") if payload.get("steps") is not None else 1)
        except (TypeError, ValueError) as exc:
            raise KernelError("budget.consumed steps must be an integer") from exc
        if steps <= 0:
            raise KernelError("budget delta is empty")
        new = State(**{**new.__dict__, "used": new.used + steps})
    elif event.kind in (DICTIONARY_PROMOTED, PROMOTION_EVIDENCE, CONTRACT_APPROVED):
        pass

    stored = Event(
        kind=event.kind,
        sequence=new.revision + 1,
        id=event.id,
        payload=copy.deepcopy(event.payload),
    )
    return State(**{**new.__dict__, "revision": new.revision + 1, "events": new.events + (stored,)})


def replay(events: list[Event] | tuple[Event, ...]) -> State:
    """Fold events onto an empty state. Zero sequences become stream position."""
    state = empty_state()
    for index, event in enumerate(events):
        if event.sequence == 0:
            event = Event(
                kind=event.kind,
                sequence=index + 1,
                id=event.id,
                payload=event.payload,
            )
        state = reduce(state, event)
    return state


def claims_discharged(report: Any) -> bool:
    """Success is claim discharge, never body.ok / RECEIPT / structural green."""
    if not isinstance(report, dict):
        return False
    gates = report.get("gates")
    if not isinstance(gates, list) or not gates:
        return False
    claims = [gate for gate in gates if gate.get("name") == "claims"]
    if not claims:
        return False
    if any(not gate.get("passed") for gate in claims):
        return False
    for gate in gates:
        if gate.get("name") in {"look", "progress"} and not gate.get("skipped") and not gate.get("passed"):
            return False
    return True


def reconcile(state: State, cap: int, *, stop_on_duplicates: bool = True) -> Decision:
    """Total next action: success | blocked | halt_cap | plan."""
    if claims_discharged(state.last_gates):
        return Decision(DECISION_SUCCESS, "claims discharged")
    if stop_on_duplicates and state.consecutive_duplicates >= 2:
        return Decision(DECISION_BLOCKED, "feedback loop")
    limit = int(cap)
    if limit > 0 and state.used >= limit:
        return Decision(DECISION_HALT_CAP, "cap reached")
    return Decision(DECISION_PLAN, "run another episode")


def _node_rows(envelope: Any) -> list[tuple[str, list[str], list[str], str]]:
    if envelope is None:
        return []
    if hasattr(envelope, "nodes"):
        raw = getattr(envelope, "nodes") or []
    elif isinstance(envelope, dict):
        raw = envelope.get("nodes") or []
    else:
        return []
    rows: list[tuple[str, list[str], list[str], str]] = []
    for item in raw:
        if hasattr(item, "id"):
            ident = str(getattr(item, "id"))
            writes = [str(value) for value in (getattr(item, "writes") or [])]
            deps = [str(value) for value in (getattr(item, "depends_on") or [])]
            program = getattr(item, "program") or ""
        elif isinstance(item, dict):
            ident = str(item.get("id") or "")
            writes = [str(value) for value in (item.get("writes") or [])]
            deps = [str(value) for value in (item.get("depends_on") or [])]
            program = item.get("program") or ""
        else:
            continue
        if not ident:
            continue
        rows.append((ident, writes, deps, program if isinstance(program, str) else str(program)))
    rows.sort(key=lambda row: row[0])
    return rows


def _nodes_material(envelope: Any) -> str:
    chunks: list[str] = []
    for ident, writes, deps, program in _node_rows(envelope):
        chunks.append(ident)
        chunks.append(",".join(sorted(writes)))
        chunks.append(",".join(sorted(deps)))
        chunks.append(_normalized_tokens(program))
    return "\n".join(chunks)


def _envelope_parts(envelope: Any) -> tuple[str, dict[str, str]]:
    if envelope is None:
        return "", {}
    if hasattr(envelope, "program"):
        program = getattr(envelope, "program") or ""
        artifacts = getattr(envelope, "artifacts") or {}
    elif isinstance(envelope, dict):
        program = envelope.get("program") or ""
        artifacts = envelope.get("artifacts") or {}
    else:
        raise KernelError("envelope must be an object")
    if not isinstance(program, str):
        program = str(program)
    if not isinstance(artifacts, dict):
        raise KernelError("envelope.artifacts must be an object")
    cleaned: dict[str, str] = {}
    for key, text in artifacts.items():
        if not isinstance(key, str):
            continue
        cleaned[key] = text if isinstance(text, str) else str(text)
    return program, cleaned


def _claim_ids(artifacts: dict[str, str]) -> list[str]:
    raw = artifacts.get("claims.json")
    if not raw:
        return []
    try:
        blob = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(blob, dict):
        return []
    items = blob.get("claims")
    if not isinstance(items, list):
        return []
    ids: list[str] = []
    for item in items:
        if isinstance(item, dict) and item.get("id") is not None:
            ids.append(str(item["id"]))
    ids.sort()
    return ids


def _normalized_tokens(program: str) -> str:
    try:
        tokens = tokenize(program)
    except Exception:
        return " ".join(program.split())
    parts: list[str] = []
    for token in tokens:
        if token.kind == "string":
            parts.append(f'S"{token.value}"')
        elif token.kind == "number":
            parts.append(str(token.value))
        else:
            parts.append(str(token.value).upper())
    return " ".join(parts)


def fingerprint(envelope: Any) -> str:
    """SHA-256 over the complete executable plan, including artifact bodies."""
    program, artifacts = _envelope_parts(envelope)
    parts = [
        _normalized_tokens(program),
        json.dumps(
            {key: hashlib.sha256(value.encode("utf-8")).hexdigest() for key, value in sorted(artifacts.items())},
            sort_keys=True,
        ),
    ]
    nodes_material = _nodes_material(envelope)
    if nodes_material:
        parts.append(nodes_material)
    material = "\n".join(parts)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()
