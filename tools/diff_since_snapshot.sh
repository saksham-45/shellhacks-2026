#!/usr/bin/env bash
# Unified diff from the latest snapshot to the live tree, for integration and adversarial review.
# Usage: tools/diff_since_snapshot.sh [area-path]   e.g. ios/Packages/ADCore, research, server
# Writes the patch to stdout. Exit 0 = no changes, 1 = changes, >1 = error (diff semantics).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPROOT="${MYAD_SNAPSHOT_ROOT:-/workspace/myad-snapshots}"
LATEST="$SNAPROOT/latest"
AREA="${1:-.}"
AREA="${AREA%/}"

[[ -d "$LATEST" ]] || { echo "no snapshot at $LATEST; run tools/snapshot.sh" >&2; exit 2; }
case "$AREA" in /*|*..*) echo "area must be a relative path inside the tree" >&2; exit 2 ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/empty"

# Patch paths read a/<area>/... and b/<area>/...; an area missing on one side diffs against empty.
side() {  # side <name> <tree>
  mkdir -p "$WORK/$1/$(dirname "$AREA")"
  if [[ -e "$2/$AREA" ]]; then ln -s "$(readlink -f "$2/$AREA")" "$WORK/$1/$AREA"
  else ln -s "$WORK/empty" "$WORK/$1/$AREA"; fi
}
if [[ "$AREA" == "." ]]; then
  ln -s "$(readlink -f "$LATEST")" "$WORK/a"; ln -s "$ROOT" "$WORK/b"
else
  side a "$LATEST"; side b "$ROOT"
fi

cd "$WORK"
diff -ruN -x .git -x .venv -x .build -x __pycache__ -x DerivedData -x .pytest_cache -x '.env*' \
  "a/$AREA/" "b/$AREA/"
