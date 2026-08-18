from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from collections import Counter
from pathlib import Path

from livingdict.adapter import run_request
from livingdict.cli import critic_extra, run_job
from livingdict.envelope import load_envelope
from livingdict.execute import run_forth
from livingdict.forth import ForthVM
from livingdict.host import CapabilityError, CapabilityHost
from livingdict.kernel import EVENT_KINDS, Event, replay
from livingdict.rho import EventStream, consume_rho_v1
from livingdict.space import Space, SpaceError, subset_match
from livingdict.store import Store
from livingdict.trace import read_events


REPO = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "graph-01.envelope.json"
GRAPH_PLANNER = Path(__file__).resolve().parent / "graph_planner.py"
FIZZBUZZ_PLANNER = Path(__file__).resolve().parent / "fizzbuzz_planner.py"
GRAPH_01 = REPO / "eval" / "tasks" / "graph-01"
CLI = REPO / "client" / "cli.py"
SCUDCHECK = REPO / "tools" / "scudcheck"

SKIP_TREE = {".git", "__pycache__", ".sb", ".livingdict-run", ".mypy_cache"}

REJECT_PLANNER = r'''
import json, sys
from pathlib import Path
obs = json.loads(sys.stdin.read() or "{}")
path = Path(sys.argv[1])
rows = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else []
rows.append(obs)
path.write_text(json.dumps(rows), encoding="utf-8")
if int(obs.get("episode") or 0) <= 1:
    json.dump(
        {"language": "forth", "program": "NO-SUCH-WORD", "artifacts": {}, "rationale": "bad"},
        sys.stdout,
    )
else:
    json.dump(
        {"language": "forth", "program": "RECEIPT", "artifacts": {}, "rationale": "ok"},
        sys.stdout,
    )
sys.stdout.write("\n")
'''


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, delta: float) -> None:
        self.now += float(delta)


def _wait_until(predicate, timeout: float = 1.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.001)
    raise AssertionError("timeout waiting for condition")


def _node_ready(node: str, **extra: object) -> dict:
    payload = {"kind": "node.ready", "node": node}
    payload.update(extra)
    return payload


def _tree_hashes(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if any(part in SKIP_TREE for part in path.parts):
            continue
        if path.suffix in {".pyc", ".pyo"}:
            continue
        if path.name in {"trace.jsonl", "receipt.json", "checkpoint.json"}:
            continue
        rel = path.relative_to(root).as_posix()
        values[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return values


def _gate_shape(report: dict) -> list[tuple[str, bool, bool]]:
    gates = report.get("gates") or []
    return [
        (str(gate.get("name")), bool(gate.get("passed")), bool(gate.get("skipped")))
        for gate in gates
    ]


def _host(root: Path, globs: tuple[str, ...] = ("**",)) -> CapabilityHost:
    return CapabilityHost(
        workspace=root,
        allowed_effects=("read", "write", "exec"),
        allowed_globs=globs,
        forbidden_globs=(),
        trace_path=root / "trace.jsonl",
        receipt_path=root / "receipt.json",
    )


def _env(**extra: str) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("RHO_PROTOCOL_GRANT_")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.update(extra)
    return env


def _scudcheck(stream: str, run_id: str) -> subprocess.CompletedProcess[str] | None:
    if shutil.which("go") is None or not (SCUDCHECK / "main.go").is_file():
        return None
    return subprocess.run(
        ["go", "run", ".", "-run-id", run_id],
        input=stream,
        cwd=str(SCUDCHECK),
        capture_output=True,
        text=True,
        check=False,
    )


def _canned_request(run_id: str, prompt: str, workspace: Path) -> dict:
    return {
        "protocol": "rho.run/v1",
        "run_id": run_id,
        "model": {"provider": "test", "id": "fizzbuzz"},
        "input": [{"role": "user", "content": [{"type": "text", "text": prompt}]}],
        "limits": {},
        "grant": {
            "grant_id": "scud-local",
            "expires_at": "2030-01-01T00:00:00Z",
            "providers": ["test"],
            "models": ["fizzbuzz"],
            "tools": [],
            "read_roots": [str(workspace)],
            "write_roots": [str(workspace)],
            "network": {"mode": "provider_only"},
        },
    }


class SpaceMatchTests(unittest.TestCase):
    def test_subset_matching_and_types(self) -> None:
        clock = FakeClock()
        space = Space(clock=clock)
        space.out(
            {
                "kind": "node.ready",
                "run": "R",
                "episode": 1,
                "wave": 2,
                "node": "registry",
                "extra": 1,
            }
        )
        self.assertEqual(space.rd({"kind": "node.ready"})["node"], "registry")
        self.assertEqual(space.rd({"kind": "node.ready", "node": "registry"})["wave"], 2)
        self.assertIsNone(space.rd({"kind": "node.ready", "node": "verify"}))
        self.assertIsNone(space.rd({"kind": "gate.result"}))
        self.assertIsNone(space.rd({"wave": "2"}))
        self.assertIsNotNone(space.rd({"wave": 2}))
        self.assertTrue(subset_match({"meta": {"a": 1}}, {"meta": {"a": 1, "b": 2}}))
        self.assertFalse(subset_match({"ok": True}, {"ok": 1}))

    def test_rd_is_nondestructive_take_is_a_copy(self) -> None:
        space = Space(clock=FakeClock())
        space.out(_node_ready("registry"))
        first = space.rd({"node": "registry"})
        second = space.rd({"node": "registry"})
        self.assertEqual(first["node"], "registry")
        self.assertEqual(second["node"], "registry")
        claim = space.take({"kind": "node.ready"}, 1, "w0", timeout=0)
        assert claim is not None
        claim.tuple["node"] = "x"
        self.assertIsNone(space.rd({"node": "x"}))
        space.ack(claim.token)
        self.assertIsNone(space.rd({"node": "registry"}))

    def test_bag_two_equal_dicts(self) -> None:
        space = Space(clock=FakeClock())
        space.out(_node_ready("registry"))
        space.out(_node_ready("registry"))
        first = space.take({"kind": "node.ready"}, 1, "a", timeout=0)
        second = space.take({"kind": "node.ready"}, 1, "b", timeout=0)
        third = space.take({"kind": "node.ready"}, 1, "c", timeout=0)
        self.assertIsNotNone(first)
        self.assertIsNotNone(second)
        self.assertIsNone(third)
        self.assertNotEqual(first.tuple_id, second.tuple_id)

    def test_oldest_first_take(self) -> None:
        space = Space(clock=FakeClock())
        space.out(_node_ready("ingest"))
        space.out(_node_ready("offset"))
        space.out(_node_ready("scale"))
        first = space.take({"kind": "node.ready"}, 1, "w0", timeout=0)
        second = space.take({"kind": "node.ready"}, 1, "w0", timeout=0)
        third = space.take({"kind": "node.ready"}, 1, "w0", timeout=0)
        self.assertEqual([first.tuple["node"], second.tuple["node"], third.tuple["node"]], ["ingest", "offset", "scale"])

    def test_refuse_obligation_and_non_dict(self) -> None:
        space = Space(clock=FakeClock())
        with self.assertRaises(SpaceError):
            space.out({"kind": "obligation", "goal": "g", "id": "ob-7"})
        with self.assertRaises(SpaceError):
            space.out(["node.ready"])  # type: ignore[arg-type]
        with self.assertRaises(SpaceError):
            space.take({"kind": "node.ready"}, 0, "w0")

    def test_refuse_unknown_kind_but_allow_kindless(self) -> None:
        space = Space(clock=FakeClock())
        with self.assertRaises(SpaceError):
            space.out({"kind": "weird", "node": "x"})
        space.out({"wave": 2})
        self.assertEqual(space.bag_size(), 1)

    def test_rd_with_timeout_returns_after_deadline(self) -> None:
        """Regression: rd(pattern, timeout>0) on an empty space must not hang."""
        space = Space()
        result: dict[str, object] = {}

        def run() -> None:
            result["value"] = space.rd({"kind": "node.ready"}, timeout=0.1)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        thread.join(5)
        self.assertFalse(thread.is_alive(), "rd hung past its timeout")
        self.assertIsNone(result["value"])


class SpaceLeaseTests(unittest.TestCase):
    def test_expiry_returns_tuple_and_steals_generation(self) -> None:
        clock = FakeClock()
        records: list[tuple[str, dict]] = []
        space = Space(clock=clock, record=lambda kind, payload: records.append((kind, payload)))
        space.out(_node_ready("ingest"))
        first = space.take({"kind": "node.ready"}, 0.05, "w1", timeout=0)
        assert first is not None
        self.assertEqual(first.generation, 1)
        clock.advance(0.06)
        sibling = space.take({"kind": "node.ready"}, 10, "w2", timeout=0)
        assert sibling is not None
        self.assertEqual(sibling.generation, 2)
        self.assertEqual(sibling.tuple["node"], "ingest")
        self.assertTrue(space.ack(sibling.token))
        self.assertFalse(space.ack(first.token))
        kinds = [kind for kind, _payload in records]
        self.assertIn("space.lease_expired", kinds)
        expired = [payload for kind, payload in records if kind == "space.lease_expired"]
        self.assertEqual(expired[0]["worker"], "w1")

    def test_renew_extends_and_ack_does_not_ghost(self) -> None:
        clock = FakeClock()
        space = Space(clock=clock)
        space.out(_node_ready("ingest"))
        claim = space.take({"kind": "node.ready"}, 0.05, "w1", timeout=0)
        assert claim is not None
        for _ in range(10):
            clock.advance(0.02)
            self.assertTrue(space.renew(claim.token, 0.05))
            self.assertIsNone(space.take({"kind": "node.ready"}, 1, "w2", timeout=0))
        self.assertTrue(space.ack(claim.token))
        clock.advance(1)
        self.assertIsNone(space.rd({"kind": "node.ready"}))
        self.assertIsNone(space.take({"kind": "node.ready"}, 1, "w2", timeout=0))
        self.assertFalse(space.renew("missing", 1))
        self.assertFalse(space.renew(claim.token, 1))

    def test_stale_generation_write_is_fenced(self) -> None:
        clock = FakeClock()
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        space = Space(clock=clock)
        host = _host(root)
        host._space = space
        space.out(_node_ready("ingest"))
        first = space.take({"kind": "node.ready"}, 0.05, "w1", timeout=0)
        assert first is not None
        host._space_claim = first
        clock.advance(0.06)
        sibling = space.take({"kind": "node.ready"}, 1, "w2", timeout=0)
        assert sibling is not None
        with self.assertRaises(CapabilityError) as caught:
            host.write_file("stolen\n", "ingest.py")
        self.assertEqual(caught.exception.code, "fence")
        self.assertFalse((root / "ingest.py").exists())
        self.assertFalse(space.ack(first.token))
        self.assertTrue(space.ack(sibling.token))
        tmp.cleanup()


class SpaceContentionTests(unittest.TestCase):
    def test_double_take_under_contention(self) -> None:
        records: list[tuple[str, dict]] = []
        space = Space(record=lambda kind, payload: records.append((kind, payload)))
        space.out(_node_ready("registry"))
        claims: list = [None] * 8
        barriers = threading.Barrier(8)

        def worker(index: int) -> None:
            barriers.wait()
            claims[index] = space.take({"kind": "node.ready"}, 10, str(index), timeout=0.3)

        threads = [threading.Thread(target=worker, args=(index,)) for index in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        won = [claim for claim in claims if claim is not None]
        self.assertEqual(len(won), 1)
        self.assertEqual(space.bag_size(), 0)
        takes = [payload for kind, payload in records if kind == "space.take"]
        self.assertEqual(len(takes), 1)
        self.assertEqual(takes[0]["tuple_id"], won[0].tuple_id)

    def test_lost_wakeup_after_empty_take(self) -> None:
        space = Space()
        box: list = []

        def waiter() -> None:
            box.append(space.take({"kind": "node.ready"}, 5, "A", timeout=1))

        thread = threading.Thread(target=waiter)
        thread.start()
        _wait_until(lambda: space.waiter_count() >= 1)
        space.out(_node_ready("registry"))
        thread.join(timeout=1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(box), 1)
        self.assertIsNotNone(box[0])
        self.assertEqual(box[0].tuple["node"], "registry")

    def test_n_waiters_m_outs_unique_tuple_ids(self) -> None:
        space = Space()
        claims: list = []
        lock = threading.Lock()

        def waiter(index: int) -> None:
            claim = space.take({"kind": "node.ready"}, 5, f"w{index}", timeout=1)
            if claim is not None:
                with lock:
                    claims.append(claim)

        threads = [threading.Thread(target=waiter, args=(index,)) for index in range(5)]
        for thread in threads:
            thread.start()
        _wait_until(lambda: space.waiter_count() >= 5)
        for name in ("ingest", "offset", "scale"):
            space.out(_node_ready(name))
        _wait_until(lambda: len(claims) >= 3)
        self.assertEqual(len(claims), 3)
        self.assertEqual(len({claim.tuple_id for claim in claims}), 3)
        self.assertGreaterEqual(space.waiter_count(), 1)
        for thread in threads:
            thread.join(timeout=1.5)

    def test_fifo_waiter_a_before_b(self) -> None:
        space = Space()
        order: list[str] = []

        def waiter(name: str) -> None:
            claim = space.take({"kind": "node.ready"}, 5, name, timeout=1)
            if claim is not None:
                order.append(name)
                space.ack(claim.token)

        first = threading.Thread(target=waiter, args=("A",))
        second = threading.Thread(target=waiter, args=("B",))
        first.start()
        _wait_until(lambda: space.waiter_count() >= 1)
        second.start()
        _wait_until(lambda: space.waiter_count() >= 2)
        space.out(_node_ready("only"))
        first.join(timeout=1)
        _wait_until(lambda: order == ["A"])
        self.assertEqual(order, ["A"])
        space.out(_node_ready("later"))
        second.join(timeout=1)
        self.assertEqual(order, ["A", "B"])

    def test_specific_match_not_starved(self) -> None:
        space = Space()
        box: dict[str, object] = {}

        def broad() -> None:
            box["broad"] = space.take({"kind": "node.ready"}, 5, "broad", timeout=1)

        def specific() -> None:
            box["specific"] = space.take({"kind": "node.ready", "node": "registry"}, 5, "spec", timeout=1)

        t_broad = threading.Thread(target=broad)
        t_spec = threading.Thread(target=specific)
        t_broad.start()
        _wait_until(lambda: space.waiter_count() >= 1)
        t_spec.start()
        _wait_until(lambda: space.waiter_count() >= 2)
        space.out(_node_ready("registry"))
        t_spec.join(timeout=1)
        self.assertIsNotNone(box.get("specific"))
        self.assertEqual(box["specific"].tuple["node"], "registry")
        space.out(_node_ready("ingest"))
        t_broad.join(timeout=1)
        self.assertIsNotNone(box.get("broad"))

    def test_outs_after_pool_start_still_complete(self) -> None:
        space = Space()
        claims: list = []
        lock = threading.Lock()

        def worker(index: int) -> None:
            claim = space.take({"kind": "node.ready"}, 5, f"w{index}", timeout=1)
            if claim is not None:
                with lock:
                    claims.append(claim)
                space.ack(claim.token)

        threads = [threading.Thread(target=worker, args=(index,)) for index in range(4)]
        for thread in threads:
            thread.start()
        _wait_until(lambda: space.waiter_count() >= 4)
        for name in ("ingest", "offset", "scale"):
            space.out(_node_ready(name, wave=0))
        for thread in threads:
            thread.join(timeout=1)
        self.assertEqual(len(claims), 3)
        self.assertEqual(sorted(claim.tuple["node"] for claim in claims), ["ingest", "offset", "scale"])


class SpacePoisonTests(unittest.TestCase):
    def test_poison_tuple_is_refused_not_eventstream_terminal(self) -> None:
        buf = io.StringIO()
        stream = EventStream("run-1", buf)
        stream.emit("run.started", {"provider": "test", "id": "x"})
        records: list[tuple[str, dict]] = []
        space = Space(record=lambda kind, payload: records.append((kind, payload)))
        with self.assertRaises(SpaceError):
            space.out({"kind": "run.completed", "status": "succeeded"})
        space.out(_node_ready("registry"))
        self.assertEqual([kind for kind, _payload in records], ["space.out"])
        self.assertNotIn("run.completed", [kind for kind, _payload in records])
        stream.emit("run.completed", {"status": "succeeded"})
        result = consume_rho_v1(buf.getvalue(), "run-1")
        types = [event["type"] for event in result["events"]]
        self.assertEqual(types[0], "run.started")
        self.assertEqual(types[-1], "run.completed")
        self.assertEqual(types.count("run.completed"), 1)

    def test_store_none_and_optional_intern(self) -> None:
        space = Space(store=None)
        ident = space.out(_node_ready("x"))
        self.assertTrue(ident)
        tmp = tempfile.TemporaryDirectory()
        store = Store(Path(tmp.name) / "objects")
        space = Space(store=store)
        space.out(_node_ready("y"))
        self.assertGreaterEqual(store.object_count(), 1)
        tmp.cleanup()


class SpaceWaveIntegrationTests(unittest.TestCase):
    def test_space_graph01_serial_vs_dispatched_trees_byte_identical(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)

        def run_once(name: str, *, serial: bool) -> tuple[dict[str, str], dict, dict, list[dict]]:
            workspace = base / name / "ws"
            run_dir = base / name / "run"
            shutil.copytree(GRAPH_01 / "repo", workspace)
            _code, receipt = run_job(
                "complete the graph-01 pipeline",
                workspace,
                max_turns=1,
                run_dir=run_dir,
                planner_cmd=[sys.executable, str(GRAPH_PLANNER)],
                wave_workers=4,
                serial=serial,
                print_receipt=False,
            )
            discharge_path = workspace / ".sb" / "discharge_report.json"
            discharge = json.loads(discharge_path.read_text(encoding="utf-8")) if discharge_path.is_file() else {}
            events = read_events(run_dir / "trace.jsonl")
            return _tree_hashes(workspace), receipt, discharge, events

        serial_tree, serial_receipt, serial_discharge, serial_events = run_once("serial", serial=True)
        waved_tree, waved_receipt, waved_discharge, waved_events = run_once("waved", serial=False)
        self.assertEqual(serial_tree, waved_tree)
        self.assertEqual(_gate_shape(serial_discharge), _gate_shape(waved_discharge))
        self.assertEqual(serial_discharge.get("passed"), waved_discharge.get("passed"))
        self.assertEqual(serial_receipt.get("wave_count"), 3)
        self.assertEqual(serial_receipt.get("max_wave_width"), 3)
        self.assertEqual(serial_receipt.get("conflicts"), 0)
        self.assertEqual(waved_receipt.get("conflicts"), 0)
        for events in (serial_events, waved_events):
            takes = [event for event in events if event.get("type") == "space.take"]
            self.assertGreaterEqual(len(takes), 5)
            self.assertTrue(all(event["data"].get("worker") for event in takes))
            self.assertTrue(any(event.get("type") == "space.out" for event in events))
        kernel = (base / "serial" / "run" / "events.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("space.out", kernel)
        self.assertNotIn("space.take", kernel)
        tmp.cleanup()

    def test_space_n_workers_one_take_per_tuple(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name) / "ws"
        shutil.copytree(GRAPH_01 / "repo", root)
        host = _host(root)
        envelope = load_envelope(FIXTURE)
        request = {
            "workspace": str(root),
            "dictionary_dir": str(root / "dictionary"),
            "receipt_path": str(root / "receipt.json"),
            "trace_path": str(root / "trace.jsonl"),
            "wave_workers": 4,
        }
        (root / "dictionary").mkdir()
        run_forth(host, envelope, preflight=True, request=request, wave_workers=4)
        takes = [
            event["data"].get("node")
            for event in read_events(root / "trace.jsonl")
            if event.get("type") == "space.take"
        ]
        counts = Counter(takes)
        for node in ("ingest", "offset", "scale", "registry", "verify"):
            self.assertEqual(counts[node], 1, counts)
        tmp.cleanup()

    def test_space_injected_death_lease_expiry_sibling_completes(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)

        def run_case(name: str, *, kill: bool) -> tuple[dict[str, str], list[dict]]:
            root = base / name
            shutil.copytree(GRAPH_01 / "repo", root)
            host = _host(root)
            if kill:
                seen = {"ingest": False}

                def death(node_id: str) -> None:
                    if node_id == "ingest" and not seen["ingest"]:
                        seen["ingest"] = True
                        raise RuntimeError("injected worker death")

                host.node_death_hook = death
            envelope = load_envelope(FIXTURE)
            request = {
                "workspace": str(root),
                "dictionary_dir": str(root / "dictionary"),
                "receipt_path": str(root / "receipt.json"),
                "trace_path": str(root / "trace.jsonl"),
                "wave_workers": 1 if not kill else 4,
                "serial": not kill,
            }
            (root / "dictionary").mkdir()
            run_forth(
                host,
                envelope,
                preflight=True,
                request=request,
                wave_workers=1 if not kill else 4,
                serial=not kill,
            )
            return _tree_hashes(root), read_events(root / "trace.jsonl")

        serial_tree, _serial_events = run_case("serial", kill=False)
        waved_tree, events = run_case("death", kill=True)
        self.assertEqual(serial_tree, waved_tree)
        expired = [event for event in events if event.get("type") == "space.lease_expired"]
        self.assertTrue(expired)
        self.assertTrue(any(event["data"].get("node") == "ingest" for event in expired))
        self.assertTrue(any(event["data"].get("worker") for event in expired))
        writes = [
            event
            for event in events
            if event.get("type") == "tool.call"
            and event.get("data", {}).get("tool") == "WRITE-FILE"
            and event.get("data", {}).get("path") == "pipeline/ingest.py"
        ]
        self.assertEqual(len(writes), 1)
        ingest_takes = [
            event["data"].get("generation")
            for event in events
            if event.get("type") == "space.take" and event.get("data", {}).get("node") == "ingest"
        ]
        self.assertEqual(ingest_takes, [1, 2])
        tmp.cleanup()

    def test_space_backpressure_observation_matches_pre_space(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        base = Path(tmp.name)
        workspace = base / "ws"
        run_dir = base / "run"
        obs_path = base / "obs.json"
        planner = base / "planner.py"
        workspace.mkdir()
        planner.write_text(REJECT_PLANNER, encoding="utf-8")
        goal = "reject then continue"
        run_job(
            goal,
            workspace,
            max_turns=2,
            run_dir=run_dir,
            planner_cmd=[sys.executable, str(planner), str(obs_path)],
            print_receipt=False,
        )
        rows = json.loads(obs_path.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(rows), 2)
        episode2 = rows[1]
        rejects = [
            json.loads(line)
            for line in (run_dir / "rejects.jsonl").read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        self.assertTrue(rejects)
        errors = [str(item) for item in rejects[0]["errors"]]
        expected = {
            "dictionary": str((run_dir / "dictionary").resolve()),
            "episode": 2,
            "errors": errors,
            "extra": critic_extra(errors),
            "goal": goal,
            "run_dir": str(run_dir.resolve()),
            "workspace": str(workspace.resolve()),
        }
        self.assertEqual(episode2, expected)
        kinds = {json.loads(line)["kind"] for line in (run_dir / "events.jsonl").read_text().splitlines() if line.strip()}
        self.assertTrue(kinds <= EVENT_KINDS)
        self.assertNotIn("space.out", kinds)
        replayed = replay(
            [
                Event(kind=item["kind"], sequence=item["sequence"], payload=item.get("payload") or {})
                for item in (
                    json.loads(line)
                    for line in (run_dir / "events.jsonl").read_text().splitlines()
                    if line.strip()
                )
            ]
        )
        self.assertEqual(replayed.revision, replayed.used + (replayed.revision - replayed.used))
        self.assertGreaterEqual(replayed.revision, 1)
        tmp.cleanup()

    def test_space_rho_stream_still_scudcheck(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        request = _canned_request("space-rho-1", "Write a small Python fizzbuzz in this directory.", workspace)
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "run",
                "--request-file",
                "-",
                "--events",
                "jsonl",
                "--run-dir",
                str(run_dir),
                "--planner-cmd",
                sys.executable,
                str(FIZZBUZZ_PLANNER),
            ],
            input=json.dumps(request),
            cwd=str(workspace),
            capture_output=True,
            text=True,
            check=False,
            env=_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        result = consume_rho_v1(proc.stdout, "space-rho-1")
        types = [event["type"] for event in result["events"]]
        self.assertEqual(types[0], "run.started")
        self.assertEqual(types[-1], "run.completed")
        self.assertEqual(sum(1 for item in types if item in {"run.completed", "run.failed", "run.cancelled"}), 1)
        self.assertIn("livingdict.receipt", types)
        self.assertLess(types.index("livingdict.receipt"), types.index("run.completed"))
        completed = result["events"][-1]
        self.assertEqual(completed["data"].get("status"), "succeeded")
        self.assertNotIn("ok", completed["data"])
        self.assertNotIn("changed_files", completed["data"])
        gold = _scudcheck(proc.stdout, "space-rho-1")
        if gold is not None:
            self.assertEqual(gold.returncode, 0, gold.stderr)
        tmp.cleanup()

    def test_space_ldeval_adapter_unchanged(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "workspace"
        run_dir = Path(tmp.name) / "run"
        shutil.copytree(GRAPH_01 / "repo", workspace)
        (run_dir / "dictionary").mkdir(parents=True)
        request = {
            "protocol_version": "1.0",
            "run_id": "space-adapter",
            "arm": "forth-shen",
            "memory_mode": "cold",
            "resume": False,
            "task": {
                "id": "graph-01",
                "family": "graph_coordination",
                "sequence": 1,
                "allowed_effects": ["read", "write", "exec"],
                "allowed_globs": ["pipeline/*.py"],
                "forbidden_globs": ["task_graph.json", "tests/**", "TASK.md"],
            },
            "workspace": str(workspace),
            "prompt_path": str(workspace / "TASK.md"),
            "trace_path": str(run_dir / "trace.jsonl"),
            "receipt_path": str(run_dir / "receipt.json"),
            "dictionary_dir": str(run_dir / "dictionary"),
        }
        previous = os.environ.get("LIVINGDICT_ENVELOPE")
        os.environ["LIVINGDICT_ENVELOPE"] = str(FIXTURE)
        try:
            code = run_request(request, preflight=True)
        finally:
            if previous is None:
                os.environ.pop("LIVINGDICT_ENVELOPE", None)
            else:
                os.environ["LIVINGDICT_ENVELOPE"] = previous
        self.assertEqual(code, 0)
        receipt = json.loads((run_dir / "receipt.json").read_text(encoding="utf-8"))
        for key in ("protocol_version", "run_id", "task_id", "success"):
            self.assertIn(key, receipt)
        self.assertEqual(receipt["protocol_version"], "1.0")
        checkpoint = json.loads((run_dir / "checkpoint.json").read_text(encoding="utf-8"))
        self.assertIn("envelope", checkpoint)
        self.assertIn("workspace", checkpoint)
        self.assertEqual(set(checkpoint), {"envelope", "workspace"})
        host = _host(workspace)
        words = set(ForthVM(host).words)
        self.assertNotIn("TAKE", words)
        self.assertNotIn("OUT", words)
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
