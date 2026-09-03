from __future__ import annotations

import unittest
from unittest.mock import patch

from job import ensure_job_files, ensure_run_gates, imply_artifact_writes
from planner import (
    SYSTEM,
    _consume_stream,
    extract_json_object,
    normalize_envelope,
    observe_dictionary,
    observe_graph,
    observe_workspace,
    parse_stream_chunk,
    repair_context,
    GATE_AUDIT_SYSTEM,
    _chat_request,
    _anthropic_api,
    _codex_oauth,
    _openai_api,
    api_base,
    model,
    normalize_cache_scope,
    provider,
    provider_cache_key,
)


class PlannerParseTests(unittest.TestCase):
    def test_strips_fence(self) -> None:
        raw = '```json\n{"language":"forth","program":"3 4 + RECEIPT","artifacts":{}}\n```'
        env = normalize_envelope(extract_json_object(raw))
        self.assertEqual(env["program"], "3 4 + RECEIPT")
        self.assertEqual(env["artifacts"], {})

    def test_embedded_object(self) -> None:
        raw = 'here you go\n{"program":"RECEIPT","artifacts":{"a":"b"},"rationale":"ok"}\nthanks'
        env = normalize_envelope(extract_json_object(raw))
        self.assertEqual(env["artifacts"]["a"], "b")
        self.assertEqual(env["rationale"], "ok")
        self.assertNotIn("continue", env)

    def test_ignores_model_continue_field(self) -> None:
        env = normalize_envelope(
            extract_json_object('{"program":"RECEIPT","continue":true}')
        )
        self.assertNotIn("continue", env)

    def test_system_omits_continue_and_job_file_traps(self) -> None:
        self.assertNotIn("continue:", SYSTEM)
        self.assertNotIn("GOAL.md", SYSTEM)
        self.assertNotIn("PROGRESS.md", SYSTEM)

    def test_system_documents_nodes(self) -> None:
        self.assertIn("nodes:", SYSTEM)
        self.assertIn("depends_on", SYSTEM)
        self.assertIn("Kahn", SYSTEM)

    def test_system_requires_behavioral_acceptance_claim(self) -> None:
        self.assertIn('"kind":"check"', SYSTEM)
        self.assertIn("Source/file/absent claims are", SYSTEM)
        self.assertIn("MUST include a check that invokes the product", SYSTEM)

    def test_repair_context_preserves_failure_and_contract(self) -> None:
        text = repair_context(
            {
                "contract": {"claims": []},
                "last_failure": {"failed_claims": [{"id": "run"}]},
            }
        )
        self.assertIn("contract is frozen", text)
        self.assertIn("failed_claims", text)

    def test_gate_audit_forbids_weakening(self) -> None:
        self.assertIn('"add_claims"', GATE_AUDIT_SYSTEM)
        self.assertIn("Never delete", GATE_AUDIT_SYSTEM)

    def test_normalize_keeps_nodes_and_allows_empty_program(self) -> None:
        env = normalize_envelope(
            {
                "program": "",
                "nodes": [
                    {
                        "id": "ingest",
                        "writes": ["pipeline/ingest.py"],
                        "depends_on": [],
                        "program": "RECEIPT",
                    }
                ],
                "artifacts": {"pipeline/ingest.py": "x\n"},
            }
        )
        self.assertEqual(env["program"], "")
        self.assertEqual(env["nodes"][0]["id"], "ingest")
        self.assertEqual(env["nodes"][0]["writes"], ["pipeline/ingest.py"])

    def test_observe_empty_product_and_dictionary(self) -> None:
        tmp = __import__("tempfile").TemporaryDirectory()
        root = __import__("pathlib").Path(tmp.name)
        self.assertIn("empty product", observe_workspace(root))
        self.assertIn("empty dictionary", observe_dictionary(root))
        (root / "words").mkdir()
        (root / "words" / "PATCH.fs").write_text(": PATCH ;\n", encoding="utf-8")
        self.assertIn("PATCH", observe_dictionary(root))
        (root / "task_graph.json").write_text('{"nodes":[]}\n', encoding="utf-8")
        self.assertIn('"nodes"', observe_graph(root))
        tmp.cleanup()

    def test_episode_one_does_not_write_job_files_into_workspace(self) -> None:
        tmp = __import__("tempfile").TemporaryDirectory()
        root = __import__("pathlib").Path(tmp.name)
        ensure_job_files(root, "build a compiler", 1)
        self.assertTrue(root.is_dir())
        self.assertFalse((root / "GOAL.md").exists())
        self.assertFalse((root / "PROGRESS.md").exists())
        ensure_job_files(root, "something else", 2)
        self.assertFalse((root / "GOAL.md").exists())
        self.assertFalse((root / "PROGRESS.md").exists())
        tmp.cleanup()

    def test_ensure_run_gates_inserts_before_receipt(self) -> None:
        self.assertIn("RUN-GATES", ensure_run_gates("RECEIPT"))
        self.assertEqual(ensure_run_gates("RUN-GATES RECEIPT"), "RUN-GATES RECEIPT")
        self.assertTrue(ensure_run_gates('S" a" INSTALL').endswith("RUN-GATES RECEIPT"))

    def test_imply_artifact_writes_zips_plain_write_file(self) -> None:
        program = 'S" fizzbuzz.py" WRITE-FILE\nRUN-GATES\nRECEIPT'
        out = imply_artifact_writes(program, {"fizzbuzz.py": "def fizzbuzz(n): ...\n"})
        self.assertIn("USE-ARTIFACT", out)
        self.assertIn('S" fizzbuzz.py" WRITE-FILE', out)
        already = 'S" fizzbuzz.py" USE-ARTIFACT S" fizzbuzz.py" WRITE-FILE'
        self.assertEqual(imply_artifact_writes(already, {"fizzbuzz.py": "x"}), already)

    def test_provider_cache_keys_are_scoped_and_hashed(self) -> None:
        first = provider_cache_key("run", run_id="a", phase="planner", system=SYSTEM)
        again = provider_cache_key("run", run_id="a", phase="planner", system=SYSTEM)
        other = provider_cache_key("run", run_id="b", phase="planner", system=SYSTEM)
        shared = provider_cache_key(
            "shared", run_id=None, phase="planner", system=SYSTEM
        )
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)
        self.assertTrue(shared and shared.startswith("ld-"))
        self.assertIsNone(
            provider_cache_key("off", run_id="a", phase="planner", system=SYSTEM)
        )

    def test_xai_affinity_header_is_only_sent_when_key_exists(self) -> None:
        payload = {"model": "grok-4.6", "messages": []}
        request = _chat_request(payload, "secret", "ld-test")
        headers = {key.lower(): value for key, value in request.header_items()}
        self.assertEqual(headers["x-grok-conv-id"], "ld-test")
        request = _chat_request(payload, "secret")
        headers = {key.lower(): value for key, value in request.header_items()}
        self.assertNotIn("x-grok-conv-id", headers)

    def test_cache_scope_validation(self) -> None:
        self.assertEqual(normalize_cache_scope("RUN"), "run")
        with self.assertRaises(Exception):
            normalize_cache_scope("global")

    def test_provider_defaults_and_aliases(self) -> None:
        with patch.dict("os.environ", {"LIVINGDICT_PROVIDER": "claude"}, clear=False):
            self.assertEqual(provider(), "anthropic")
            self.assertEqual(model(), "claude-sonnet-4-5")
            self.assertEqual(api_base(), "https://api.anthropic.com/v1")

    @patch("planner._json_request")
    def test_openai_uses_responses_api(self, request) -> None:
        request.return_value = {
            "output": [{"content": [{"type": "output_text", "text": '{"ok":true}'}]}],
            "usage": {"input_tokens": 3, "output_tokens": 2},
        }
        with patch.dict(
            "os.environ",
            {"LIVINGDICT_PROVIDER": "openai", "OPENAI_API_KEY": "key"},
            clear=False,
        ):
            text, usage, auth = _openai_api(
                [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}]
            )
        self.assertEqual(text, '{"ok":true}')
        self.assertEqual(auth, "api_key")
        self.assertEqual(usage["input_tokens"], 3)
        self.assertTrue(request.call_args.args[0].endswith("/responses"))

    @patch("planner._json_request")
    def test_anthropic_uses_messages_api(self, request) -> None:
        request.return_value = {
            "content": [{"type": "text", "text": '{"ok":true}'}],
            "usage": {},
        }
        with patch.dict(
            "os.environ",
            {"LIVINGDICT_PROVIDER": "anthropic", "ANTHROPIC_API_KEY": "key"},
            clear=False,
        ):
            text, _usage, auth = _anthropic_api(
                [{"role": "system", "content": "s"}, {"role": "user", "content": "u"}]
            )
        self.assertEqual((text, auth), ('{"ok":true}', "api_key"))
        self.assertTrue(request.call_args.args[0].endswith("/messages"))
        self.assertEqual(request.call_args.args[2]["anthropic-version"], "2023-06-01")

    @patch("planner.subprocess.run")
    @patch("planner.shutil.which", return_value="/usr/bin/codex")
    def test_openai_oauth_delegates_to_codex(self, _which, run) -> None:
        run.return_value.returncode = 0
        run.return_value.stderr = ""
        run.return_value.stdout = "\n".join(
            [
                '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"ok\\":true}"}}',
                '{"type":"turn.completed","usage":{"input_tokens":4,"output_tokens":2}}',
            ]
        )
        with patch.dict("os.environ", {"LIVINGDICT_PROVIDER": "openai"}, clear=False):
            text, usage, auth = _codex_oauth([{"role": "system", "content": "s"}])
        self.assertEqual(text, '{"ok":true}')
        self.assertEqual(auth, "oauth")
        self.assertEqual(usage["output_tokens"], 2)
        self.assertIn("read-only", run.call_args.args[0])


class StreamParseTests(unittest.TestCase):
    def test_parse_stream_chunk_splits_reasoning_and_content(self) -> None:
        chunk = {
            "choices": [
                {"delta": {"reasoning_content": "hmm, ", "content": ""}},
                {"delta": {"content": '{"language"'}},
            ],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2},
        }
        content, reasoning, usage = parse_stream_chunk(chunk)
        self.assertEqual(content, '{"language"')
        self.assertEqual(reasoning, "hmm, ")
        self.assertEqual(usage["prompt_tokens"], 5)

    def test_consume_stream_accumulates_content_and_echoes_reasoning(self) -> None:
        import contextlib
        import io
        import json as _json

        def sse(obj) -> bytes:
            return b"data: " + _json.dumps(obj).encode("utf-8") + b"\n"

        lines = [
            sse({"choices": [{"delta": {"reasoning_content": "thinking about it\n"}}]}),
            sse({"choices": [{"delta": {"content": '{"language": "forth"'}}]}),
            sse({"choices": [{"delta": {"content": ', "program": ""}'}}]}),
            sse({"usage": {"prompt_tokens": 9, "completion_tokens": 4}, "choices": []}),
            b"data: [DONE]\n",
            sse({"choices": [{"delta": {"content": "IGNORED-AFTER-DONE"}}]}),
        ]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            content, usage = _consume_stream(lines)
        self.assertEqual(content, '{"language": "forth", "program": ""}')
        self.assertEqual(usage["completion_tokens"], 4)
        self.assertIn("thinking about it", err.getvalue())
        self.assertIn("envelope:", err.getvalue())
        self.assertNotIn("IGNORED-AFTER-DONE", content)


if __name__ == "__main__":
    unittest.main()
