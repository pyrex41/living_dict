#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UV_BIN=${UV:-$(command -v uv 2>/dev/null || true)}
if [ -z "$UV_BIN" ] && [ -x "$ROOT/.venv-bench/bin/uv" ]; then
  UV_BIN="$ROOT/.venv-bench/bin/uv"
fi
if [ -z "$UV_BIN" ]; then
  echo "uv is required; install it or set UV=/path/to/uv" >&2
  exit 2
fi
cd "$ROOT"
exec "$UV_BIN" run --python 3.12 --with datasets --with swebench \
  python bench/swebench_livingdict.py "$@"
