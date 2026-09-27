#!/usr/bin/env bash
# Local CI (the only CI while the no-version-control order stands). Owner: myAD Lead.
# Runs: server pytest, tools pytest, string parity, fact coverage, no secrets, swift test per package,
# then every area hook (<locked folder>/ci-hook.sh) as its own step.
# Exits nonzero if any step fails. Prints a PASS/FAIL/SKIP summary.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

declare -a NAMES=() RESULTS=()
FAILED=0

record() { NAMES+=("$1"); RESULTS+=("$2"); [[ "$2" == FAIL ]] && FAILED=1; return 0; }

run_step() {
  local name="$1"; shift
  echo "=== $name"
  if "$@"; then record "$name" PASS; else record "$name" FAIL; fi
}

# Python 3.12 venvs (created on first run with uv if present, else python3 -m venv).
ensure_venv() {
  local dir="$1"; shift
  if [[ ! -x "$dir/.venv/bin/python" ]]; then
    if command -v uv >/dev/null 2>&1; then
      uv venv -q --python 3.12 "$dir/.venv" && uv pip install -q --python "$dir/.venv/bin/python" "$@"
    else
      python3 -m venv "$dir/.venv" && "$dir/.venv/bin/pip" install -q "$@"
    fi
  fi
}

if ensure_venv server -e "server[dev]"; then
  run_step "server pytest" server/.venv/bin/python -m pytest -q server/tests
else
  record "server pytest" FAIL
fi

if ensure_venv tools -r tools/requirements.txt; then
  PY=tools/.venv/bin/python
  run_step "tools pytest" "$PY" -m pytest -q -c tools/pytest.ini --rootdir tools tools/tests
  run_step "string parity" "$PY" tools/check_string_parity.py --root "$ROOT"
  run_step "fact coverage" "$PY" tools/check_fact_coverage.py --root "$ROOT"
  run_step "no secrets" "$PY" tools/check_no_secrets.py --root "$ROOT"
else
  record "tools pytest" FAIL; record "string parity" FAIL; record "fact coverage" FAIL; record "no secrets" FAIL
fi

for pkg in ADCore ADLocale ADVoice ADCityPack ADAgentsClient ADAccessibility ADRouter ADBeat; do
  if command -v swift >/dev/null 2>&1; then
    run_step "swift test $pkg" swift test --package-path "ios/Packages/$pkg"
  else
    echo "=== swift test $pkg: SKIP (swift not on PATH)"
    record "swift test $pkg" SKIP
  fi
done

# Area hooks: any executable ci-hook.sh inside a locked folder runs from its own directory
# as its own step. tools/ itself never ships one (ci.sh is Lead's).
while IFS= read -r hook; do
  rel="${hook#./}"
  dir="$(dirname "$rel")"
  if [[ ! -x "$hook" ]]; then
    echo "=== hook $rel: not executable"; record "hook $rel" FAIL; continue
  fi
  echo "=== hook $rel"
  if (cd "$dir" && ./ci-hook.sh); then record "hook $rel" PASS; else record "hook $rel" FAIL; fi
done < <(find . \( -name .git -o -name .venv -o -name .build -o -name __pycache__ -o -name DerivedData \
                   -o -name node_modules -o -path ./tools \) -prune -o -type f -name ci-hook.sh -print | sort)

echo
echo "===== ci summary ====="
for i in "${!NAMES[@]}"; do printf '%-4s  %s\n' "${RESULTS[$i]}" "${NAMES[$i]}"; done
if (( FAILED )); then echo "CI: FAIL"; exit 1; fi
echo "CI: PASS"
