from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("llm_cache_recorder", ROOT / "tools/llm_cache_recorder.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RecorderMetadataTests(unittest.TestCase):
    def test_records_hashes_and_shape_without_prompt_or_authorization(self) -> None:
        body = json.dumps(
            {
                "model": "grok-4.6",
                "messages": [{"role": "user", "content": "private prompt"}],
                "tools": [{"type": "function", "function": {"name": "read"}}],
            }
        ).encode()
        result = MODULE.request_metadata(
            body,
            {"Authorization": "Bearer secret", "x-grok-conv-id": "private-route"},
        )
        encoded = json.dumps(result)
        self.assertNotIn("private prompt", encoded)
        self.assertNotIn("secret", encoded)
        self.assertNotIn("private-route", encoded)
        self.assertTrue(result["has_x_grok_conv_id"])
        self.assertEqual(result["messages"][0]["role"], "user")

    def test_extracts_usage_from_stream(self) -> None:
        data = b'data: {"choices":[]}\n\ndata: {"usage":{"prompt_tokens":9}}\n\n'
        self.assertEqual(MODULE.usage_from_bytes(data), {"prompt_tokens": 9})


if __name__ == "__main__":
    unittest.main()
