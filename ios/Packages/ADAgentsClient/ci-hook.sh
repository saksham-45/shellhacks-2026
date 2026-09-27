#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Keep the checked-in server key list and the client catalog in lockstep.
bash scripts/sync-keys.sh --check
python3 ../../../tools/check_string_parity.py --root .
swift test
