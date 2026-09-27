#!/usr/bin/env python3
"""Compile content/cards/*.yaml into the ONE canonical card bundle (ARCHITECTURE.md §13.x).

Writes:
  contracts/content/cards.json          canonical bundle (the server reads this; env MYAD_CARDS_BUNDLE)
  contracts/content/cards.schema.json   JSON Schema of the bundle
  ios/App/Resources/Generated/cards.json  byte-identical copy for the app

Owner: myAD Lead. Deterministic: sorted keys, cards ordered by id, lists kept in content's order
(stages sorted, modes sorted). Zero cards -> {"cards": [], "version": 1}.

  python3 tools/build_content_bundle.py            # write
  python3 tools/build_content_bundle.py --check    # exit 1 if any written file is stale (ci.sh)

Topic slugs are validated against research/topics.yaml when that file exists (skipped otherwise).
needs_review: content may set `needs_review: {es: bool, en: bool, ht: bool}` or a list of
languages; when absent, es and ht default to true (not yet reviewed) and en to false.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

LANGS = ("es", "en", "ht")
BUNDLE_VERSION = 1
CARD_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
FACT_ID = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$")
SLUG = re.compile(r"^[a-z0-9]+([_-][a-z0-9]+)*$")
SCOPES = ("household", "person", "person-papers")
MODES = ("resident", "tourist")
REGION_PACKS = ("us", "us-fl", "us-fl-miamidade", "us-fl-miami")
# AppAction wire types a card may offer (contracts/intent/app_action.*.json).
ACTION_TYPES = ("call_desk", "open_map", "read_aloud", "navigate", "next_step", "previous_step")

SCHEMA: dict = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://myamericandream.invalid/contracts/content/cards.schema.json",
    "title": "myAD compiled card bundle",
    "type": "object",
    "additionalProperties": False,
    "required": ["version", "cards"],
    "properties": {
        "version": {"const": BUNDLE_VERSION},
        "cards": {"type": "array", "items": {"$ref": "#/$defs/card"}},
    },
    "$defs": {
        "lang3_text": {
            "type": "object", "additionalProperties": False, "required": list(LANGS),
            "properties": {lang: {"type": "string"} for lang in LANGS},
        },
        "lang3_phrases": {
            "type": "object", "additionalProperties": False, "required": list(LANGS),
            "properties": {lang: {"type": "array", "items": {"type": "string", "minLength": 1}} for lang in LANGS},
        },
        "lang3_flags": {
            "type": "object", "additionalProperties": False, "required": list(LANGS),
            "properties": {lang: {"type": "boolean"} for lang in LANGS},
        },
        "action": {
            "oneOf": [
                {"enum": list(ACTION_TYPES)},
                {"type": "object", "required": ["type"], "properties": {"type": {"enum": list(ACTION_TYPES)}}},
            ]
        },
        "card": {
            "type": "object",
            "additionalProperties": False,
            "required": ["id", "title", "desk", "scope", "stages", "modes", "region_pack", "fact_refs",
                         "topics", "utterances", "actions", "needs_review", "immigration"],
            "properties": {
                "id": {"type": "string", "pattern": CARD_ID.pattern},
                "title": {"$ref": "#/$defs/lang3_text"},
                "desk": {"type": "string", "minLength": 1},
                "scope": {"enum": list(SCOPES)},
                "stages": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": 10}, "uniqueItems": True},
                "modes": {"type": "array", "items": {"enum": list(MODES)}, "minItems": 1, "uniqueItems": True},
                "region_pack": {"enum": list(REGION_PACKS)},
                "fact_refs": {"type": "array", "items": {"type": "string", "pattern": FACT_ID.pattern}},
                "topics": {"type": "array", "items": {"type": "string", "pattern": SLUG.pattern}},
                "utterances": {"$ref": "#/$defs/lang3_phrases"},
                "actions": {"type": "array", "items": {"$ref": "#/$defs/action"}},
                "needs_review": {"$ref": "#/$defs/lang3_flags"},
                "immigration": {"type": "boolean"},
            },
        },
    },
}


class BundleError(ValueError):
    def __init__(self, problems: list[str]):
        super().__init__("\n".join(problems))
        self.problems = problems


def load_topics(root: Path) -> frozenset[str] | None:
    """Same accepted shapes as server/src/myad_server/topics.py; None when the file is absent."""
    path = root / "research" / "topics.yaml"
    if not path.is_file():
        return None
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    raw = data.get("topics", data) if isinstance(data, dict) else data
    if isinstance(raw, dict):
        return frozenset(str(k) for k in raw)
    slugs = set()
    for item in raw or []:
        if isinstance(item, str):
            slugs.add(item)
        elif isinstance(item, dict) and (item.get("id") or item.get("slug")):
            slugs.add(str(item.get("id") or item.get("slug")))
    return frozenset(slugs)


def _lang3(value, field: str, cid: str, problems: list[str], kind: str) -> dict:
    if not isinstance(value, dict):
        problems.append(f"{cid}: {field} must be a mapping with {', '.join(LANGS)}")
        return {lang: ([] if kind == "phrases" else "") for lang in LANGS}
    out = {}
    for lang in LANGS:
        v = value.get(lang)
        if kind == "text":
            if not isinstance(v, str):
                problems.append(f"{cid}: {field}.{lang} missing")
                v = ""
            out[lang] = v
        else:
            if v is None:
                v = []
            if isinstance(v, str):
                v = [v]
            if not isinstance(v, list) or not all(isinstance(p, str) and p.strip() for p in v):
                problems.append(f"{cid}: {field}.{lang} must be a list of non-empty strings")
                v = []
            out[lang] = [p.strip() for p in v]
    extra = sorted(set(value) - set(LANGS))
    if extra:
        problems.append(f"{cid}: {field} has unknown languages {extra}")
    return out


def _needs_review(value, cid: str, problems: list[str]) -> dict:
    default = {"es": True, "en": False, "ht": True}
    if value is None:
        return default
    if isinstance(value, list):
        return {lang: lang in value for lang in LANGS}
    if isinstance(value, dict):
        out = dict(default)
        for lang, flag in value.items():
            if lang not in LANGS or not isinstance(flag, bool):
                problems.append(f"{cid}: needs_review.{lang} must be true/false for es/en/ht")
                continue
            out[lang] = flag
        return out
    problems.append(f"{cid}: needs_review must be a mapping or list of languages")
    return default


def compile_card(path: Path, topics: frozenset[str] | None, problems: list[str]) -> dict | None:
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        problems.append(f"{path.name}: not YAML ({e})")
        return None
    if not isinstance(raw, dict):
        problems.append(f"{path.name}: expected a mapping")
        return None
    cid = raw.get("id")
    if not isinstance(cid, str) or not CARD_ID.match(cid):
        problems.append(f"{path.name}: id must be kebab-case")
        return None
    if cid != path.stem:
        problems.append(f"{path.name}: id {cid!r} must equal the file name")

    desk = raw.get("desk")
    if not isinstance(desk, str) or not desk.strip():
        problems.append(f"{cid}: every card names a desk (ARCHITECTURE.md §12)")
        desk = ""
    scope = raw.get("privacy_scope", raw.get("scope"))
    if scope not in SCOPES:
        problems.append(f"{cid}: privacy_scope must be one of {SCOPES}")
    stages = raw.get("stages") or []
    if not isinstance(stages, list) or any(not isinstance(s, int) or isinstance(s, bool) or not 1 <= s <= 10 for s in stages):
        problems.append(f"{cid}: stages are integers 1-10")
        stages = []
    modes = raw.get("modes") or ["resident"]
    if not isinstance(modes, list) or any(m not in MODES for m in modes) or not modes:
        problems.append(f"{cid}: modes are {MODES}")
        modes = ["resident"]
    pack = raw.get("region_pack")
    if pack not in REGION_PACKS:
        problems.append(f"{cid}: region_pack must be one of {REGION_PACKS}")
    fact_refs = raw.get("fact_refs") or []
    bad = [r for r in fact_refs if not isinstance(r, str) or not FACT_ID.match(r)]
    if bad:
        problems.append(f"{cid}: bad fact ids {bad}")
    card_topics = raw.get("topics") or []
    if not isinstance(card_topics, list) or any(not isinstance(t, str) or not SLUG.match(t) for t in card_topics):
        problems.append(f"{cid}: topics are slugs")
        card_topics = []
    if topics is not None:
        unknown = sorted(set(card_topics) - topics)
        if unknown:
            problems.append(f"{cid}: unknown topics {unknown} (research/topics.yaml)")
    actions = raw.get("actions") or []
    for a in actions:
        name = a if isinstance(a, str) else a.get("type") if isinstance(a, dict) else None
        if name not in ACTION_TYPES:
            problems.append(f"{cid}: unknown action {a!r} (allowed: {ACTION_TYPES})")
    immigration = raw.get("immigration", scope == "person-papers")
    if not isinstance(immigration, bool):
        problems.append(f"{cid}: immigration must be true/false")
        immigration = False

    return {
        "id": cid,
        "title": _lang3(raw.get("title"), "title", cid, problems, "text"),
        "desk": desk,
        "scope": scope,
        "stages": sorted(set(stages)),
        "modes": sorted(set(modes)),
        "region_pack": pack,
        "fact_refs": list(dict.fromkeys(fact_refs)),
        "topics": list(dict.fromkeys(card_topics)),
        "utterances": _lang3(raw.get("utterances", {}), "utterances", cid, problems, "phrases"),
        "actions": actions,
        "needs_review": _needs_review(raw.get("needs_review"), cid, problems),
        "immigration": immigration,
    }


def build(root: Path) -> dict:
    problems: list[str] = []
    topics = load_topics(root)
    cards = []
    for path in sorted((root / "content" / "cards").glob("*.yaml")):
        card = compile_card(path, topics, problems)
        if card:
            cards.append(card)
    ids = [c["id"] for c in cards]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        problems.append(f"duplicate card ids {dupes}")
    if problems:
        raise BundleError(problems)
    return {"version": BUNDLE_VERSION, "cards": sorted(cards, key=lambda c: c["id"])}


def render(obj: dict) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def outputs(root: Path) -> dict[Path, bytes]:
    bundle = render(build(root))
    return {
        root / "contracts" / "content" / "cards.json": bundle,
        root / "contracts" / "content" / "cards.schema.json": render(SCHEMA),
        root / "ios" / "App" / "Resources" / "Generated" / "cards.json": bundle,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--check", action="store_true", help="fail if the checked-in files are stale")
    args = ap.parse_args(argv)
    try:
        files = outputs(args.root.resolve())
    except BundleError as e:
        print("content bundle: FAIL", file=sys.stderr)
        for p in e.problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    stale = [p for p, data in files.items() if not p.is_file() or p.read_bytes() != data]
    if args.check:
        for p in stale:
            print(f"stale: {p.relative_to(args.root.resolve())} (run tools/build_content_bundle.py)", file=sys.stderr)
        print("content bundle: " + ("STALE" if stale else "up to date"))
        return 1 if stale else 0
    for p, data in files.items():
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.is_file() or p.read_bytes() != data:
            p.write_bytes(data)
    print(f"content bundle: wrote {len(json.loads(files[args.root.resolve() / 'contracts/content/cards.json']))} top-level keys, "
          f"{len(json.loads(files[args.root.resolve() / 'contracts/content/cards.json'])['cards'])} cards")
    return 0


if __name__ == "__main__":
    sys.exit(main())
