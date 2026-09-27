#!/usr/bin/env bash
# ADCore area hook (offline, keyless). Hard rule: ADCore holds no facts. Phone numbers, prices,
# URLs and addresses come only from ledger facts, so none may appear in ADCore's Swift sources.
# Also checks that every literal .adCore("key") in Sources exists in ADCore.xcstrings.
set -euo pipefail
python3 - <<'PY'
import json, pathlib, re, sys

root = pathlib.Path("Sources")
checks = [
    ("phone number", re.compile(r"\b\d{3}[-. )]\s?\d{3}[-. ]\d{4}\b|\b\d{10,11}\b")),
    ("price", re.compile(r"\$\s?\d|\b\d+\.\d{2}\s?(?:USD|dollars?)\b")),
    ("url", re.compile(r"https?://")),
    ("street address", re.compile(r"\b\d{1,5}\s+(?:[NSEW]{1,2}\s+)?\w+\s+(?:St|Ave|Blvd|Rd|Dr|Ct|Ter|Pl|Way|Hwy)\b\.?")),
]
def strip_comment(line):
    """Drop a trailing // comment, ignoring // inside string literals (e.g. URLs)."""
    in_string = escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
    return line

problems = []
for path in sorted(root.rglob("*.swift")):
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        code = strip_comment(line)  # comments may cite examples; code may not
        # String literal contents, plus bare long digit runs in code ($0 closures are not prices).
        literals = " | ".join(re.findall(r'"((?:[^"\\]|\\.)*)"', code))
        bare = " ".join(re.findall(r"\b\d{10,11}\b", code))
        for name, pattern in checks:
            if pattern.search(literals) or (name == "phone number" and bare):
                problems.append(f"{path}:{n}: {name} literal in ADCore source: {line.strip()}")

catalog = json.loads((root / "ADCore/Resources/ADCore.xcstrings").read_text(encoding="utf-8"))["strings"]
for path in sorted(root.rglob("*.swift")):
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for key in re.findall(r'\.adCore\("([^"\\]+)"\)', line):
            if key not in catalog:
                problems.append(f"{path}:{n}: key '{key}' missing from ADCore.xcstrings")

for p in problems:
    print(p)
print(f"adcore hook: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
PY
