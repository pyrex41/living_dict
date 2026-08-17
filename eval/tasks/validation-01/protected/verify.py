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

record('first_and_order', lambda: (_ for _ in ()).throw(AssertionError()) if [(x['id'],x['v']) for x in reconcile([{'id':2,'v':'first'},{'id':1,'v':'only'},{'id':2,'v':'last'}])] != [(2,'first'),(1,'only')] else None)
print(json.dumps({'checks': checks}, sort_keys=True))
