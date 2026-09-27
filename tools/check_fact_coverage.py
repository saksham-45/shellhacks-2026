#!/usr/bin/env python3
"""Fail if a card references a fact the ledger does not have.

Checks every content/cards/*.yaml:
  - each {fact:<id>} placeholder in any copy field is listed in the card's fact_refs
  - each placeholder and fact_ref exists in research/facts/*.json
Passes when there are no cards.

Usage: check_fact_coverage.py [--root DIR]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

PLACEHOLDER = re.compile(r"\{fact:([^}\s]+)\}")


def ledger_ids(root: Path) -> tuple[set[str], list[str]]:
    ids: set[str] = set()
    errs: list[str] = []
    for path in sorted((root / "research" / "facts").glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            errs.append(f"{path}: unreadable ledger ({e})")
            continue
        facts = data.get("facts", []) if isinstance(data, dict) else data
        for fact in facts:
            if isinstance(fact, dict) and "id" in fact:
                ids.add(str(fact["id"]))
            else:
                errs.append(f"{path}: fact without id: {fact!r}")
    return ids, errs


def _strings(node) -> list[str]:
    if isinstance(node, str):
        return [node]
    if isinstance(node, dict):
        return [s for v in node.values() for s in _strings(v)]
    if isinstance(node, list):
        return [s for v in node for s in _strings(v)]
    return []


def card_problems(path: Path, ledger: set[str]) -> list[str]:
    try:
        card = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as e:
        return [f"{path}: unreadable card ({e})"]
    if not isinstance(card, dict):
        return [f"{path}: card is not a mapping"]
    refs = [str(r) for r in (card.get("fact_refs") or [])]
    copy = {k: v for k, v in card.items() if k != "fact_refs"}
    placeholders = {m for s in _strings(copy) for m in PLACEHOLDER.findall(s)}
    errs = []
    for pid in sorted(placeholders - set(refs)):
        errs.append(f"{path}: placeholder {{fact:{pid}}} not in fact_refs")
    for fid in sorted((placeholders | set(refs)) - ledger):
        errs.append(f"{path}: fact {fid!r} missing from research/facts/*.json")
    return errs


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args(argv)
    ledger, errs = ledger_ids(args.root)
    cards = sorted((args.root / "content" / "cards").glob("*.yaml"))
    for c in cards:
        errs += card_problems(c, ledger)
    for e in errs:
        print(e, file=sys.stderr)
    print(f"fact coverage: {len(cards)} card(s), {len(ledger)} fact(s), {len(errs)} problem(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
