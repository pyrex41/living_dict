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

record('disabled', lambda: (_ for _ in ()).throw(AssertionError()) if reconcile([{'kind':'a','enabled':False},{'kind':'a'}], ['a']) != [('a',1)] else None)

def unknown():
    try: reconcile([{'kind':'x'}], ['a'])
    except ValueError: return
    raise AssertionError('unknown kind accepted')
record('unknown', unknown)
print(json.dumps({'checks': checks}, sort_keys=True))
