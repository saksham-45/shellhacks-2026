#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO_ROOT=$(cd "$PACKAGE_ROOT/../../.." && pwd)
KEY_FILE="$PACKAGE_ROOT/Tests/ADAgentsClientTests/server_message_keys.json"
CATALOG="$PACKAGE_ROOT/Sources/ADAgentsClient/Resources/ADAgentsClient.xcstrings"
SERVER_ROOT="$REPO_ROOT/server/src"
CONTRACTS="$REPO_ROOT/contracts/v1"

python3 - "$PACKAGE_ROOT" "$KEY_FILE" "$CATALOG" "$SERVER_ROOT" "$CONTRACTS" "${1:-}" <<'PY'
import json
import re
import sys
from pathlib import Path

package_root, key_file, catalog_file, server_root, contracts_root = map(Path, sys.argv[1:6])
mode = sys.argv[6] if len(sys.argv) > 6 else ""

verifier = (server_root / "myad_server/verifier.py").read_text(encoding="utf-8")
# The stable desk-only ids are declared in the server's type-level key list.
desk_match = re.search(r"DeskOnlyKind\s*=\s*Literal\[(.*?)\]", verifier, re.S)
if not desk_match:
    raise SystemExit("could not find DeskOnlyKind in verifier.py")
desk_ids = re.findall(r"['\"]([a-z0-9_]+)['\"]", desk_match.group(1))

# _Fail names are the server's handoff reason constants. These three are emitted
# by paths that do not construct _Fail instances.
handoff_reasons = set(re.findall(r'_Fail\("([a-z_]+)"', verifier))
handoff_reasons.update({"no_source", "unavailable", "membership_unknown"})

keys = {f"ask.reason.desk_only.{name}" for name in desk_ids}
keys |= {f"handoff.reason.{name}" for name in handoff_reasons}

# Contracts provide checked-in examples of emitted keys. Keep only the two
# server-owned families above; other tables and private demo copy are separate.
if contracts_root.is_dir():
    for path in sorted(contracts_root.glob("*.json")):
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        def visit(node):
            if isinstance(node, dict):
                key = node.get("key")
                if node.get("table") == "ADAgentsClient" and isinstance(key, str):
                    yield key
                for child in node.values():
                    yield from visit(child)
            elif isinstance(node, list):
                for child in node:
                    yield from visit(child)

        allowed_handoff = {f"handoff.reason.{n}" for n in handoff_reasons}
        for key in visit(raw):
            if key.startswith("ask.reason.desk_only.") or key in allowed_handoff:
                keys.add(key)

expected = sorted(keys)
if mode == "--check":
    if not Path(key_file).is_file():
        raise SystemExit(f"missing generated key list: {key_file}")
    actual = json.loads(Path(key_file).read_text(encoding="utf-8"))
    if actual != expected:
        raise SystemExit("server_message_keys.json is stale; run scripts/sync-keys.sh")
else:
    Path(key_file).write_text(json.dumps(expected, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

catalog = json.loads(Path(catalog_file).read_text(encoding="utf-8"))
strings = catalog.get("strings", {})
missing = sorted(set(expected) - set(strings))
if mode == "--check" and missing:
    raise SystemExit("catalog is missing server keys: " + ", ".join(missing))

print(f"server message keys: {len(expected)}")
if mode != "--check":
    print(f"wrote {key_file}")
PY
