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

record('beyond_end', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile([1,2],5,2) != [] else None)

def invalid():
    for pair in [(-1,1),(0,0),(True,1)]:
        try: reconcile([1],*pair)
        except ValueError: continue
        raise AssertionError(pair)
record('invalid_bounds', invalid)
print(json.dumps({'checks': checks}, sort_keys=True))
