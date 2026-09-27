"""tools/mac_batch.sh: syntax, package coverage, and a full dry run with stub Xcode tools.

The dry run copies the script plus ios/project.yml, the test plan, and every package manifest into a
temp tree, puts stub xcodegen/xcodebuild/xcrun/swift scripts first on PATH (each logs its argv), and
checks the step order, the result bundles, the Creole probe capture, and summary.txt.
"""
import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent.parent
ROOT = TOOLS.parent
SCRIPT = TOOLS / "mac_batch.sh"
IOS = ROOT / "ios"
BASE_PATH = "/usr/bin:/bin"

RUNTIMES = {
    "runtimes": [
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5", "version": "17.5", "platform": "iOS", "isAvailable": True},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0", "version": "18.0", "platform": "iOS", "isAvailable": True},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "platform": "iOS", "isAvailable": True},
    ]
}
DEVICES = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [{"name": "iPhone 15", "udid": "UDID-15", "isAvailable": True}],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [{"name": "iPhone 16", "udid": "UDID-16", "isAvailable": True}],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 17", "udid": "UDID-17", "isAvailable": True},
            {"name": "iPhone 17 Pro", "udid": "UDID-17PRO", "isAvailable": True},
            {"name": "iPad Pro 13-inch (M5)", "udid": "UDID-IPAD", "isAvailable": True},
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [{"name": "Apple Watch", "udid": "UDID-W", "isAvailable": True}],
    }
}

STUBS = {
    "xcodegen": r"""#!/bin/bash
echo "xcodegen [cwd=$(basename "$PWD")] $*" >>"$STUB_LOG"
[[ "$1" == --version ]] && { echo "Version: 2.43.0"; exit 0; }
mkdir -p MyAmericanDream.xcodeproj
exit "${XCODEGEN_EXIT:-0}"
""",
    "xcodebuild": r"""#!/bin/bash
echo "xcodebuild $*" >>"$STUB_LOG"
[[ "$1" == -version ]] && { echo "Xcode 26.0"; exit 0; }
bundle=""; derived=""; prev=""
for a in "$@"; do
  [[ "$prev" == -resultBundlePath ]] && bundle="$a"
  [[ "$prev" == -derivedDataPath ]] && derived="$a"
  prev="$a"
done
[[ -n "$bundle" ]] && mkdir -p "$bundle"
if [[ " $* " == *" build "* ]]; then
  mkdir -p "$derived/Build/Products/Debug-iphonesimulator/MyAmericanDream.app"
fi
exit 0
""",
    "swift": r"""#!/bin/bash
echo "swift $*" >>"$STUB_LOG"
[[ "$1" == --version ]] && { echo "Swift version 6.2"; exit 0; }
prev=""; pkg=""
for a in "$@"; do [[ "$prev" == --package-path ]] && pkg="$(basename "$a")"; prev="$a"; done
[[ -n "${FAIL_SWIFT_PKG:-}" && "$pkg" == "$FAIL_SWIFT_PKG" ]] && { echo "error: tests failed"; exit 1; }
echo "Test Suite 'All tests' passed"
exit 0
""",
    "xcrun": r"""#!/bin/bash
echo "xcrun $*" >>"$STUB_LOG"
if [[ "$1" == simctl ]]; then
  case "$2" in
    list)
      if [[ "$3" == runtimes ]]; then cat "$STUB_DIR/runtimes.json"; else cat "$STUB_DIR/devices.json"; fi ;;
    get_app_container) echo "$FAKE_CONTAINER" ;;
    launch)
      mkdir -p "$FAKE_CONTAINER/Documents"
      echo "MYAD-PROBE device: iOS 26.0"
      echo "MYAD-PROBE match ht: 0"
      echo "probe report" >"$FAKE_CONTAINER/Documents/creole_probe.txt"
      echo '{"voice_count": 1}' >"$FAKE_CONTAINER/Documents/creole_probe.json"
      echo "MYAD-PROBE done"
      exec sleep 30 ;;   # like the real app: it never exits by itself
  esac
fi
exit 0
""",
}


def _write_exec(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def package_folders():
    return sorted(p.parent.name for p in (IOS / "Packages").glob("*/Package.swift"))


@pytest.fixture
def tree(tmp_path):
    """A temp copy with the script, the XcodeGen spec, the test plan, package manifests, and stubs."""
    root = tmp_path / "repo"
    (root / "tools").mkdir(parents=True)
    shutil.copy2(SCRIPT, root / "tools" / "mac_batch.sh")
    (root / "ios").mkdir()
    shutil.copy2(IOS / "project.yml", root / "ios" / "project.yml")
    for plan in IOS.glob("*.xctestplan"):
        shutil.copy2(plan, root / "ios" / plan.name)
    for name in package_folders():
        d = root / "ios" / "Packages" / name
        d.mkdir(parents=True)
        shutil.copy2(IOS / "Packages" / name / "Package.swift", d / "Package.swift")
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    for name, text in STUBS.items():
        _write_exec(stubs / name, text)
    (stubs / "runtimes.json").write_text(json.dumps(RUNTIMES))
    (stubs / "devices.json").write_text(json.dumps(DEVICES))
    env = {
        "PATH": f"{stubs}:{BASE_PATH}",
        "HOME": str(tmp_path),
        "STUB_LOG": str(tmp_path / "calls.log"),
        "STUB_DIR": str(stubs),
        "FAKE_CONTAINER": str(tmp_path / "container"),
        "MAC_BATCH_STAMP": "test-stamp",
        "PROBE_TIMEOUT": "10",
        "PROBE_LANGS": "en",
    }
    return {"root": root, "stubs": stubs, "env": env, "log": tmp_path / "calls.log"}


def run(tree, **extra):
    env = dict(tree["env"], **extra)
    proc = subprocess.run(
        ["bash", str(tree["root"] / "tools" / "mac_batch.sh")],
        env=env, capture_output=True, text=True, timeout=120,
    )
    out = tree["root"] / "build" / "mac-batch" / "test-stamp"
    calls = tree["log"].read_text().splitlines() if tree["log"].exists() else []
    summary = (out / "summary.txt").read_text() if (out / "summary.txt").exists() else ""
    return proc, out, calls, summary


def _index(calls, pred, start=0):
    for i in range(start, len(calls)):
        if pred(calls[i]):
            return i
    raise AssertionError(f"no call matching after #{start}:\n" + "\n".join(calls))


# ---------------------------------------------------------------- static checks

def test_bash_syntax():
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)


def test_strict_mode_and_executable():
    text = SCRIPT.read_text()
    assert "set -euo pipefail" in text
    assert os.access(SCRIPT, os.X_OK)


def test_references_every_package_folder():
    text = SCRIPT.read_text()
    m = re.search(r"^KNOWN_PACKAGES=\(([^)]*)\)", text, re.M)
    assert m, "KNOWN_PACKAGES list missing"
    listed = m.group(1).split()
    for name in package_folders():
        assert name in listed, f"ios/Packages/{name} is not in KNOWN_PACKAGES"


def test_names_match_project_yml():
    text = SCRIPT.read_text()
    spec = (IOS / "project.yml").read_text()
    for var in ("SCHEME", "APP_TARGET", "UNIT_TARGET", "UI_TARGET"):
        name = re.search(rf'^{var}="([^"]+)"', text, re.M).group(1)
        assert re.search(rf"^  {re.escape(name)}:", spec, re.M), f"{var}={name} is not a target/scheme in project.yml"
    bundle = re.search(r'^BUNDLE_ID="([^"]+)"', text, re.M).group(1)
    assert f"PRODUCT_BUNDLE_IDENTIFIER: {bundle}\n" in spec


def test_no_git_and_no_secrets():
    code = [l for l in SCRIPT.read_text().splitlines() if not l.lstrip().startswith("#")]
    assert not any(re.search(r"(^|[\s;&|(])git(\s|$)", l) for l in code)
    assert not any(re.search(r"API_KEY|TOKEN|SECRET|\.env\b", l) for l in code)


# ---------------------------------------------------------------- dry runs with stubs

def test_full_run_step_order_and_summary(tree):
    proc, out, calls, summary = run(tree, PROBE_LANGS="en fr")
    assert proc.returncode == 0, proc.stdout + proc.stderr

    i = _index(calls, lambda c: c.startswith("xcodegen [cwd=ios] generate"))
    i = _index(calls, lambda c: c.startswith("xcodebuild ") and c.rstrip().endswith(" build"), i)
    assert "-scheme MyAmericanDream" in calls[i]
    assert "-destination platform=iOS Simulator,id=UDID-17PRO" in calls[i]  # newest iPhone on the newest iOS
    assert "build.xcresult" in calls[i]
    for pkg in ["ADCore", "ADLocale", "ADVoice", "ADCityPack", "ADRouter", "ADAgentsClient", "ADAccessibility", "ADBeat"]:
        if pkg in package_folders():
            i = _index(calls, lambda c, p=pkg: c.startswith("swift test") and f"/ios/Packages/{p} " in c, i)
    i = _index(calls, lambda c: c.startswith("xcodebuild ") and " test " in c
               and "-only-testing:MyAmericanDreamTests" in c and "-testPlan Accessibility" in c, i)
    assert "unit-tests.xcresult" in calls[i]
    i = _index(calls, lambda c: c.startswith("xcodebuild ") and "-testPlan Accessibility" in c
               and "-only-testing" not in c and "accessibility.xcresult" in c, i)
    i = _index(calls, lambda c: c.startswith("xcrun simctl install UDID-17PRO"), i)
    i = _index(calls, lambda c: c.startswith("xcrun simctl launch") and "-myadProbe creole" in c
               and "com.saksham45.myamericandream" in c and "(en)" in c, i)
    i = _index(calls, lambda c: c.startswith("xcrun simctl launch") and "(fr)" in c, i)
    assert not any(c.startswith("git") for c in calls)

    for bundle in ("build", "unit-tests", "accessibility"):
        assert (out / f"{bundle}.xcresult").is_dir()
    for lang in ("en", "fr"):
        assert (out / f"creole-probe-{lang}.json").read_text().strip() == '{"voice_count": 1}'
        assert "MYAD-PROBE" in (out / f"creole-probe-{lang}.console.log").read_text()

    lines = [l for l in summary.splitlines() if re.match(r"^(PASS|FAIL|SKIP) ", l)]
    names = [re.sub(r"^\w+\s+", "", l).split("  (")[0] for l in lines]
    expected = (["prerequisites", "xcodegen generate", "xcodebuild build MyAmericanDream"]
                + [f"swift test {p}" for p in ["ADCore", "ADLocale", "ADVoice", "ADCityPack", "ADRouter",
                                                "ADAgentsClient", "ADAccessibility", "ADBeat"] if p in package_folders()]
                + ["unit tests MyAmericanDreamTests", "test plan Accessibility", "creole probe en", "creole probe fr"])
    assert names == expected
    assert all(l.startswith("PASS") for l in lines), summary
    assert "RESULT: PASS" in summary
    assert "iPhone 17 Pro" in summary


def test_failure_is_recorded_and_batch_continues(tree):
    proc, out, calls, summary = run(tree, FAIL_SWIFT_PKG="ADVoice")
    assert proc.returncode == 1
    assert re.search(r"^FAIL  swift test ADVoice", summary, re.M)
    assert re.search(r"^PASS  swift test ADBeat", summary, re.M)        # later packages still ran
    assert re.search(r"^PASS  creole probe en", summary, re.M)          # and so did the probe
    assert "RESULT: FAIL" in summary
    assert "tests failed" in (out / "swift_test_ADVoice.log").read_text()


def test_missing_prerequisite_prints_install_hint(tree):
    if shutil.which("xcodegen", path=BASE_PATH):
        pytest.skip("a real xcodegen is on the base PATH")
    (tree["stubs"] / "xcodegen").unlink()
    proc, out, calls, summary = run(tree)
    assert proc.returncode != 0
    assert "brew install xcodegen" in proc.stderr
    assert re.search(r"^FAIL  prerequisites", summary, re.M)
    assert not any(c.startswith("xcodebuild ") and "-scheme" in c for c in calls)


def test_no_ios18_runtime_fails_early(tree):
    (tree["stubs"] / "runtimes.json").write_text(json.dumps({"runtimes": [RUNTIMES["runtimes"][0]]}))
    proc, out, calls, summary = run(tree)
    assert proc.returncode != 0
    assert "iOS 18+ simulator runtime" in proc.stderr
    assert "RESULT: FAIL" in summary


def test_device_override(tree):
    proc, out, calls, summary = run(tree, DEVICE="iPhone 16")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert any("id=UDID-16" in c for c in calls if c.startswith("xcodebuild"))


def test_unknown_device_override_fails(tree):
    proc, out, calls, summary = run(tree, DEVICE="iPhone 15")   # only on iOS 17
    assert proc.returncode != 0
    assert "DEVICE='iPhone 15'" in proc.stderr


def test_missing_test_plan_falls_back_to_ui_target(tree):
    for plan in (tree["root"] / "ios").glob("*.xctestplan"):
        plan.unlink()
    proc, out, calls, summary = run(tree)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "not found" in proc.stdout
    assert any("-only-testing:MyAmericanDreamUITests" in c and "-testPlan" not in c for c in calls)
    assert re.search(r"^PASS  ui tests MyAmericanDreamUITests \(no test plan\)", summary, re.M)


def test_xcodegen_failure_skips_xcode_steps(tree):
    proc, out, calls, summary = run(tree, XCODEGEN_EXIT="1")
    assert proc.returncode == 1
    assert re.search(r"^FAIL  xcodegen generate", summary, re.M)
    assert re.search(r"^SKIP  xcodebuild build", summary, re.M)
    assert re.search(r"^PASS  swift test ADCore", summary, re.M)
    assert re.search(r"^FAIL  creole probe en", summary, re.M)
