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

from app.config import DEFAULTS, normalize
record('canonical_default', lambda: (_ for _ in ()).throw(AssertionError()) if 'max_workers' not in DEFAULTS or 'worker_count' in DEFAULTS else None)
record('new_value', lambda: (_ for _ in ()).throw(AssertionError()) if normalize({'max_workers': 'chosen'})['max_workers'] != 'chosen' else None)
record('legacy_alias', lambda: (_ for _ in ()).throw(AssertionError()) if normalize({'worker_count': 'legacy'})['max_workers'] != 'legacy' else None)
record('new_wins', lambda: (_ for _ in ()).throw(AssertionError()) if normalize({'worker_count': 'old', 'max_workers': 'new'})['max_workers'] != 'new' else None)
def unknown_rejected():
    try:
        normalize({'not_a_setting': 1})
    except KeyError:
        return
    raise AssertionError('unknown key was accepted')
record('unknown_rejected', unknown_rejected)

print(json.dumps({'checks': checks}, sort_keys=True))
