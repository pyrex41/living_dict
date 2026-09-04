#!/usr/bin/env python3
"""Replay the 20260815T191456Z livingdict envelope (no USE-ARTIFACT)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
EPISODE = Path(__file__).resolve().parent / "fixtures" / "fizzbuzz_historical_episodes.json"
CLAIMS = REPO / "compare" / "fixtures" / "fizzbuzz" / "claims.json"

FIZZBUZZ_PY = '''def fizzbuzz(n):
    if n % 15 == 0:
        return "FizzBuzz"
    if n % 3 == 0:
        return "Fizz"
    if n % 5 == 0:
        return "Buzz"
    return str(n)


if __name__ == "__main__":
    for i in range(1, 21):
        print(fizzbuzz(i))
'''

TEST_PY = '''import unittest

from fizzbuzz import fizzbuzz


class TestFizzBuzz(unittest.TestCase):
    def test_1(self):
        self.assertEqual(fizzbuzz(1), "1")

    def test_3(self):
        self.assertEqual(fizzbuzz(3), "Fizz")

    def test_5(self):
        self.assertEqual(fizzbuzz(5), "Buzz")

    def test_15(self):
        self.assertEqual(fizzbuzz(15), "FizzBuzz")

    def test_16(self):
        self.assertEqual(fizzbuzz(16), "16")


if __name__ == "__main__":
    unittest.main()
'''

README = (
    "Run the tests with `python -m unittest test_fizzbuzz.py` from this "
    "directory. You can also print the first twenty values with `python fizzbuzz.py`.\n"
)


def main() -> int:
    sys.stdin.read()
    episodes = json.loads(EPISODE.read_text(encoding="utf-8"))
    program = episodes[0]["program"]
    if "USE-ARTIFACT" in program.upper():
        print("historical program must not contain USE-ARTIFACT", file=sys.stderr)
        return 2
    envelope = {
        "artifacts": {
            "README.md": README,
            "claims.json": CLAIMS.read_text(encoding="utf-8"),
            "fizzbuzz.py": FIZZBUZZ_PY,
            "test_fizzbuzz.py": TEST_PY,
        },
        "language": "forth",
        "program": program,
        "rationale": episodes[0].get("rationale") or "",
    }
    json.dump(envelope, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
