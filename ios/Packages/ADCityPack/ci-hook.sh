#!/usr/bin/env bash
# ADCityPack area hook (offline, keyless, stdlib Python only). Does NOT run swift test: tools/ci.sh
# already runs `swift test` for this package as its own step.
# Checks the bundled demo data the phone ships:
#   - every Resources JSON parses; every result's value uses one of ADCore's ten FactValue wire types
#   - every result that is not `unsourced` names its source url and retrieved_at; every result has a desk
#   - no personal fields (owner names, mailing addresses) and no standalone wrong year (the plan's year for 111 NW 1st St; the county parcel says 1984)
#   - every not-applicable reason key exists in ADCityPack.xcstrings, with en/es/ht values
#   - pin A (unincorporated) carries no us-fl-miami result
#   - Checks/: verified ledger rows carry source/quote/retrieved_at, the listing cache has no owner field,
#     the fee replay is labeled demo-script, and every check string has en/es/ht
#   - address check: cached answers are labeled PointAddress 95+ with point-in-polygon urls, times and declared
#     fields only; a verified rule has a verified ledger row and names at least one area
#   - Resources are byte-identical to server/regionpacks' export (export_fixtures.py --check)
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import json, pathlib, re, sys

res = pathlib.Path("Sources/ADCityPack/Resources")
VALUE_TYPES = {"text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag"}
# Field-shaped only (a JSON key or a "FIELD: value" quote), so a statute quote saying "mailing address" is not a hit.
PERSONAL = re.compile(r"\b(?:TRUE_OWNER|OWNER\d|MAILING|CONTACT|CREATEDBY|MODIFIEDBY|EMAIL|GlobalID|MUNICUID)\w*\"?\s*:", re.I)
WRONG_YEAR = re.compile(r"(?<![\d.])%d(?!\d)" % (1900 + 25))  # built, not written, so this file never holds it
problems = []

catalog = json.loads((res / "ADCityPack.xcstrings").read_text(encoding="utf-8"))["strings"]
for path in sorted(res.rglob("*.json")):
    text = path.read_text(encoding="utf-8")
    try:
        doc = json.loads(text)
    except ValueError as e:
        problems.append(f"{path}: invalid JSON ({e})"); continue
    if PERSONAL.search(text):
        problems.append(f"{path}: personal field present")
    if WRONG_YEAR.search(text):
        problems.append(f"{path}: standalone wrong year")
    if path.parent.name != "Fixtures":
        continue
    for r in doc.get("results", []):
        fid = r.get("fact_id", "?")
        if not r.get("desk"):
            problems.append(f"{path.name}: {fid} has no desk")
        if r.get("status") != "unsourced" and not (r.get("url") and r.get("retrieved_at")):
            problems.append(f"{path.name}: {fid} lacks url/retrieved_at")
        v = r.get("value")
        if v is not None and v.get("type") not in VALUE_TYPES:
            problems.append(f"{path.name}: {fid} value type {v.get('type')!r} is not an ADCore FactValue case")
        if r.get("status") == "ok" and v is None:
            problems.append(f"{path.name}: {fid} is ok without a value")
        na = r.get("not_applicable")
        if na:
            entry = catalog.get(na["reason"])
            if not entry:
                problems.append(f"{path.name}: {fid} reason {na['reason']} missing from ADCityPack.xcstrings")
            else:
                for lang in ("en", "es", "ht"):
                    if not entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value"):
                        problems.append(f"catalog: {na['reason']} has no {lang} value")
        if path.stem == "pin-sw137" and (r.get("pack") == "us-fl-miami" or fid.startswith("us-fl-miami.")):
            problems.append(f"{path.name}: {fid} is a City of Miami result at the unincorporated pin")

# Fee Check / Listing Check bundle (FM-MYAD-DEMO-FEE).
checks = res / "Checks"
if checks.is_dir():
    led = json.loads((checks / "check-ledger.json").read_text(encoding="utf-8"))
    for f in led.get("facts", []):
        if f.get("status") == "verified":
            if not (f.get("source", {}).get("url") and f.get("quote") and f.get("retrieved_at")):
                problems.append(f"check-ledger: {f['id']} verified without source/quote/retrieved_at")
        elif "value" in f:
            problems.append(f"check-ledger: {f['id']} is {f.get('status')} but carries a value")
    listing = json.loads((checks / "listing-county-building.json").read_text(encoding="utf-8"))
    if listing.get("owner_kind") not in {"government", "company", "person", "unknown"}:
        problems.append("listing cache: owner_kind missing")
    if re.search(r"OWNER(?!_KIND)", json.dumps(listing).upper()):
        problems.append("listing cache: owner field present")
    if json.loads((checks / "fee-replay.json").read_text(encoding="utf-8")).get("kind") != "demo-script":
        problems.append("fee replay: not labeled demo-script")
    # Who handles my address (FM-MYAD-ADDR): cached county answers and ledger-gated rules.
    arules = json.loads((checks / "address-rules.json").read_text(encoding="utf-8"))
    declared = {l["key"]: set(l["fields"]) for l in arules["layers"]}
    verified_ids = {f["id"] for f in led.get("facts", []) if f.get("status") == "verified"}
    for r in arules["rules"]:
        if r["status"] == "verified" and (r["fact"] not in verified_ids or not r["municipalities"]):
            problems.append(f"address rules: {r['id']} verified without a verified ledger row naming an area")
        if r["status"] != "verified" and r["municipalities"]:
            problems.append(f"address rules: {r['id']} is {r['status']} but names areas")
    for pin in ("pin-sw137", "pin-nw1st"):
        a = json.loads((checks / f"address-{pin}.json").read_text(encoding="utf-8"))
        if a.get("kind") != "cached-county-response" or a.get("pin_id") != pin:
            problems.append(f"address {pin}: not labeled cached-county-response")
        loc = a.get("locator", {})
        if loc.get("addr_type") != "PointAddress" or loc.get("score", 0) < 95 or not loc.get("retrieved_at"):
            problems.append(f"address {pin}: locator is not a PointAddress match at score 95+ with a time")
        if set(a.get("layers", {})) != set(declared):
            problems.append(f"address {pin}: layers differ from address-rules.json")
        for key, ans in a.get("layers", {}).items():
            if not (ans.get("url", "").startswith("https://") and "esriSpatialRelIntersects" in ans.get("url", "") and ans.get("retrieved_at")):
                problems.append(f"address {pin}/{key}: no point-in-polygon url or retrieved_at")
            for f in ans.get("features", []):
                if not set(f) <= declared.get(key, set()):
                    problems.append(f"address {pin}/{key}: undeclared field {sorted(set(f) - declared.get(key, set()))}")
        for key, dom in a.get("domains", {}).items():
            if not (dom.get("url") and dom.get("retrieved_at") and dom.get("codes")):
                problems.append(f"address {pin}: code list {key} without url/retrieved_at/codes")
    for key, entry in catalog.items():
        if key.startswith(("regions.fee.", "regions.listing.", "regions.check.", "regions.beat.", "regions.address.")):
            for lang in ("en", "es", "ht"):
                if not entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value"):
                    problems.append(f"catalog: {key} has no {lang} value")

for p in problems:
    print(p)
print(f"adcitypack hook: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
PY
python3 ../../../server/regionpacks/scripts/export_fixtures.py --check
