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

from pipeline.registry import run, describe_pipeline
record('behavior', lambda: (_ for _ in ()).throw(AssertionError()) if run(4) != 11 else None)
record('order', lambda: (_ for _ in ()).throw(AssertionError()) if describe_pipeline() != ['north', 'east', 'south'] else None)
record('graph_unchanged', lambda: json.loads((workspace/'task_graph.json').read_text()))

print(json.dumps({'checks': checks}, sort_keys=True))
