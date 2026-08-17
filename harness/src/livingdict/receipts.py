"""Execution receipts written by the RECEIPT capability."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def write_receipt(path: Path, payload: dict[str, Any]) -> dict[str, Any]:
    body = {"protocol_version": "1.0", **payload}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return body
