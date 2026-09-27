#!/usr/bin/env bash
# ADLocale area hook (offline, keyless; Python 3 standard library only). Run by tools/ci.sh from
# this folder. Checks:
#   a. Commands/{es,en,ht}.json command keys == contracts/intent/command_keys.json
#   b. no command has an empty phrase list
#   c. within one language, no normalized phrase maps to two commands; single-word phrases
#      only from SINGLE_WORD_OK (whole-utterance matching: "dos"/"two"/"home" are answers)
#   e. ADLocale + ADVoice catalogs: every ht stringUnit (plural variations too) is needs_review,
#      and every key has a comment
#   d. no direct Foundation formatting outside ADLocale (Swift in ios/Packages and ios/App).
#      Fails inside ADLocale/ADVoice; WARN elsewhere unless LINT_STRICT=1.
#      Escape a single line with `// adlocale-lint:allow`.
# Also prints informational review counts (never fail).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MYAD_ROOT:-$(cd "$HERE/../../.." && pwd)}"
export HERE ROOT LINT_STRICT="${LINT_STRICT:-0}"
python3 - <<'PY'
import json, os, pathlib, re, sys, unicodedata

here = pathlib.Path(os.environ["HERE"])
root = pathlib.Path(os.environ["ROOT"])
strict = os.environ.get("LINT_STRICT") == "1"
problems, warnings = [], []

contract_path = root / "contracts/intent/command_keys.json"
contract = set(json.loads(contract_path.read_text(encoding="utf-8"))["command_keys"])

def norm(p):
    p = unicodedata.normalize("NFD", p.lower())
    p = "".join(c for c in p if unicodedata.category(c) != "Mn")
    p = re.sub(r"[¿?¡!.,;:\"'«»()\-]", " ", p)
    return " ".join(p.split())

# Single words that are safe as a whole sentence (reviewed per language; add deliberately).
SINGLE_WORD_OK = {
    "es": {"atras", "volver", "regresar", "vuelve", "regresa", "regrese", "inicio", "leelo", "leemelo", "lealo",
           "pare", "detente", "basta", "repite", "repitelo", "repita", "siguiente", "anterior", "llamar", "llama",
           "llame", "llamalos", "espanol", "spanish", "ingles", "english", "creole", "criollo", "kreyol",
           "si", "claro", "dale", "correcto", "okey", "no"},
    "en": {"back", "stop", "repeat", "again", "next", "previous", "call", "map", "spanish", "espanol", "english",
           "creole", "kreyol", "yes", "yeah", "yep", "sure", "ok", "okay", "correct", "no", "nope"},
    "ht": {"tounen", "retounen", "akey", "sispann", "kanpe", "ase", "repete", "anko", "pwochen", "rele",
           "panyol", "espanol", "angle", "english", "kreyol", "creole", "wi", "dako", "oke", "non"},
}

review = {}
for lang in ("es", "en", "ht"):
    path = here / f"Sources/ADLocale/Commands/{lang}.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    commands = data.get("commands", {})
    keys = set(commands)
    if keys != contract:
        missing, extra = sorted(contract - keys), sorted(keys - contract)
        problems.append(f"{path.name}: command keys differ from {contract_path.relative_to(root)} (missing {missing}, extra {extra})")
    seen = {}
    review[lang] = 0
    for cmd, phrases in commands.items():
        texts = []
        for p in phrases or []:
            if isinstance(p, dict):
                texts.append(p.get("phrase", ""))
                if p.get("state") == "needs_review": review[lang] += 1
            else:
                texts.append(p)
        texts = [t for t in texts if t.strip()]
        if not texts:
            problems.append(f"{path.name}: command '{cmd}' has no phrases")
        for t in texts:
            n = norm(t)
            if " " not in n and n not in SINGLE_WORD_OK[lang]:
                problems.append(f"{path.name}: single-word phrase '{t}' ({cmd}) is not in SINGLE_WORD_OK; one-word answers would fire it")
            if n in seen and seen[n][0] != cmd:
                problems.append(f"{path.name}: phrase '{t}' maps to both '{seen[n][0]}' ('{seen[n][1]}') and '{cmd}'")
            seen.setdefault(n, (cmd, t))

# d. Foundation formatting lint
pattern = re.compile(r"\.formatted\(|\bDateFormatter\(|NumberFormatter\(|MeasurementFormatter\(|Date\.FormatStyle|IntegerFormatStyle"
                     r"|\.currency\(code:|String\(format:|\.string\(from:|(?:ISO8601|Relative|DateComponents|List)\w*Formatter\("
                     r"|format: \.|Text\(.*style: \.date")
# Display formatting owned elsewhere (FactText), and machine-format ISO parsing (not display).
allow = {("ios/App/Sources/Logic/FactText.swift", n) for n in (66, 67, 85)} | \
        {("ios/Packages/ADCityPack/Sources/ADCityPack/RegionResult.swift", n) for n in (146, 152)}
def strip_comment(line):
    in_string = escaped = False
    for i, ch in enumerate(line):
        if escaped: escaped = False
        elif ch == "\\": escaped = True
        elif ch == '"': in_string = not in_string
        elif not in_string and line.startswith("//", i): return line[:i]
    return line
def swift_files():
    for base in (root / "ios/Packages", root / "ios/App"):
        for f in sorted(base.rglob("*.swift")):
            parts = f.relative_to(root).parts
            if ".build" in parts or "DerivedData" in parts: continue
            if base.name == "Packages" and ("Tests" in parts or parts[2] == "ADLocale"): continue
            yield f
for f in swift_files():
    rel = str(f.relative_to(root))
    owned = rel.startswith("ios/Packages/ADVoice/")
    for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if "adlocale-lint:allow" in line or (rel, n) in allow: continue
        if pattern.search(strip_comment(line)):
            msg = f"{rel}:{n}: direct Foundation formatting (use ADLocale's Localizer): {line.strip()[:100]}"
            (problems if owned or strict else warnings).append(msg)

# e. catalogs (ADVoice is this package's sibling folder)
def string_units(node):
    if isinstance(node, dict):
        if "stringUnit" in node: yield node["stringUnit"]
        for k, v in node.items():
            if k != "stringUnit": yield from string_units(v)
    elif isinstance(node, list):
        for v in node: yield from string_units(v)
cat_review = {}
for table, p in (("ADLocale", here / "Sources/ADLocale/Resources/ADLocale.xcstrings"),
                 ("ADVoice", here.parent / "ADVoice/Sources/ADVoice/Resources/ADVoice.xcstrings")):
    d = json.loads(p.read_text(encoding="utf-8"))
    cat_review[table] = 0
    for key, e in d["strings"].items():
        if not str(e.get("comment", "")).strip():
            problems.append(f"{table}.xcstrings: key '{key}' has no comment")
        ht = e.get("localizations", {}).get("ht")
        units = list(string_units(ht)) if ht else []
        if not units:
            problems.append(f"{table}.xcstrings: key '{key}' has no ht localization")
        for u in units:
            if u.get("state") != "needs_review":
                problems.append(f"{table}.xcstrings: key '{key}' ht state is '{u.get('state')}', must be needs_review until native review")
        if units and all(u.get("state") == "needs_review" for u in units): cat_review[table] += 1

for w in warnings: print(f"WARN {w}")
print("INFO command phrases needs_review: " + ", ".join(f"{l}={review[l]}" for l in ("es", "en", "ht")))
print("INFO ht strings needs_review: " + ", ".join(f"{t}={c}" for t, c in cat_review.items()))
for p in problems: print(f"FAIL {p}")
if problems:
    print(f"adlocale hook: {len(problems)} problem(s)"); sys.exit(1)
print(f"adlocale hook: OK ({len(warnings)} warning(s){'' if strict else '; LINT_STRICT=1 makes them failures'})")
PY
