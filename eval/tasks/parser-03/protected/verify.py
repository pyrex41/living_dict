import json
import sys
import traceback
from pathlib import Path

workspace = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(workspace))
checks = []

def record(name, fn):
    try:
        fn()
        checks.append({"name": name, "passed": True})
    except Exception as exc:
        checks.append({"name": name, "passed": False, "detail": f"{type(exc).__name__}: {exc}"})

from src.records import parse_record
record('quoted_delimiter', lambda: (_ for _ in ()).throw(AssertionError()) if parse_record("left,'middle,inside',right") != ('left', 'middle,inside', 'right') else None)
record('comment_rule', lambda: (_ for _ in ()).throw(AssertionError()) if parse_record('a,b,c # ignored') != ('a', 'b', 'c') else None)
record('crlf_and_space', lambda: (_ for _ in ()).throw(AssertionError()) if parse_record('  a , b , c  \r\n') != ('a', 'b', 'c') else None)
def wrong_count():
    try:
        parse_record('a,b')
    except ValueError:
        return
    raise AssertionError('wrong field count accepted')
record('wrong_count', wrong_count)

print(json.dumps({'checks': checks}, sort_keys=True))
