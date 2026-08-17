#!/usr/bin/env python3
"""ldeval adapter: Forth + Shen-style preflight.

The eval-harness critic is Python (`livingdict.preflight`), matching
harness/shen/contracts.shen. The live shen-lua critic is
openresty/shen/preflight.shen, invoked by openresty/bin/livingdict-resty.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from livingdict.adapter import main


if __name__ == "__main__":
    raise SystemExit(main(preflight=True))
