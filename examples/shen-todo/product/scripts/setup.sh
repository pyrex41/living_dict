#!/usr/bin/env bash
# Install Shen-Go via pyrex41/bifrost and shake the workspace.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v bifrost >/dev/null 2>&1; then
  echo "installing bifrost from github.com/pyrex41/bifrost"
  go install github.com/pyrex41/bifrost@latest
fi

# bifrost --shake shen-go materializes the Shen-Go runtime and stdlib
bifrost --shake shen-go

# pin local product packages for the HTTP todo service
export SHEN_HOME="${SHEN_HOME:-$ROOT/.shen-go}"
echo "shen-go ready under $SHEN_HOME"
