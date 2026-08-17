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

record('cap', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile(5,3,10) != [3,6,10,10,10] else None)
record('zero', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile(0,1,1) != [] else None)
print(json.dumps({'checks': checks}, sort_keys=True))
