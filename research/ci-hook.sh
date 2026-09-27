#!/usr/bin/env bash
# research/ CI hook. Run by tools/ci.sh from inside research/ (cwd = research/). Offline and fast:
#   1. ledger validator (tools/validate.py, owned by the ledger worker) if present
#   2. unit tests: python -m pytest tests -m 'not live'   (no network; live tests need --run-live)
# Python: $MYAD_RESEARCH_PYTHON, else the venv at $MYAD_RESEARCH_VENV (default ~/.cache/myad-research-venv,
# outside the tree so no .venv lands in research/), else python3 if it already has
# the deps, else that venv is created from requirements.txt with uv (offline from the uv cache first).
# pytest runs with -p no:cacheprovider so no .pytest_cache is written. Exits non-zero on any failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
export PYTHONDONTWRITEBYTECODE=1 MYAD_NO_NETWORK=1
VENV="${MYAD_RESEARCH_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/myad-research-venv}"

has_deps() { "$1" -c 'import httpx, yaml, bs4, pytest, jsonschema' >/dev/null 2>&1; }

PY="${MYAD_RESEARCH_PYTHON:-}"
if [[ -z "$PY" ]]; then
  if [[ -x "$VENV/bin/python" ]] && has_deps "$VENV/bin/python"; then
    PY="$VENV/bin/python"
  elif has_deps python3; then
    PY=python3
  elif command -v uv >/dev/null 2>&1; then
    uv venv -q --python 3.12 "$VENV" >/dev/null 2>&1 || true
    uv pip install -q --offline --python "$VENV/bin/python" -r requirements.txt >/dev/null 2>&1 \
      || uv pip install -q --python "$VENV/bin/python" -r requirements.txt
    PY="$VENV/bin/python"
  fi
fi
if [[ -z "$PY" ]] || ! has_deps "$PY"; then
  echo "research ci-hook: no Python with httpx/pyyaml/bs4/pytest/jsonschema (see research/requirements.txt)" >&2
  exit 1
fi

status=0
if [[ -f tools/validate.py && -f sources.yaml ]]; then
  echo "--- research: ledger validator"
  "$PY" tools/validate.py . || status=1
else
  echo "--- research: ledger validator skipped (tools/validate.py or sources.yaml missing)"
fi
echo "--- research: unit tests (offline)"
"$PY" -m pytest -q -p no:cacheprovider tests -m 'not live' || status=1
exit $status
