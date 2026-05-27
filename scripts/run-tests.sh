#!/usr/bin/env bash
# Run the engine's pytest suite. Bootstraps engine/.venv on first run so a
# fresh clone can `bash scripts/run-tests.sh` without ceremony.
#
# Invoked by .githooks/pre-push; also runnable by hand.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 not on PATH" >&2
  exit 1
fi

VENV="engine/.venv"
if [[ ! -d "$VENV" ]]; then
  echo "→ Bootstrapping $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r engine/requirements.txt -r engine/requirements-dev.txt
fi

cd engine
exec .venv/bin/python -m pytest tests/ "$@"
