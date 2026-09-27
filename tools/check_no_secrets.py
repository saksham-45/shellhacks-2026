#!/usr/bin/env python3
"""Fail on obvious secrets in the tree (it is headed for a public repo).

Keys come from environment variables only (e.g. GEMINI_API_KEY). Detects Google API keys (AIza...),
OpenAI-style keys (sk-...), GitHub tokens (ghp_/gho_/ghu_/ghs_/ghr_), and PEM private key blocks.
Also fails if a .env* file (other than .env.example) is present in the tree.

Usage: check_no_secrets.py [--root DIR]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", ".build", "build", ".venv", "__pycache__", "DerivedData", "node_modules", ".pytest_cache"}
# This checker's own fail fixtures hold fake keys on purpose.
SKIP_PREFIX = ("tools", "tests", "fixtures")
MAX_BYTES = 2_000_000

PATTERNS = {
    "google-api-key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "openai-style-key": re.compile(r"\bsk-(?:proj-|live-|test-)?[A-Za-z0-9_\-]{20,}"),
    "github-token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}"),
    "private-key-block": re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"),
}


def scan(root: Path) -> list[str]:
    errs = []
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).parts
        if SKIP_DIRS.intersection(rel) or rel[:3] == SKIP_PREFIX or not p.is_file():
            continue
        if p.name.startswith(".env") and p.name != ".env.example":
            errs.append(f"{p}: .env file in tree (use environment variables)")
            continue
        try:
            if p.stat().st_size > MAX_BYTES:
                continue
            text = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for name, rx in PATTERNS.items():
            for m in rx.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                errs.append(f"{p}:{line}: possible {name}")
    return errs


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = ap.parse_args(argv)
    errs = scan(args.root)
    for e in errs:
        print(e, file=sys.stderr)
    print(f"no secrets: {len(errs)} problem(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
