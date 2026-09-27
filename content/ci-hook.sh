#!/usr/bin/env bash
# CI hook for the content registry. tools/ci.sh finds and runs this file from content/.
# Steps: validator (against ../research/facts when it exists), Cards.xcstrings freshness,
# then the pytest suite. Exits nonzero on any failure. Offline; touches only content/.
# Needs Python 3.12 with PyYAML and pytest. Override the interpreter with PYTHON=...
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ -n "${PYTHON:-}" ]; then
  PY="$PYTHON"
elif [ -x ../tools/.venv/bin/python ]; then
  PY=../tools/.venv/bin/python   # the project CI venv (has pyyaml + pytest)
else
  PY=python3
fi

if [ -d ../research/facts ]; then
  echo "== validate (with ledger ../research/facts)"
  "$PY" tools/validate.py --content . --ledger ../research/facts --quiet-warnings
else
  echo "== validate (no ledger found at ../research/facts)"
  "$PY" tools/validate.py --content .
fi

echo "== Cards.xcstrings freshness"
"$PY" tools/build_strings.py --content . --check

echo "== facts-requested freshness"
fresh_tmp="$(mktemp)"
fresh_diff="$(mktemp)"
if ! "$PY" tools/gen_facts_requested.py --output "$fresh_tmp" >/dev/null; then
  rm -f "$fresh_tmp" "$fresh_diff"
  echo "facts-requested generator failed" >&2
  exit 1
fi
if ! diff -u facts-requested.yaml "$fresh_tmp" >"$fresh_diff"; then
  lines="$(wc -l <"$fresh_diff")"
  rm -f "$fresh_tmp" "$fresh_diff"
  echo "facts-requested.yaml is stale (diff: ${lines} lines)" >&2
  exit 1
fi
rm -f "$fresh_tmp" "$fresh_diff"

# Lead's bundle compiler (tools/build_content_bundle.py), when present: prove our cards compile,
# writing only to a temp dir. contracts/ is Lead's folder; this hook never writes there.
BUNDLER=../tools/build_content_bundle.py
if [ -f "$BUNDLER" ] && grep -q -- '--out' "$BUNDLER"; then
  echo "== bundle compile (temp output)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  "$PY" "$BUNDLER" --out "$tmp/cards.json"
else
  echo "== bundle compile: SKIP (no ../tools/build_content_bundle.py with --out)"
fi

echo "== pytest"
"$PY" -m pytest -q -p no:cacheprovider tests
