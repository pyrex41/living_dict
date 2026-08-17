from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from livingdict.bip340 import verify as bip340_verify
from livingdict.cli import resolve_argv_files
from livingdict.rho import (
    GrantError,
    GrantExpired,
    StreamError,
    canonical_json,
    consume_rho_v1,
    request_sha256,
    unsigned_request_bytes,
    verify_witness,
)


REPO = Path(__file__).resolve().parents[2]
CLI = REPO / "client" / "cli.py"
PLANNER = Path(__file__).resolve().parent / "fizzbuzz_planner.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
COMPLETED = FIXTURES / "completed.jsonl"
INVALID_AFTER = FIXTURES / "invalid_after_terminal.jsonl"
WIRE_REQUEST = FIXTURES / "wire_request.json"
SCUDCHECK = REPO / "tools" / "scudcheck"
CANONICAL_FIXTURE = (
    b'{"grant":{"expires_at":"2030-01-01T00:00:00Z","grant_id":"scud-local",'
    b'"models":["fizzbuzz"],"network":{"mode":"provider_only"},"providers":["test"],'
    b'"read_roots":["/tmp/ld-rho-ws"],"tools":[],"write_roots":["/tmp/ld-rho-ws"]},'
    b'"input":[{"content":[{"text":"hello","type":"text"}],"role":"user"}],'
    b'"limits":{},"model":{"id":"fizzbuzz","provider":"test"},'
    b'"protocol":"rho.run/v1","run_id":"fixture-grant-1"}'
)
CANONICAL_FIXTURE_SHA256 = "b36a5db83604361d77dcf61afab6a069ded6527f70b6b443fb18cf425e97dff2"
PUBKEY = "F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9"


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
        "input": [
            {
                "role": "user",
                "content": [{"type": "text", "text": prompt}],
            }
        ],
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
        "unexpected_field": {"keep": True},
    }


class ConsumeRhoV1CheckerTests(unittest.TestCase):
    def test_completed_fixture_is_valid(self) -> None:
        result = consume_rho_v1(COMPLETED.read_text(encoding="utf-8"), "fixture-1")
        self.assertEqual(result["outcome"], "completed")
        self.assertEqual(result["text"], "hello")
        self.assertEqual(result["usage"]["input_tokens"], 4)
        types = [event["type"] for event in result["events"]]
        self.assertEqual(types, ["run.started", "message.delta", "run.completed"])

    def test_invalid_after_terminal_is_rejected(self) -> None:
        stream = INVALID_AFTER.read_text(encoding="utf-8")
        with self.assertRaises(StreamError) as caught:
            consume_rho_v1(stream, "fixture-2")
        self.assertIn("after terminal", str(caught.exception))
        gold = _scudcheck(stream, "fixture-2")
        if gold is not None:
            self.assertNotEqual(gold.returncode, 0, gold.stderr)

    def test_receipt_shaped_completed_is_rejected(self) -> None:
        stream = (
            '{"protocol":"rho.run/v1","run_id":"run-1","seq":1,"time":"now",'
            '"type":"run.completed","data":{"run_id":"run-1","text":"ok",'
            '"outcome":"completed","status":"completed","ok":true}}\n'
        )
        with self.assertRaises(StreamError) as caught:
            consume_rho_v1(stream, "run-1")
        self.assertIn("invalid run.completed payload", str(caught.exception))

    def test_completed_requires_status_succeeded(self) -> None:
        stream = (
            '{"protocol":"rho.run/v1","run_id":"run-1","seq":1,"time":"now",'
            '"type":"run.completed","data":{}}\n'
        )
        with self.assertRaises(StreamError) as caught:
            consume_rho_v1(stream, "run-1")
        self.assertIn("invalid run.completed payload", str(caught.exception))

    def test_failed_requires_code_and_message(self) -> None:
        stream = (
            '{"protocol":"rho.run/v1","run_id":"run-1","seq":1,"time":"now",'
            '"type":"run.failed","data":{"reason":"nope"}}\n'
        )
        with self.assertRaises(StreamError) as caught:
            consume_rho_v1(stream, "run-1")
        self.assertIn("invalid run.failed payload", str(caught.exception))

    def test_cancelled_requires_reason(self) -> None:
        stream = (
            '{"protocol":"rho.run/v1","run_id":"run-1","seq":1,"time":"now",'
            '"type":"run.cancelled","data":{}}\n'
        )
        with self.assertRaises(StreamError) as caught:
            consume_rho_v1(stream, "run-1")
        self.assertIn("invalid run.cancelled payload", str(caught.exception))

    def test_wrong_protocol_and_run_id_and_seq(self) -> None:
        with self.assertRaises(StreamError):
            consume_rho_v1(
                '{"protocol":"rho.run/v2","run_id":"run-1","seq":1,"time":"now",'
                '"type":"run.cancelled","data":{"reason":"stop"}}\n',
                "run-1",
            )
        with self.assertRaises(StreamError):
            consume_rho_v1(
                '{"protocol":"rho.run/v1","run_id":"other","seq":1,"time":"now",'
                '"type":"run.cancelled","data":{"reason":"stop"}}\n',
                "run-1",
            )
        with self.assertRaises(StreamError):
            consume_rho_v1(
                "\n".join(
                    [
                        '{"protocol":"rho.run/v1","run_id":"run-1","seq":2,"time":"now","type":"run.started","data":{}}',
                        '{"protocol":"rho.run/v1","run_id":"run-1","seq":2,"time":"now","type":"run.cancelled","data":{"reason":"stop"}}',
                    ]
                ),
                "run-1",
            )
        with self.assertRaises(StreamError):
            consume_rho_v1(
                '{"protocol":"rho.run/v1","run_id":"run-1","seq":1,"time":"now","type":"run.started","data":{}}\n',
                "run-1",
            )

    def test_message_delta_requires_text(self) -> None:
        stream = (
            '{"protocol":"rho.run/v1","run_id":"run-1","seq":1,"time":"now",'
            '"type":"message.delta","data":{"delta":"x"}}\n'
            '{"protocol":"rho.run/v1","run_id":"run-1","seq":2,"time":"now",'
            '"type":"run.completed","data":{"status":"succeeded"}}\n'
        )
        with self.assertRaises(StreamError) as caught:
            consume_rho_v1(stream, "run-1")
        self.assertIn("decode message.delta", str(caught.exception))


class CanonicalAndGrantTests(unittest.TestCase):
    def test_canonical_json_sorts_nested_keys(self) -> None:
        got = canonical_json(b'{"z":1,"nested":{"b":2,"a":1},"a":0}')
        self.assertEqual(got, b'{"a":0,"nested":{"a":1,"b":2},"z":1}')

    def test_canonical_fixture_request_is_stable(self) -> None:
        raw = json.loads(WIRE_REQUEST.read_text(encoding="utf-8"))
        first = unsigned_request_bytes(raw)
        self.assertEqual(first, CANONICAL_FIXTURE)
        self.assertNotIn(b"witness", first)
        self.assertEqual(unsigned_request_bytes(raw), first)
        self.assertEqual(request_sha256(raw), CANONICAL_FIXTURE_SHA256)
        self.assertEqual(canonical_json(first), first)

    def test_verify_witness_refuses_missing_witness(self) -> None:
        raw = json.loads(WIRE_REQUEST.read_text(encoding="utf-8"))
        raw["grant"].pop("witness", None)
        with self.assertRaises(GrantError) as caught:
            verify_witness(raw, pubkey=PUBKEY)
        self.assertIn("grant.witness is required", str(caught.exception))
        self.assertNotIsInstance(caught.exception, GrantExpired)

    def test_verify_witness_refuses_expired_grant(self) -> None:
        raw = json.loads(WIRE_REQUEST.read_text(encoding="utf-8"))
        raw["grant"]["expires_at"] = "2020-01-01T00:00:00Z"
        with self.assertRaises(GrantExpired) as caught:
            verify_witness(raw, pubkey=PUBKEY)
        self.assertIn("expires_at", str(caught.exception))

    def test_verify_witness_refuses_pubkey_mismatch(self) -> None:
        raw = json.loads(WIRE_REQUEST.read_text(encoding="utf-8"))
        raw["grant"]["issuer_pubkey"] = "11" * 32
        with self.assertRaises(GrantError) as caught:
            verify_witness(raw, pubkey=PUBKEY)
        self.assertIn("does not match", str(caught.exception))

    def test_bip340_official_vector_0(self) -> None:
        message = bytes(32)
        signature = (
            "E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215"
            "25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"
        )
        self.assertTrue(bip340_verify(PUBKEY, message, signature))
        self.assertFalse(bip340_verify(PUBKEY, b"\x01" * 32, signature))


class RunnerContractTests(unittest.TestCase):
    def test_fizzbuzz_wire_request_stream(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        request = _canned_request(
            "fizzbuzz-1",
            "Write a small Python fizzbuzz in this directory.",
            workspace,
        )
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
                str(PLANNER),
            ],
            input=json.dumps(request),
            cwd=str(workspace),
            capture_output=True,
            text=True,
            check=False,
            env=_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        result = consume_rho_v1(proc.stdout, "fizzbuzz-1")
        types = [event["type"] for event in result["events"]]
        self.assertEqual(types[0], "run.started")
        self.assertEqual(types[-1], "run.completed")
        self.assertEqual(types.count("run.completed"), 1)
        self.assertNotIn("run.failed", types)
        self.assertNotIn("run.cancelled", types)
        self.assertIn("livingdict.receipt", types)
        self.assertLess(types.index("livingdict.receipt"), types.index("run.completed"))
        self.assertIn("episode.planned", types)
        self.assertIn("artifacts.applied", types)
        self.assertIn("gates.measured", types)
        completed = result["events"][-1]
        self.assertEqual(completed["data"].get("status"), "succeeded")
        self.assertNotIn("ok", completed["data"])
        self.assertNotIn("changed_files", completed["data"])
        self.assertEqual(result["outcome"], "completed")
        receipt = next(event["data"] for event in result["events"] if event["type"] == "livingdict.receipt")
        self.assertEqual(receipt.get("request_sha256"), request_sha256(request))
        self.assertNotIn("signature_verified", receipt)
        self.assertNotIn("grant_verification", receipt)
        for name in ("fizzbuzz.py", "test_fizzbuzz.py", "README.md"):
            self.assertTrue((workspace / name).is_file(), name)
        gold = _scudcheck(proc.stdout, "fizzbuzz-1")
        if gold is not None:
            self.assertEqual(gold.returncode, 0, gold.stderr)
        tmp.cleanup()

    def test_relative_planner_cmd_survives_cwd_flag(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        request = _canned_request(
            "fizzbuzz-rel",
            "Write a small Python fizzbuzz in this directory.",
            workspace,
        )
        proc = subprocess.run(
            [
                sys.executable,
                str(CLI),
                "run",
                "--request-file",
                "-",
                "--events",
                "jsonl",
                "--cwd",
                str(workspace),
                "--run-dir",
                str(run_dir),
                "--planner-cmd",
                sys.executable,
                "harness/tests/fizzbuzz_planner.py",
            ],
            input=json.dumps(request),
            cwd=str(REPO),
            capture_output=True,
            text=True,
            check=False,
            env=_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        result = consume_rho_v1(proc.stdout, "fizzbuzz-rel")
        self.assertEqual(result["outcome"], "completed")
        self.assertTrue((workspace / "fizzbuzz.py").is_file())
        tmp.cleanup()

    def test_resolve_argv_files_uses_invocation_dir_not_workspace(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        workspace.mkdir()
        relative = "harness/tests/fizzbuzz_planner.py"
        resolved = resolve_argv_files(["python3", relative], REPO)
        self.assertEqual(resolved[0], "python3")
        self.assertEqual(Path(resolved[1]), PLANNER.resolve())
        self.assertTrue(Path(resolved[1]).is_absolute())
        from_empty = resolve_argv_files(["python3", relative], workspace)
        self.assertEqual(Path(from_empty[1]), PLANNER.resolve())
        tmp.cleanup()

    def test_missing_model_fails_on_the_wire(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name)
        request = {
            "protocol": "rho.run/v1",
            "run_id": "bad-model",
            "model": {"provider": "test"},
            "input": [{"role": "user", "content": [{"type": "text", "text": "x"}]}],
            "limits": {},
            "grant": {"grant_id": "", "expires_at": ""},
        }
        proc = subprocess.run(
            [sys.executable, str(CLI), "run", "--request-file", "-", "--events", "jsonl"],
            input=json.dumps(request),
            cwd=str(workspace),
            capture_output=True,
            text=True,
            check=False,
            env=_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = consume_rho_v1(proc.stdout, "bad-model")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["failure"]["code"], "invalid_request")
        tmp.cleanup()


class GrantGateTests(unittest.TestCase):
    def test_require_mode_refuses_without_witness(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        request = _canned_request("grant-missing", "Write fizzbuzz.", workspace)
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
                str(PLANNER),
            ],
            input=json.dumps(request),
            cwd=str(workspace),
            capture_output=True,
            text=True,
            check=False,
            env=_env(RHO_PROTOCOL_GRANT_MODE="require", RHO_PROTOCOL_GRANT_PUBKEY=PUBKEY),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        result = consume_rho_v1(proc.stdout, "grant-missing")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["failure"]["code"], "grant_invalid")
        self.assertIn("grant.witness", result["failure"]["message"])
        self.assertFalse((workspace / "fizzbuzz.py").exists())
        receipt = next(event["data"] for event in result["events"] if event["type"] == "livingdict.receipt")
        self.assertEqual(receipt.get("request_sha256"), request_sha256(request))
        self.assertNotIn("grant_verification", receipt)
        self.assertNotIn("signature_verified", receipt)
        tmp.cleanup()

    def test_expired_grant_is_refused(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        run_dir = Path(tmp.name) / "run"
        workspace.mkdir()
        request = _canned_request("grant-expired", "Write fizzbuzz.", workspace)
        request["grant"]["expires_at"] = "2020-01-01T00:00:00Z"
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
                str(PLANNER),
            ],
            input=json.dumps(request),
            cwd=str(workspace),
            capture_output=True,
            text=True,
            check=False,
            env=_env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + "\n" + proc.stderr)
        result = consume_rho_v1(proc.stdout, "grant-expired")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["failure"]["code"], "grant_expired")
        self.assertFalse((workspace / "fizzbuzz.py").exists())
        receipt = next(event["data"] for event in result["events"] if event["type"] == "livingdict.receipt")
        self.assertEqual(receipt.get("request_sha256"), request_sha256(request))
        tmp.cleanup()

    def test_require_mode_expired_grant_refused_before_effects(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        workspace = Path(tmp.name) / "ws"
        workspace.mkdir()
        request = _canned_request("grant-expired-req", "Write fizzbuzz.", workspace)
        request["grant"]["expires_at"] = "2020-01-01T00:00:00Z"
        request["grant"]["witness"] = "00" * 64
        proc = subprocess.run(
            [sys.executable, str(CLI), "run", "--request-file", "-", "--events", "jsonl"],
            input=json.dumps(request),
            cwd=str(workspace),
            capture_output=True,
            text=True,
            check=False,
            env=_env(RHO_PROTOCOL_GRANT_MODE="require", RHO_PROTOCOL_GRANT_PUBKEY=PUBKEY),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = consume_rho_v1(proc.stdout, "grant-expired-req")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["failure"]["code"], "grant_expired")
        self.assertFalse((workspace / "fizzbuzz.py").exists())
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
