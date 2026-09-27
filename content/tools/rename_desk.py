#!/usr/bin/env python3
"""Rename a desk id everywhere in content/ in one step.

Desk ids are provisional until myAD Research posts the final list. desks.yaml is the one
registry; this tool carries a rename from there into cards (desk, actions), lenses,
facts-requested.yaml (desk contact facts <desk-id>.<field>, desk fields, used_by), and
rebuilds build/Cards.xcstrings.

Usage: python3 content/tools/rename_desk.py OLD_ID NEW_ID [--dry-run]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CONTENT = Path(__file__).resolve().parent.parent
ID_RE = re.compile(r"^(us|us-fl|us-fl-miamidade|us-fl-miami)(\.[a-z0-9][a-z0-9-]*)+$")


def pattern(old: str) -> re.Pattern:
    # the id itself, or the id followed by ".<field>"; never a longer id that merely starts with it
    return re.compile(rf"(?<![\w.-]){re.escape(old)}(?=\.[a-z]|[^\w.-]|$)", re.MULTILINE)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--content", type=Path, default=CONTENT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    if not ID_RE.match(args.new):
        print(f"{args.new!r} is not a region-scoped desk id")
        return 2
    files = [args.content / "desks.yaml", args.content / "facts-requested.yaml"]
    files += sorted((args.content / "cards").glob("*.yaml")) + sorted((args.content / "lenses").glob("*.yaml"))
    rx = pattern(args.old)
    if not rx.search((args.content / "desks.yaml").read_text(encoding="utf-8")):
        print(f"{args.old} is not in desks.yaml")
        return 2
    changed = 0
    for path in files:
        text = path.read_text(encoding="utf-8")
        new_text, n = rx.subn(args.new, text)
        if n:
            changed += 1
            print(f"{path.relative_to(args.content)}: {n} replacement(s)")
            if not args.dry_run:
                path.write_text(new_text, encoding="utf-8")
    if not args.dry_run and changed:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import build_strings
        build_strings.main(["--content", str(args.content)])
    print(f"{changed} file(s) {'would change' if args.dry_run else 'changed'}; run tools/validate.py next")
    return 0


if __name__ == "__main__":
    sys.exit(main())
