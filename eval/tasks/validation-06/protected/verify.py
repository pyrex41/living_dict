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

record('falsy_preserved', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile([{'a':1},{'a':0,'b':False,'c':''}]) != {'a':0,'b':False,'c':''} else None)
record('none_deletes', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile([{'a':1},{'a':None}]) != {} else None)
print(json.dumps({'checks': checks}, sort_keys=True))
