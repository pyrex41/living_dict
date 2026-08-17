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

record('largest_remainder', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile([1,1,1]) != [34,33,33] else None)
record('sum', lambda: (_ for _ in ()).throw(AssertionError()) if sum(reconcile([2,3,7])) != 100 else None)
print(json.dumps({'checks': checks}, sort_keys=True))
