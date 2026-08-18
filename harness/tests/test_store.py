from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from livingdict.cli import run_job
from livingdict.dictionary import save_colon_words
from livingdict.forth import ForthVM
from livingdict.host import CapabilityHost
from livingdict.kernel import DICTIONARY_PROMOTED, EPISODE_PLANNED, Event, replay
from livingdict.policy import snapshot
from livingdict.store import (
    Store,
    StoreCorruption,
    StoreError,
    as_of,
    blob_digest,
    facts,
    objects_root,
    open_store,
    tree_bytes,
    tree_digest,
)


REPO = Path(__file__).resolve().parents[2]
FIZZBUZZ_PLANNER = Path(__file__).resolve().parent / "fizzbuzz_planner.py"
GRAPH_PLANNER = Path(__file__).resolve().parent / "graph_planner.py"
CLAIMS = REPO / "compare" / "fixtures" / "fizzbuzz" / "claims.json"
GRAPH_01 = REPO / "eval" / "tasks" / "graph-01"

CLI_RECEIPT_KEYS = {
    "changed_files",
    "decision",
    "discharged",
    "episodes",
    "gates",
    "ok",
    "reason",
    "run_dir",
    "workspace",
}
HOST_RECEIPT_KEYS = {
    "protocol_version",
    "run_id",
    "task_id",
    "success",
    "workspace_before",
    "workspace_after",
    "changed_files",
    "effects_used",
    "policy_violations",
}

COLON_PLANNER = r'''
import json, sys
sys.stdin.read()
json.dump({
    "language": "forth",
    "program": ": INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; S\" hello.txt\" INSTALL RECEIPT",
    "artifacts": {"hello.txt": "hi\n"},
    "rationale": "promote INSTALL",
}, sys.stdout)
sys.stdout.write("\n")
'''


def _load_events(path: Path) -> list[dict]:
    events: list[dict] = []
    if not path.is_file():
        return events
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        events.append(json.loads(line))
    return events


class StoreUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "objects"
        self.store = Store(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_intern_idempotent_and_object_count(self) -> None:
        first = self.store.intern(b"abc")
        second = self.store.intern(b"abc")
        self.assertEqual(first, second)
        self.assertEqual(first, blob_digest(b"abc"))
        self.assertEqual(self.store.object_count(), 1)
        self.assertTrue((self.root / first[:2] / first).is_file())

    def test_atomic_write_leaves_no_tmp(self) -> None:
        digest = self.store.intern(b"payload")
        leftovers = [path for path in self.root.rglob("*") if path.name.startswith(".tmp-")]
        self.assertEqual(leftovers, [])
        self.assertTrue(self.store.has(digest))

    def test_corrupt_blob_detected_on_get(self) -> None:
        digest = self.store.intern(b"clean")
        path = self.root / digest[:2] / digest
        path.write_bytes(b"dirty")
        with self.assertRaises(StoreCorruption):
            self.store.get(digest)

    def test_missing_blob_is_typed_error(self) -> None:
        missing = blob_digest(b"absent")
        with self.assertRaises(StoreError):
            self.store.get(missing)

    def test_canonical_tree_roundtrip(self) -> None:
        files = {"b.py": "bb", "a.py": "aa"}
        digest = self.store.intern_tree(files)
        self.assertEqual(self.store.get(digest), tree_bytes(files))
        self.assertEqual(self.store.get(digest), b'{"a.py":"aa","b.py":"bb"}')
        self.assertEqual(self.store.get_tree(digest), {"a.py": "aa", "b.py": "bb"})
        again = self.store.intern_tree({"a.py": "aa", "b.py": "bb"})
        self.assertEqual(digest, again)
        self.assertEqual(self.store.object_count(), 1)

    def test_livingdict_objects_shared_across_run_dirs(self) -> None:
        shared = Path(self.tmp.name) / "shared"
        run_a = Path(self.tmp.name) / "run-a"
        run_b = Path(self.tmp.name) / "run-b"
        previous = os.environ.get("LIVINGDICT_OBJECTS")
        os.environ["LIVINGDICT_OBJECTS"] = str(shared)
        try:
            self.assertEqual(objects_root(run_a), shared)
            self.assertEqual(objects_root(run_b), shared)
            store_a = open_store(run_a)
            store_b = open_store(run_b)
            assert store_a is not None and store_b is not None
            digest = store_a.intern(b"hello")
            self.assertTrue(store_b.has(digest))
            self.assertEqual(store_b.get(digest), b"hello")
            self.assertEqual(store_a.object_count(), store_b.object_count())
            self.assertEqual(store_a.object_count(), 1)
        finally:
            if previous is None:
                os.environ.pop("LIVINGDICT_OBJECTS", None)
            else:
                os.environ["LIVINGDICT_OBJECTS"] = previous

    def test_facts_and_as_of_from_payloads(self) -> None:
        files = {"fizzbuzz.py": blob_digest(b"x")}
        events = [
            Event(
                kind="episode.planned",
                sequence=1,
                payload={"fingerprint": "db4a76", "artifact_sha256": files, "program": "RECEIPT"},
            ),
            Event(kind="critic.rejected", sequence=2, payload={"errors": ["token 1: underflow"]}),
            Event(kind="artifacts.applied", sequence=3, payload={"keys": ["fizzbuzz.py"]}),
            Event(
                kind="gates.measured",
                sequence=4,
                payload={
                    "report": {"passed": True, "gates": [{"name": "claims", "passed": True}]},
                    "tree_after": tree_digest(files),
                    "tree_before": tree_digest({}),
                    "files": files,
                },
            ),
            Event(
                kind="dictionary.promoted",
                sequence=5,
                payload={"word": "INSTALL", "sha256": "ab12", "episode": 1},
            ),
        ]
        rows = facts(events)
        self.assertIn(("episode/1", ":episode/fingerprint", "db4a76", 1), rows)
        self.assertIn(("episode/1", ":critic/verdict", ":reject", 2), rows)
        self.assertIn(("episode/1", ":critic/error", "token 1: underflow", 2), rows)
        self.assertIn(("ws/fizzbuzz.py", ":file/content", f"blob:{files['fizzbuzz.py']}", 3), rows)
        self.assertIn(("run", ":gates/passed", True, 4), rows)
        self.assertIn(("word/INSTALL", ":word/content", "blob:ab12", 5), rows)
        self.assertIn(("word/INSTALL", ":word/promoted-by", "episode/1", 5), rows)
        self.assertEqual(as_of(events, 2), {})
        self.assertEqual(as_of(events, 3), files)
        self.assertEqual(as_of(events, 5), files)

    def test_as_of_mid_episode_overlays_applied_artifacts(self) -> None:
        """Artifacts applied after the last measured tree must show at their seq."""
        old = {"a.py": blob_digest(b"old")}
        new_digest = blob_digest(b"new")
        events = [
            Event(
                kind="episode.planned",
                sequence=1,
                payload={"fingerprint": "f1", "artifact_sha256": old, "program": "RECEIPT"},
            ),
            Event(kind="artifacts.applied", sequence=2, payload={"keys": ["a.py"]}),
            Event(
                kind="gates.measured",
                sequence=3,
                payload={"report": {"passed": True}, "files": old},
            ),
            Event(
                kind="episode.planned",
                sequence=4,
                payload={
                    "fingerprint": "f2",
                    "artifact_sha256": {"a.py": new_digest, "b.py": blob_digest(b"bee")},
                    "program": "RECEIPT",
                },
            ),
            Event(kind="artifacts.applied", sequence=5, payload={"keys": ["a.py", "b.py"]}),
        ]
        self.assertEqual(as_of(events, 3), old)
        mid = as_of(events, 5)
        self.assertEqual(mid["a.py"], new_digest)
        self.assertEqual(mid["b.py"], blob_digest(b"bee"))

    def test_replay_does_not_require_store(self) -> None:
        events = [
            Event(kind=EPISODE_PLANNED, payload={"fingerprint": "aa", "program": "RECEIPT"}),
            Event(kind=DICTIONARY_PROMOTED, payload={"word": "X", "sha256": "00", "episode": 1}),
        ]
        state = replay(events)
        self.assertEqual(state.revision, 2)
        self.assertEqual(as_of(events, 2), {})


class HostStoreTests(unittest.TestCase):
    def test_receipt_keeps_adapter_fields_and_adds_trees(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name) / "ws"
        run = Path(tmp.name) / "run"
        root.mkdir()
        run.mkdir()
        (root / "app").mkdir()
        (root / "app" / "config.py").write_text("OLD\n", encoding="utf-8")
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write", "exec"),
            allowed_globs=("app/config.py",),
            forbidden_globs=(),
            receipt_path=run / "receipt.json",
            run_id="test-run",
            task_id="config-01",
        )
        host.write_file("NEW\n", "app/config.py")
        body = host.receipt()
        for key in HOST_RECEIPT_KEYS:
            self.assertIn(key, body)
        self.assertEqual(body["protocol_version"], "1.0")
        self.assertEqual(body["changed_files"], ["app/config.py"])
        self.assertIn("tree_before", body)
        self.assertIn("tree_after", body)
        self.assertNotEqual(body["tree_before"], body["tree_after"])
        self.assertTrue(host._store.has(body["tree_after"]))
        self.assertEqual(host._store.get_tree(body["tree_after"]), snapshot(root))
        tmp.cleanup()

    def test_objects_inside_workspace_are_skipped_by_snapshot(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        host = CapabilityHost(
            workspace=root,
            allowed_effects=("read", "write"),
            allowed_globs=("**",),
            forbidden_globs=(),
            receipt_path=root / "receipt.json",
        )
        host.write_file("hi\n", "note.txt")
        files = snapshot(root)
        self.assertIn("note.txt", files)
        self.assertFalse(any(path.startswith("objects/") or "/objects/" in path for path in files))
        self.assertTrue((root / ".livingdict-run" / "objects").is_dir())
        tmp.cleanup()


class AsOfFizzbuzzTests(unittest.TestCase):
    def test_as_of_matches_recorded_snapshot_each_episode(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        code, receipt = run_job(
            "Write a small Python fizzbuzz in this directory.",
            workspace,
            max_turns=3,
            claims=CLAIMS,
            run_dir=run_dir,
            planner_cmd=[sys.executable, str(FIZZBUZZ_PLANNER)],
            print_receipt=False,
        )
        self.assertEqual(code, 0)
        for key in CLI_RECEIPT_KEYS:
            self.assertIn(key, receipt, key)
        self.assertTrue(receipt["ok"])
        self.assertIn("tree_before", receipt)
        self.assertIn("tree_after", receipt)
        events = _load_events(run_dir / "events.jsonl")
        store = Store(run_dir / "objects")
        live = snapshot(workspace)
        last_seq = max(event["sequence"] for event in events)
        self.assertEqual(as_of(events, last_seq, store), live)
        self.assertEqual(store.get_tree(receipt["tree_after"]), live)
        measured = False
        for event in events:
            seq = event["sequence"]
            reconstructed = as_of(events, seq, store)
            if event["kind"] == "gates.measured":
                measured = True
                recorded = event["payload"]["files"]
                tree_after = event["payload"]["tree_after"]
                self.assertEqual(reconstructed, recorded)
                self.assertEqual(store.get_tree(tree_after), recorded)
                self.assertEqual(tree_digest(recorded), tree_after)
            elif not measured and event["kind"] in {
                "episode.planned",
                "critic.accepted",
                "critic.rejected",
                "episode.blocked_duplicate",
            }:
                self.assertEqual(reconstructed, {})
        self.assertTrue(measured)
        replayed = replay(
            [
                Event(
                    kind=item["kind"],
                    sequence=item["sequence"],
                    payload=item.get("payload") or {},
                    id=item.get("id") or "",
                )
                for item in events
            ]
        )
        self.assertEqual(replayed.revision, last_seq)
        tmp.cleanup()


class EquivalenceTests(unittest.TestCase):
    def test_fizzbuzz_receipt_is_superset_of_prechange_keys(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        code, receipt = run_job(
            "Write a small Python fizzbuzz in this directory.",
            workspace,
            max_turns=3,
            claims=CLAIMS,
            run_dir=run_dir,
            planner_cmd=[sys.executable, str(FIZZBUZZ_PLANNER)],
            print_receipt=False,
        )
        self.assertEqual(code, 0)
        self.assertTrue(CLI_RECEIPT_KEYS.issubset(receipt))
        self.assertTrue(receipt["discharged"])
        self.assertEqual(receipt["decision"], "success")
        self.assertTrue((workspace / "fizzbuzz.py").is_file())
        tmp.cleanup()

    def test_graph01_receipt_is_superset_of_prechange_keys(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        shutil.copytree(GRAPH_01 / "repo", workspace)
        _code, receipt = run_job(
            "complete the graph-01 pipeline",
            workspace,
            max_turns=1,
            run_dir=run_dir,
            planner_cmd=[sys.executable, str(GRAPH_PLANNER)],
            serial=True,
            print_receipt=False,
        )
        self.assertTrue(CLI_RECEIPT_KEYS.issubset(receipt))
        self.assertIn("tree_before", receipt)
        self.assertIn("tree_after", receipt)
        self.assertTrue((run_dir / "objects").is_dir())
        events = _load_events(run_dir / "events.jsonl")
        self.assertTrue(any(event["kind"] == "gates.measured" for event in events))
        tmp.cleanup()


class DictionaryProvenanceTests(unittest.TestCase):
    def test_save_colon_words_interns_and_facts_follow_tx(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        ws = root / "ws"
        ws.mkdir()
        dictionary = root / "dictionary"
        store = Store(root / "objects")
        vm = ForthVM(
            CapabilityHost(
                workspace=ws,
                allowed_effects=("read", "write", "exec"),
                allowed_globs=("**",),
                forbidden_globs=(),
            )
        )
        vm.interpret(": INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;")
        written = save_colon_words(dictionary, vm.colon, store=store)
        self.assertEqual(written, ["INSTALL"])
        source = (dictionary / "words" / "INSTALL.fs").read_bytes()
        digest = blob_digest(source)
        self.assertTrue(store.has(digest))
        events = [
            {
                "kind": "episode.planned",
                "sequence": 1,
                "payload": {"fingerprint": "fp", "program": ": INSTALL ;"},
            },
            {
                "kind": "dictionary.promoted",
                "sequence": 2,
                "payload": {"episode": 1, "sha256": digest, "word": "INSTALL"},
            },
        ]
        rows = facts(events)
        self.assertIn(("word/INSTALL", ":word/content", f"blob:{digest}", 2), rows)
        self.assertIn(("word/INSTALL", ":word/promoted-by", "episode/1", 2), rows)
        tmp.cleanup()

    def test_run_job_records_promoted_word_on_tx_log(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        planner = Path(tmp.name) / "planner.py"
        workspace.mkdir()
        planner.write_text(COLON_PLANNER, encoding="utf-8")
        _code, receipt = run_job(
            "write hello",
            workspace,
            max_turns=1,
            run_dir=run_dir,
            planner_cmd=[sys.executable, str(planner)],
            print_receipt=False,
        )
        self.assertIn("ok", receipt)
        events = _load_events(run_dir / "events.jsonl")
        promoted = [event for event in events if event["kind"] == "dictionary.promoted"]
        self.assertEqual(len(promoted), 1)
        digest = promoted[0]["payload"]["sha256"]
        self.assertEqual(promoted[0]["payload"]["word"], "INSTALL")
        store = Store(run_dir / "objects")
        self.assertTrue(store.has(digest))
        rows = facts(events)
        self.assertTrue(any(row[:3] == ("word/INSTALL", ":word/content", f"blob:{digest}") for row in rows))
        self.assertTrue(any(row[:3] == ("word/INSTALL", ":word/promoted-by", "episode/1") for row in rows))
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
