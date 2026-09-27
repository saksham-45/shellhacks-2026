#!/usr/bin/env bash
# Take an integration snapshot of the tree (the accepted integration point). Owner: myAD Lead.
# Copies /workspace/myamericandream to /workspace/myad-snapshots/<UTC timestamp>/ and repoints `latest`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPROOT="${MYAD_SNAPSHOT_ROOT:-/workspace/myad-snapshots}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$SNAPROOT/$STAMP"

mkdir -p "$SNAPROOT"
[[ -e "$DEST" ]] && { echo "snapshot $DEST already exists" >&2; exit 1; }
mkdir "$DEST"

tar -C "$ROOT" \
  --exclude=./.git --exclude=.venv --exclude=.build --exclude=__pycache__ --exclude=DerivedData \
  --exclude=.pytest_cache --exclude='.env*' \
  -cf - . | tar -C "$DEST" -xf -

ln -sfn "$STAMP" "$SNAPROOT/latest"
echo "$DEST"
