#!/usr/bin/env bash
# CI hook for server/regionpacks (owner: myAD Regions). Runs ONLY the region pack tests, offline and keyless.
# tools/ci.sh runs this from server/regionpacks. Live tests are skipped (MYAD_LIVE is forced off here).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
unset MYAD_LIVE
export PYTHONDONTWRITEBYTECODE=1

PY=""
for cand in "${MYAD_REGIONS_PY:-}" ../.venv/bin/python ../../tools/.venv/bin/python python3; do
  [[ -n "$cand" ]] || continue
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import pytest, sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; then
    PY="$cand"; break
  fi
done
[[ -n "$PY" ]] || { echo "regionpacks hook: no Python 3.12 with pytest found (server/.venv is created by tools/ci.sh)" >&2; exit 1; }

"$PY" -m pytest -q -c pytest.ini --rootdir . tests
