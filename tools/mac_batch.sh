#!/usr/bin/env bash
# Mac batch: build and test the whole iOS app in ONE approved run on the captain's Mac.
# Owner: myAD Lead (tools/). Doc: docs/MAC_BATCH.md.
#
# Steps, in order (each gets a PASS/FAIL/SKIP line in summary.txt; the batch continues past failures):
#   1. prerequisites        xcodegen, xcodebuild, xcrun simctl, swift, python3, an iOS 18+ simulator runtime
#   2. xcodegen generate    in ios/ (spec: ios/project.yml)
#   3. xcodebuild build     scheme MyAmericanDream on one iPhone simulator
#   4. swift test <Pkg>     every package in ios/Packages (host macOS)
#   5. unit tests           target MyAmericanDreamTests (via the scheme's test plan, one configuration)
#   6. accessibility plan   test plan Accessibility (all configurations: Español, English, Kreyòl);
#                           if the plan file is missing, the UI test target MyAmericanDreamUITests instead
#   7. creole probe <lang>  app launched with `-myadProbe creole` (ios/App/Sources/Platform/CreoleProbe.swift),
#                           console captured with `simctl launch --console-pty`, Documents/creole_probe.{txt,json}
#                           copied out; once per device language in PROBE_LANGS
# Output: build/mac-batch/<timestamp>/ (logs, *.xcresult, probe files, summary.txt). Exit 0 only if nothing failed.
#
# Environment (all optional; no secrets are ever needed or read):
#   DEVICE          simulator name ("iPhone 17 Pro") or UDID; default: newest available iPhone on iOS >= 18
#   PROBE_LANGS     device languages for the Creole probe runs (default "en fr"; report FM-MYAD-LANG §7.4 #4)
#   PROBE_TIMEOUT   seconds to wait for each probe run (default 90)
#   DERIVED_DATA    derived data dir (default build/mac-batch/DerivedData, shared so reruns are incremental)
#   MAC_BATCH_STAMP override the timestamp folder name (tests use this)
# Bash 3.2 compatible (macOS /bin/bash). Never uses version control, never touches the network beyond what Xcode itself does for local packages.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS="$ROOT/ios"
PACKAGES_DIR="$IOS/Packages"

# Names exactly as in ios/project.yml (checked below; a mismatch is a FAIL of "prerequisites").
PROJECT="MyAmericanDream.xcodeproj"
SCHEME="MyAmericanDream"
APP_TARGET="MyAmericanDream"
UNIT_TARGET="MyAmericanDreamTests"
UI_TARGET="MyAmericanDreamUITests"
BUNDLE_ID="com.saksham45.myamericandream"
UNIT_CONFIGURATION="English"          # unit tests are language-independent: run them in one plan configuration

# Every package folder in ios/Packages, in dependency order. Folders found on disk but not listed here
# are still tested (appended), and a listed folder missing on disk is a FAIL.
KNOWN_PACKAGES=(ADCore ADLocale ADVoice ADCityPack ADRouter ADAgentsClient ADAccessibility ADBeat)

STAMP="${MAC_BATCH_STAMP:-$(date +%Y%m%d-%H%M%S)}"
OUT="$ROOT/build/mac-batch/$STAMP"
DERIVED="${DERIVED_DATA:-$ROOT/build/mac-batch/DerivedData}"
PROBE_LANGS="${PROBE_LANGS:-en fr}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-90}"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"

declare -a NAMES=() RESULTS=() NOTES=()
FAILED=0

record() {  # record <name> <PASS|FAIL|SKIP> [note]
  NAMES+=("$1"); RESULTS+=("$2"); NOTES+=("${3:-}")
  if [[ "$2" == FAIL ]]; then FAILED=1; fi
  printf '%-4s  %s%s\n' "$2" "$1" "${3:+  ($3)}"
  return 0
}

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# run_step <name> <command...>: runs with output to <slug>.log; never aborts the batch.
run_step() {
  local name="$1"; shift
  local log; log="$(slug "$name").log"
  echo "=== $name  ->  $log"
  if "$@" >"$OUT/$log" 2>&1; then record "$name" PASS "log $log"; else record "$name" FAIL "log $log, exit $?"; fi
}

write_summary() {
  {
    echo "myAmericanDream Mac batch  $STAMP"
    echo "device: ${DEVICE_NAME:-?} ${DEVICE_OS:+(iOS $DEVICE_OS)} ${DEVICE_UDID:-}"
    echo "output: $OUT"
    echo
    local i
    for i in "${!NAMES[@]}"; do
      printf '%-4s  %s%s\n' "${RESULTS[$i]}" "${NAMES[$i]}" "${NOTES[$i]:+  (${NOTES[$i]})}"
    done
    echo
    if (( FAILED )); then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
    echo
    echo "Not automated (device-only, docs/accessibility.md §11): M1-M12; see docs/MAC_BATCH.md."
  } >"$SUMMARY"
  echo
  cat "$SUMMARY"
}

# ---------------------------------------------------------------- 1. prerequisites
PREREQ_OK=1
PREREQ_MSG=()
need() {  # need <command> <how to install>
  if ! command -v "$1" >/dev/null 2>&1; then PREREQ_OK=0; PREREQ_MSG+=("missing $1: $2"); fi
}
echo "=== prerequisites"
need xcodegen   "brew install xcodegen   (https://github.com/yonaskolb/XcodeGen)"
need xcodebuild "install Xcode 16 or newer from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
need xcrun      "comes with Xcode: sudo xcode-select -s /Applications/Xcode.app"
need swift      "comes with Xcode (Swift 6 toolchain): sudo xcode-select -s /Applications/Xcode.app"
need python3    "xcode-select --install   (Command Line Tools ship /usr/bin/python3)"

# The python helper reads `simctl list ... -j` JSON. Modes:
#   runtime <file>          -> newest available iOS runtime >= 18 as "<version>" (exit 1 if none)
#   device <file> [DEVICE]  -> "<udid>\t<name>\t<ios version>" for DEVICE (name or UDID) or the newest iPhone
pick() {
  python3 - "$@" <<'PY'
import json, sys

def ver(v):
    return tuple(int(p) for p in str(v).split(".") if p.isdigit())

mode, path = sys.argv[1], sys.argv[2]
want = sys.argv[3] if len(sys.argv) > 3 else ""
data = json.load(open(path))
if mode == "runtime":
    rts = [r for r in data.get("runtimes", [])
           if r.get("isAvailable", True) and (r.get("platform") == "iOS" or ".iOS-" in r.get("identifier", ""))
           and ver(r.get("version", "0")) >= (18,)]
    if not rts:
        sys.exit(1)
    print(max(rts, key=lambda r: ver(r["version"]))["version"])
    sys.exit(0)

# mode == "device"
cands = []
for rt, devs in data.get("devices", {}).items():
    if ".iOS-" not in rt:
        continue
    os_ver = rt.rsplit(".iOS-", 1)[1].replace("-", ".")
    if ver(os_ver) < (18,):
        continue
    for d in devs:
        if d.get("isAvailable", True):
            cands.append((ver(os_ver), os_ver, d["name"], d["udid"]))
if want:
    hits = [c for c in cands if c[3] == want or c[2] == want]
else:
    hits = [c for c in cands if c[2].startswith("iPhone")]
if not hits:
    sys.exit(1)
# newest runtime first, then the newest-looking iPhone name (highest model number, "Pro Max" > "Pro" > plain)
best = max(hits, key=lambda c: (c[0], [int(t) if t.isdigit() else 0 for t in c[2].split()], len(c[2])))
print(f"{best[3]}\t{best[2]}\t{best[1]}")
PY
}

DEVICE_UDID="" DEVICE_NAME="" DEVICE_OS=""
if (( PREREQ_OK )); then
  { xcodebuild -version; xcodegen --version; swift --version; } >"$OUT/prerequisites.log" 2>&1 || true
  if xcrun simctl list runtimes available -j >"$OUT/simctl-runtimes.json" 2>>"$OUT/prerequisites.log" \
     && RUNTIME="$(pick runtime "$OUT/simctl-runtimes.json")"; then
    echo "iOS simulator runtime: $RUNTIME" >>"$OUT/prerequisites.log"
  else
    PREREQ_OK=0
    PREREQ_MSG+=("no iOS 18+ simulator runtime: xcodebuild -downloadPlatform iOS   (or Xcode > Settings > Components)")
  fi
fi
if (( PREREQ_OK )); then
  if xcrun simctl list devices available -j >"$OUT/simctl-devices.json" 2>>"$OUT/prerequisites.log" \
     && DEV="$(pick device "$OUT/simctl-devices.json" "${DEVICE:-}")"; then
    IFS=$'\t' read -r DEVICE_UDID DEVICE_NAME DEVICE_OS <<<"$DEV"
  else
    PREREQ_OK=0
    if [[ -n "${DEVICE:-}" ]]; then
      PREREQ_MSG+=("DEVICE='$DEVICE' is not an available iOS 18+ simulator: xcrun simctl list devices available")
    else
      PREREQ_MSG+=("no available iPhone simulator on iOS 18+: xcrun simctl create 'iPhone' 'iPhone 16' <iOS runtime id>")
    fi
  fi
fi
# Names used below must match ios/project.yml exactly.
for n in "$SCHEME:" "$UNIT_TARGET:" "$UI_TARGET:" "PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID"; do
  if ! grep -qF -- "$n" "$IOS/project.yml"; then PREREQ_OK=0; PREREQ_MSG+=("ios/project.yml has no '$n'; update tools/mac_batch.sh"); fi
done
for p in "${KNOWN_PACKAGES[@]}"; do
  if [[ ! -f "$PACKAGES_DIR/$p/Package.swift" ]]; then PREREQ_OK=0; PREREQ_MSG+=("ios/Packages/$p/Package.swift is missing"); fi
done

if (( ! PREREQ_OK )); then
  printf '%s\n' "${PREREQ_MSG[@]}" | tee -a "$OUT/prerequisites.log" >&2
  record "prerequisites" FAIL "$(printf '%s; ' "${PREREQ_MSG[@]}")"
  write_summary
  exit 2
fi
record "prerequisites" PASS "iOS $DEVICE_OS, $DEVICE_NAME"
DEST="platform=iOS Simulator,id=$DEVICE_UDID"

# Test plan from ios/project.yml (schemes > test > testPlans > path), relative to ios/.
PLAN_PATH="$(sed -n 's/^[[:space:]]*-[[:space:]]*path:[[:space:]]*\([^[:space:]]*\.xctestplan\).*/\1/p' "$IOS/project.yml" | head -n 1)"
PLAN_NAME=""
if [[ -n "$PLAN_PATH" && -f "$IOS/$PLAN_PATH" ]]; then
  PLAN_NAME="$(basename "$PLAN_PATH" .xctestplan)"
fi

# ---------------------------------------------------------------- 2. xcodegen
run_step "xcodegen generate" bash -c 'cd "$1" && xcodegen generate --spec project.yml' _ "$IOS"
PROJECT_OK=0
if [[ "${RESULTS[${#RESULTS[@]}-1]}" == PASS ]]; then PROJECT_OK=1; fi

xb() {  # xb <result bundle name> <xcodebuild args...>
  local bundle="$OUT/$1.xcresult"; shift
  rm -rf "$bundle"
  (cd "$IOS" && xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
      -derivedDataPath "$DERIVED" -resultBundlePath "$bundle" "$@")
}
xcresult_summary() {  # best effort; never changes a step's result
  [[ -d "$OUT/$1.xcresult" ]] || return 0
  xcrun xcresulttool get test-results summary --path "$OUT/$1.xcresult" >"$OUT/$1.summary.json" 2>/dev/null || true
}

# ---------------------------------------------------------------- 3. build
if (( PROJECT_OK )); then
  run_step "xcodebuild build $SCHEME" xb build build
else
  record "xcodebuild build $SCHEME" SKIP "no project: xcodegen failed"
fi

# ---------------------------------------------------------------- 4. swift test per package
PKGS=("${KNOWN_PACKAGES[@]}")
for manifest in "$PACKAGES_DIR"/*/Package.swift; do
  [[ -f "$manifest" ]] || continue
  p="$(basename "$(dirname "$manifest")")"
  case " ${PKGS[*]} " in *" $p "*) ;; *) PKGS+=("$p"); echo "note: $p is not in KNOWN_PACKAGES; testing it anyway" ;; esac
done
for p in "${PKGS[@]}"; do
  run_step "swift test $p" swift test --package-path "$PACKAGES_DIR/$p" \
    --scratch-path "$ROOT/build/mac-batch/swiftpm/$p"
done

# ---------------------------------------------------------------- 5. app unit tests
if (( PROJECT_OK )); then
  if [[ -n "$PLAN_NAME" ]]; then
    run_step "unit tests $UNIT_TARGET" xb unit-tests test -testPlan "$PLAN_NAME" \
      -only-testing:"$UNIT_TARGET" -only-test-configuration "$UNIT_CONFIGURATION"
  else
    run_step "unit tests $UNIT_TARGET" xb unit-tests test -only-testing:"$UNIT_TARGET"
  fi
  xcresult_summary unit-tests
else
  record "unit tests $UNIT_TARGET" SKIP "no project: xcodegen failed"
fi

# ---------------------------------------------------------------- 6. accessibility test plan
if (( PROJECT_OK )); then
  if [[ -n "$PLAN_NAME" ]]; then
    run_step "test plan $PLAN_NAME" xb accessibility test -testPlan "$PLAN_NAME"
  else
    echo "note: test plan '${PLAN_PATH:-<none in project.yml>}' not found under ios/; running $UI_TARGET instead"
    run_step "ui tests $UI_TARGET (no test plan)" xb accessibility test -only-testing:"$UI_TARGET"
  fi
  xcresult_summary accessibility
else
  record "accessibility tests" SKIP "no project: xcodegen failed"
fi

# ---------------------------------------------------------------- 7. Creole voice probe
APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/$APP_TARGET.app"

probe_run() {  # probe_run <lang>; succeeds when Documents/creole_probe.json appears
  local lang="$1" data pid waited=0 rc=1
  local log="$OUT/creole-probe-$lang.console.log"
  xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true      # already booted is fine
  # `set -e` is off inside a function run as an `if` condition (run_step), so check each step.
  xcrun simctl bootstatus "$DEVICE_UDID" -b || return 1
  xcrun simctl install "$DEVICE_UDID" "$APP_PATH" || return 1
  data="$(xcrun simctl get_app_container "$DEVICE_UDID" "$BUNDLE_ID" data)" || return 1
  [[ -n "$data" ]] || return 1
  mkdir -p "$data/Documents"
  rm -f "$data/Documents/creole_probe.txt" "$data/Documents/creole_probe.json"
  local region; region="$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')"; [[ "$lang" == en ]] && region=US
  xcrun simctl launch --console-pty --terminate-running-process "$DEVICE_UDID" "$BUNDLE_ID" \
    -myadProbe creole -AppleLanguages "($lang)" -AppleLocale "${lang}_${region}" >"$log" 2>&1 &
  pid=$!
  while (( waited < PROBE_TIMEOUT )); do
    if [[ -s "$data/Documents/creole_probe.json" ]]; then rc=0; break; fi
    sleep 1; waited=$((waited + 1))
  done
  sleep 1   # let the last console lines ("MYAD-PROBE done") flush
  xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cp "$data/Documents/creole_probe.txt" "$OUT/creole-probe-$lang.txt" 2>/dev/null || true
  cp "$data/Documents/creole_probe.json" "$OUT/creole-probe-$lang.json" 2>/dev/null || true
  grep 'MYAD-PROBE ' "$log" >"$OUT/creole-probe-$lang.lines.txt" 2>/dev/null || true
  if (( rc != 0 )); then echo "no Documents/creole_probe.json after ${PROBE_TIMEOUT}s"; fi
  return "$rc"
}

for lang in $PROBE_LANGS; do
  if [[ -d "$APP_PATH" ]]; then
    run_step "creole probe $lang" probe_run "$lang"
  else
    record "creole probe $lang" FAIL "app not built at $APP_PATH"
  fi
done
xcrun simctl shutdown "$DEVICE_UDID" >/dev/null 2>&1 || true

write_summary
if (( FAILED )); then exit 1; fi
exit 0
