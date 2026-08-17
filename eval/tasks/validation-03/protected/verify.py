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

from service.core import reconcile


def bad():
    for value in (-1, True, '3'):
        try: reconcile([{'amount':value}])
        except ValueError: continue
        raise AssertionError(value)
record('reject_invalid', bad)
record('empty', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile([]) != 0 else None)
print(json.dumps({'checks': checks}, sort_keys=True))
