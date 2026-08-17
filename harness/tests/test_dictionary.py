from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from livingdict.dictionary import compose_program, load_prelude, loaded_names, save_colon_words, used_names
from livingdict.envelope import PlanEnvelope
from livingdict.execute import run_forth
from livingdict.forth import ForthVM
from livingdict.host import CapabilityHost
from livingdict.trace import read_events


def _host(root: Path, trace: Path | None = None, receipt: Path | None = None) -> CapabilityHost:
    return CapabilityHost(
        workspace=root,
        allowed_effects=("read", "write", "exec"),
        allowed_globs=("**",),
        forbidden_globs=(),
        trace_path=trace,
        receipt_path=receipt,
    )


class DictionaryTests(unittest.TestCase):
    def test_save_load_roundtrip(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        ws = root / "ws"
        ws.mkdir()
        dictionary = root / "dictionary"
        vm = ForthVM(_host(ws))
        vm.interpret(": PATCH DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;")
        written = save_colon_words(dictionary, vm.colon)
        self.assertEqual(written, ["PATCH"])
        self.assertIn(": PATCH", (dictionary / "words" / "PATCH.fs").read_text(encoding="utf-8"))
        self.assertEqual(loaded_names(dictionary), ["PATCH"])
        self.assertIn("PATCH", load_prelude(dictionary))
        self.assertEqual(used_names("S\" a\" PATCH RECEIPT", ["PATCH"]), ["PATCH"])
        tmp.cleanup()

    def test_second_episode_reuses_colon_word(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        ws = root / "ws"
        ws.mkdir()
        dictionary = root / "dictionary"
        run = root / "run"
        run.mkdir()
        request = {
            "dictionary_dir": str(dictionary),
            "workspace": str(ws),
            "receipt_path": str(run / "receipt.json"),
            "trace_path": str(run / "trace.jsonl"),
        }
        host = _host(ws, run / "trace.jsonl", run / "receipt.json")
        first = PlanEnvelope(
            language="forth",
            program=': INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; '
            'S" hello.txt" INSTALL RECEIPT',
            artifacts={"hello.txt": "hi\n"},
        )
        run_forth(host, first, preflight=True, request=request)
        self.assertEqual((ws / "hello.txt").read_text(encoding="utf-8"), "hi\n")
        self.assertTrue((dictionary / "words" / "INSTALL.fs").is_file())

        host2 = _host(ws, run / "trace2.jsonl", run / "receipt2.json")
        request2 = dict(request)
        request2["trace_path"] = str(run / "trace2.jsonl")
        request2["receipt_path"] = str(run / "receipt2.json")
        second = PlanEnvelope(
            language="forth",
            program='S" hello.txt" INSTALL RECEIPT',
            artifacts={"hello.txt": "yo\n"},
        )
        extra = run_forth(host2, second, preflight=True, request=request2)
        self.assertEqual((ws / "hello.txt").read_text(encoding="utf-8"), "yo\n")
        self.assertIn("INSTALL", extra["defined"])
        kinds = [event["type"] for event in read_events(run / "trace2.jsonl")]
        self.assertIn("dictionary.retrieve", kinds)
        self.assertIn("dictionary.reuse", kinds)
        tmp.cleanup()

    def test_compose_empty_prelude(self) -> None:
        self.assertEqual(compose_program("", "RECEIPT"), "RECEIPT")


if __name__ == "__main__":
    unittest.main()
