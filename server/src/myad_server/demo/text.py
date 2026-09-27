"""Shared text normalization for the demo matchers (same convention as data/ask_policy.yaml): lowercase,
accents stripped, punctuation and apostrophes turned into spaces."""
from __future__ import annotations

import re
import unicodedata

_PUNCT = re.compile(r"[^\w$]+", re.UNICODE)
_SPACES = re.compile(r"\s+")


def strip_accents(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))


def normalize(text: str) -> str:
    t = strip_accents(text).casefold().replace("_", " ")
    return _SPACES.sub(" ", _PUNCT.sub(" ", t)).strip()


def compile_pattern(pattern: str) -> re.Pattern[str]:
    """Patterns are written for normalized text; accents in a pattern are stripped too."""
    return re.compile(strip_accents(pattern).casefold())


def compile_words(fragments: list[str]) -> re.Pattern[str]:
    """One alternation of word/phrase fragments, each anchored on word boundaries."""
    body = "|".join(f"(?:{strip_accents(f).casefold()})" for f in fragments)
    return re.compile(rf"\b(?:{body})\b")
