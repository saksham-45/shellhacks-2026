#!/usr/bin/env python3
"""Compile card, desk, and lens copy into the "Cards" string catalog (Cards.xcstrings).

Keys (ADCore StringKey, table "Cards"):
    card.<card-id>.title | .summary | .body
    desk.<desk-id>.name
    lens.<lens-id>.title | .summary
    lens.<lens-id>.line.<card-id>

en is the source language. es/ht carry state "needs_review" while the file's
translation_status says draft, "translated" once reviewed. {fact:<id>} placeholders stay
literal; the app resolves them from the ledger at render time.

Usage:
    python3 content/tools/build_strings.py            # writes content/build/Cards.xcstrings
    python3 content/tools/build_strings.py --check    # exit 1 if that file is stale
    python3 content/tools/build_strings.py --out PATH # write somewhere else (Lead decides where)

Dependencies: Python 3.12 standard library plus PyYAML.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

LANGS = ("en", "es", "ht")
CONTENT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = CONTENT / "build" / "Cards.xcstrings"


def _entry(loc: dict, status: dict, comment: str) -> dict:
    localizations = {}
    for lang in LANGS:
        state = "translated" if lang == "en" or status.get(lang) == "reviewed" else "needs_review"
        localizations[lang] = {"stringUnit": {"state": state, "value": loc[lang]}}
    return {"comment": comment, "extractionState": "manual", "localizations": localizations}


def build(content: Path = CONTENT) -> dict:
    strings: dict[str, dict] = {}
    for path in sorted((content / "cards").glob("*.yaml")):
        card = yaml.safe_load(path.read_text(encoding="utf-8"))
        status = card.get("translation_status", {})
        for field in ("title", "summary", "body"):
            strings[f"card.{card['id']}.{field}"] = _entry(card[field], status, f"Card {card['id']} {field}")
    desks = yaml.safe_load((content / "desks.yaml").read_text(encoding="utf-8"))
    for desk in desks["desks"]:
        strings[f"desk.{desk['id']}.name"] = _entry(desk["name"], desks.get("translation_status", {}),
                                                    f"Desk name {desk['id']}")
    for path in sorted((content / "lenses").glob("*.yaml")):
        lens = yaml.safe_load(path.read_text(encoding="utf-8"))
        status = lens.get("translation_status", {})
        for field in ("title", "summary"):
            strings[f"lens.{lens['id']}.{field}"] = _entry(lens[field], status, f"Origin lens {lens['id']} {field}")
        for line in lens["origin_lines"]:
            strings[f"lens.{lens['id']}.line.{line['card']}"] = _entry(
                line["text"], status, f"Origin line from lens {lens['id']} on card {line['card']}")
    return {"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"}


def render(catalog: dict) -> str:
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--content", type=Path, default=CONTENT)
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--check", action="store_true", help="fail if the output file is not up to date")
    args = ap.parse_args(argv)
    out = args.out or (args.content / "build" / "Cards.xcstrings")
    text = render(build(args.content))
    if args.check:
        if not out.exists() or out.read_text(encoding="utf-8") != text:
            print(f"{out} is stale: run content/tools/build_strings.py")
            return 1
        print(f"{out.name} up to date ({len(json.loads(text)['strings'])} keys)")
        return 0
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(f"wrote {out.name}: {len(json.loads(text)['strings'])} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
