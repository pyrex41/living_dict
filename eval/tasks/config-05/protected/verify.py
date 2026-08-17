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
record('canonical_default', lambda: (_ for _ in ()).throw(AssertionError()) if 'structured_logging' not in DEFAULTS or 'log_json' in DEFAULTS else None)
record('new_value', lambda: (_ for _ in ()).throw(AssertionError()) if normalize({'structured_logging': 'chosen'})['structured_logging'] != 'chosen' else None)
record('legacy_alias', lambda: (_ for _ in ()).throw(AssertionError()) if normalize({'log_json': 'legacy'})['structured_logging'] != 'legacy' else None)
record('new_wins', lambda: (_ for _ in ()).throw(AssertionError()) if normalize({'log_json': 'old', 'structured_logging': 'new'})['structured_logging'] != 'new' else None)
def unknown_rejected():
    try:
        normalize({'not_a_setting': 1})
    except KeyError:
        return
    raise AssertionError('unknown key was accepted')
record('unknown_rejected', unknown_rejected)

print(json.dumps({'checks': checks}, sort_keys=True))
