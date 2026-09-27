#!/usr/bin/env python3
import re
"""Validate the myAmericanDream research ledger.

Checks:
  * research/sources.yaml entries against schema/source.schema.json
  * every research/facts/*.json fact against schema/fact.schema.json
  * unique source ids and unique fact ids (across all fact files)
  * every non-null fact source_id exists in sources.yaml
  * verified/stale facts have non-empty quote, url, retrieved_at, source_id
  * retrieved_at parses as ISO 8601 with a UTC offset
  * lookup facts (kind: lookup) have value null, a desk, and a lookup object
  * demo pin entries (<id>.demo.pin-*) point at an existing lookup fact
  * value_type (when present, and always on lookups) is one of the ten FactValue cases in
    ARCHITECTURE.md 13.z (text, code, codes, phone, date, money, quantity, weekdays, place, flag),
    and verified/stale/demo string values parse for their value_type; quantity needs a unit
  * topics (optional) is a list of ids that all appear in research/topics.yaml (unknown tag = error)
  * desk (when present) is a dotted lowercase desk id starting with a pack id
Exit 0 when clean, 1 on any error. Usage: python3 research/tools/validate.py [research_dir]
Requires: pyyaml, jsonschema  (pip install --user pyyaml jsonschema)
"""
import datetime
import glob
import json
import os
import sys

try:
    import yaml
    import jsonschema
except ImportError as e:  # pragma: no cover
    sys.exit(f"missing dependency: {e}. pip install --user pyyaml jsonschema")


VALUE_TYPES = {"text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag"}
PACKS = ("us", "us-fl", "us-fl-miamidade", "us-fl-miami")
WEEKDAYS = {"sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"}


BCP47 = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{1,8})*$")
PHONE = re.compile(r"^\+?[0-9]{3,15}$")
CURRENCY = re.compile(r"^[A-Z]{3}$")


def check_value(vt, v, fct=None):
    """Return a problem string if v does not type as value_type vt the way the server loader
    (server/src/myad_server/ledger.py coerce_value) types it, else None."""
    import decimal
    fct = fct or {}
    if isinstance(v, dict):
        if v.get("type") != vt:
            return f"typed value type {v.get('type')!r} does not match value_type"
        if vt == "place":
            pl = v.get("place") or {}
            c = pl.get("coordinate") or {}
            if not pl.get("name") or not isinstance(c.get("latitude"), (int, float)) or not isinstance(c.get("longitude"), (int, float)):
                return "place needs place.name and place.coordinate.{latitude,longitude}"
            if not (-90 <= c["latitude"] <= 90 and -180 <= c["longitude"] <= 180):
                return "coordinate out of range"
        return None
    try:
        if vt in ("quantity", "money"):
            if isinstance(v, bool) or not isinstance(v, (str, int, float)):
                return "expected a decimal string or number"
            decimal.Decimal(str(v))
            unit = fct.get("unit")
            if not unit:
                return f"{vt} needs unit"
            if vt == "money" and not CURRENCY.match(unit):
                return f"money unit must be an ISO 4217 code like USD (got {unit!r}); put the rest in unit_detail"
        elif vt == "phone":
            if not isinstance(v, str) or not PHONE.match(re.sub(r"[\s().\-]", "", v)):
                return "expected dialable digits (separators allowed, no extension)"
        elif vt == "flag":
            if not isinstance(v, bool):
                return "expected a JSON boolean"
        elif vt == "codes":
            if not isinstance(v, list) or not v or not all(isinstance(c, str) and c.strip() for c in v):
                return "expected a non-empty JSON array of strings"
        elif vt == "code":
            if not isinstance(v, (str, int)) or not str(v).strip():
                return "expected non-empty string"
        elif vt == "text":
            if not isinstance(v, str) or not v.strip():
                return "expected non-empty string"
            if not BCP47.match(fct.get("value_language") or ""):
                return "text value needs value_language (BCP-47, e.g. 'en')"
        elif vt == "date":
            datetime.date.fromisoformat(v)
        elif vt == "weekdays":
            days = v if isinstance(v, list) else [d.strip() for d in str(v).split(",")]
            days = [str(d).strip().lower() for d in days if str(d).strip()]
            if not days or any(d not in WEEKDAYS for d in days) or len(set(days)) != len(days):
                return "expected distinct lowercase weekday names"
        elif vt == "place":
            return "expected a typed place object {type: 'place', place: {...}}"
    except (decimal.InvalidOperation, ValueError, TypeError) as e:
        return str(e)
    return None


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def parse_iso(ts):
    try:
        d = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    return d if d.tzinfo is not None else None


def main(root):
    errors, warnings = [], []
    fact_schema = load_json(os.path.join(root, "schema", "fact.schema.json"))
    source_schema = load_json(os.path.join(root, "schema", "source.schema.json"))
    fv = jsonschema.Draft202012Validator(fact_schema, format_checker=jsonschema.FormatChecker())
    sv = jsonschema.Draft202012Validator(source_schema, format_checker=jsonschema.FormatChecker())

    with open(os.path.join(root, "sources.yaml"), encoding="utf-8") as f:
        src_doc = yaml.safe_load(f) or {}
    sources = src_doc.get("sources", [])
    if not isinstance(sources, list) or not sources:
        errors.append("sources.yaml: expected a non-empty top-level 'sources' list")
        sources = []
    source_ids = {}
    for i, s in enumerate(sources):
        sid = s.get("id", f"<index {i}>")
        for err in sv.iter_errors(s):
            errors.append(f"source {sid}: {err.json_path}: {err.message}")
        if sid in source_ids:
            errors.append(f"source {sid}: duplicate id")
        source_ids[sid] = s

    topics_path = os.path.join(root, "topics.yaml")
    topic_ids = set()
    if os.path.exists(topics_path):
        with open(topics_path, encoding="utf-8") as f:
            tdoc = yaml.safe_load(f) or {}
        for i, t in enumerate(tdoc.get("topics", [])):
            tid = t.get("id") if isinstance(t, dict) else None
            if not tid or not isinstance(tid, str) or tid != tid.lower() or " " in tid:
                errors.append(f"topics.yaml: entry {i} needs a lowercase slug id")
            elif tid in topic_ids:
                errors.append(f"topics.yaml: duplicate topic id '{tid}'")
            elif not (isinstance(t.get("description"), str) and t["description"].strip()):
                errors.append(f"topics.yaml: topic '{tid}' needs a one-line description")
            topic_ids.add(tid)
    else:
        errors.append("topics.yaml: missing (controlled vocabulary for fact topics)")

    facts = {}
    used_sources = set()
    files = sorted(glob.glob(os.path.join(root, "facts", "*.json")))
    if not files:
        errors.append("facts/: no fact files found")
    for path in files:
        name = os.path.relpath(path, root)
        try:
            doc = load_json(path)
        except json.JSONDecodeError as e:
            errors.append(f"{name}: invalid JSON: {e}")
            continue
        if not isinstance(doc, list):
            errors.append(f"{name}: expected a JSON array of facts")
            continue
        for i, fct in enumerate(doc):
            fid = fct.get("id", f"<index {i}>")
            where = f"{name}:{fid}"
            for err in fv.iter_errors(fct):
                errors.append(f"{where}: {err.json_path}: {err.message}")
            if fid in facts:
                errors.append(f"{where}: duplicate fact id (also in {facts[fid][0]})")
            facts[fid] = (name, fct)
            sid = fct.get("source_id")
            if sid:
                used_sources.add(sid)
                if sid not in source_ids:
                    errors.append(f"{where}: source_id '{sid}' not in sources.yaml")
            status = fct.get("status")
            if status in ("verified", "stale"):
                for k in ("quote", "url", "retrieved_at", "source_id"):
                    if not fct.get(k):
                        errors.append(f"{where}: status {status} requires non-empty {k}")
            if sid == "" and status not in ("unsourced", "demo"):
                errors.append(f"{where}: empty source_id only allowed for unsourced or demo facts")
            if status == "unsourced" and not fct.get("notes"):
                warnings.append(f"{where}: unsourced fact has no notes on what was searched")
            ts = fct.get("retrieved_at")
            if ts is not None and parse_iso(ts) is None:
                errors.append(f"{where}: retrieved_at '{ts}' is not ISO 8601 with an offset")
            vt = fct.get("value_type")
            if vt is not None and vt not in VALUE_TYPES:
                errors.append(f"{where}: value_type '{vt}' not one of {sorted(VALUE_TYPES)}")
            tps = fct.get("topics")
            if tps is not None:
                if not isinstance(tps, list) or not all(isinstance(t, str) for t in tps):
                    errors.append(f"{where}: topics must be a list of strings")
                else:
                    for t in tps:
                        if t not in topic_ids:
                            errors.append(f"{where}: topic '{t}' is not in topics.yaml")
            desk = fct.get("desk")
            if desk is not None and (not isinstance(desk, str) or desk != desk.lower() or " " in desk
                                     or not any(desk.startswith(p + ".") for p in PACKS)):
                errors.append(f"{where}: desk '{desk}' must be a lowercase desk id like us-fl-miamidade.311")
            if vt == "quantity" and not fct.get("unit"):
                errors.append(f"{where}: value_type quantity requires unit")
            if fct.get("kind") == "lookup":
                if fct.get("value") is not None:
                    errors.append(f"{where}: lookup fact must have value null")
                if not fct.get("desk"):
                    errors.append(f"{where}: lookup fact requires desk")
                if vt not in VALUE_TYPES:
                    errors.append(f"{where}: lookup fact requires value_type (one of the ten FactValue cases)")
            elif status in ("verified", "stale", "demo") and vt and fct.get("value") is not None:
                problem = check_value(vt, fct["value"], fct)
                if problem:
                    errors.append(f"{where}: value {fct['value']!r} does not parse as {vt}: {problem}")
            if fct.get("source_id") == "" and status in ("verified", "stale"):
                errors.append(f"{where}: empty source_id on a {status} fact")
            jur, fid_s = fct.get("jurisdiction"), str(fid)
            if jur and not (fid_s == jur or fid_s.startswith(jur + ".")):
                warnings.append(f"{where}: id prefix does not match jurisdiction '{jur}'")

    for fid, (name, fct) in facts.items():
        m = re.match(r"^(.*)\.demo\.(pin-[a-z0-9-]+)$", fid)
        if ".demo." in fid and not m:
            errors.append(f"{name}:{fid}: demo ids look like <lookup id>.demo.pin-<slug>")
        if m:
            parent = m.group(1)
            if parent not in facts or facts[parent][1].get("kind") != "lookup":
                errors.append(f"{name}:{fid}: demo value must hang off an existing kind:lookup fact '{parent}' "
                              f"(ranked results and 'none recorded' outcomes go in demo-outcomes.json)")
            elif fct.get("value_type") and fct.get("value_type") != facts[parent][1].get("value_type"):
                errors.append(f"{name}:{fid}: demo value_type differs from lookup '{parent}'")
            if fct.get("status") != "demo":
                errors.append(f"{name}:{fid}: demo pin entries must have status demo")
        if fct.get("status") == "demo" and fct.get("value") is None and fct.get("kind") != "lookup":
            errors.append(f"{name}:{fid}: a demo fact needs a value (use unsourced, or demo-outcomes.json for 'none')")
        if fct.get("kind", "static") == "static" and fct.get("value") is None and fct.get("status") not in ("unsourced",):
            errors.append(f"{name}:{fid}: a static fact needs a value unless status is unsourced")

    for sid in source_ids:
        if sid not in used_sources:
            warnings.append(f"source {sid}: not referenced by any fact")

    counts = {}
    for _, fct in facts.values():
        counts[fct.get("status")] = counts.get(fct.get("status"), 0) + 1
    corrected = sum(1 for _, f in facts.values() if f.get("correction_note"))
    lookups = sum(1 for _, f in facts.values() if f.get("kind") == "lookup")
    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print(f"sources={len(source_ids)} facts={len(facts)} files={len(files)} lookups={lookups} "
          f"corrections={corrected} by_status={json.dumps(counts, sort_keys=True)}")
    print("OK" if not errors else f"FAILED ({len(errors)} errors)")
    return 0 if not errors else 1


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(here)))
