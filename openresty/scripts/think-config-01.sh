#!/bin/sh
# Copy eval/tasks/config-01 into the /think workspace and POST the canned envelope.
set -eu
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="$REPO/openresty"
WS="$PREFIX/var/think"
ENVELOPE="$PREFIX/examples/config-01.envelope.json"
BASE="${LIVINGDICT_URL:-http://127.0.0.1:8080}"

RUN="$PREFIX/var/run/think-config-01"
mkdir -p "$WS" "$RUN/dictionary"
rm -rf "$WS/app" "$WS/tests" "$WS/TASK.md" "$WS/.livingdict-run"
cp -R "$REPO/eval/tasks/config-01/repo/app" "$WS/app"
cp -R "$REPO/eval/tasks/config-01/repo/tests" "$WS/tests"
cp "$REPO/eval/tasks/config-01/prompt.md" "$WS/TASK.md"

if ! curl -sf "$BASE/health" >/dev/null; then
  echo "openresty is not serving $BASE/health" >&2
  echo "start it with: make openresty-serve" >&2
  exit 1
fi

echo "== GET $BASE/health =="
curl -sS "$BASE/health"
echo

echo "== POST $BASE/think (canned config-01 envelope) =="
BODY="$(python3 -c "
import json
from pathlib import Path
env = json.loads(Path('$ENVELOPE').read_text())
print(json.dumps({
    'request': {
        'protocol_version': '1.0',
        'run_id': 'think-config-01',
        'arm': 'forth-shen',
        'memory_mode': 'cold',
        'resume': False,
        'task': {
            'id': 'config-01',
            'family': 'config_migration',
            'sequence': 1,
            'allowed_effects': ['read', 'write', 'exec'],
            'allowed_globs': ['app/config.py'],
            'forbidden_globs': ['tests/**', 'TASK.md'],
        },
        'workspace': '$WS',
        'prompt_path': '$WS/TASK.md',
        'trace_path': '$RUN/trace.jsonl',
        'receipt_path': '$RUN/receipt.json',
        'dictionary_dir': '$RUN/dictionary',
    },
    'envelope': env,
}))
")"
RESP="$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' -d "$BODY" "$BASE/think")"
CODE="$(printf '%s' "$RESP" | tail -n 1)"
JSON="$(printf '%s' "$RESP" | sed '$d')"
echo "$JSON" | python3 -m json.tool
echo "http $CODE"

python3 - <<PY
import json, sys
from pathlib import Path
text = Path("$WS/app/config.py").read_text()
if "timeout_seconds" not in text or "request_timeout" not in text:
    print("config.py was not migrated", file=sys.stderr)
    sys.exit(1)
receipt = json.loads(Path("$RUN/receipt.json").read_text())
if receipt.get("changed_files") != ["app/config.py"]:
    print("unexpected changed_files", receipt.get("changed_files"), file=sys.stderr)
    sys.exit(1)
if receipt.get("policy_violations"):
    print("policy violations", receipt["policy_violations"], file=sys.stderr)
    sys.exit(1)
print("workspace app/config.py migrated; receipt clean")
PY
