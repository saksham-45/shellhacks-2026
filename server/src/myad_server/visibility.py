"""Shared card and fact visibility policy.

Tourist mode hides immigration content whether the compiled card flag is set or
its reviewed topic vocabulary identifies the card as immigration content.  The same
topic set hides immigration-topic ledger facts on every path (claims, request
evidence, desk contacts), so a fact cannot reach a tourist response by a side door.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml

_REQUIRED_FALLBACK = frozenset({"immigration", "tps", "visa", "asylum", "uscis", "status"})
_POLICY_PATH = Path(__file__).resolve().parent / "data" / "ask_policy.yaml"
_SLUG = re.compile(r"^[a-z0-9]+([_-][a-z0-9]+)*$")


def load_immigration_topics(path: Path = _POLICY_PATH) -> frozenset[str]:
    """Load and validate the policy's immigration topic set."""
    data: Any = yaml.safe_load(path.read_text(encoding="utf-8"))
    raw = data.get("immigration_topics") if isinstance(data, dict) else None
    if not isinstance(raw, list) or not raw or not all(isinstance(topic, str) for topic in raw):
        raise ValueError(f"{path}: immigration_topics must be a non-empty list of strings")
    topics = frozenset(raw)
    if len(topics) != len(raw) or any(not _SLUG.fullmatch(topic) for topic in raw):
        raise ValueError(f"{path}: immigration_topics must contain unique topic slugs")
    if not _REQUIRED_FALLBACK.issubset(topics):
        missing = sorted(_REQUIRED_FALLBACK - topics)
        raise ValueError(f"{path}: immigration_topics missing required ids {missing}")
    return topics


IMMIGRATION_TOPICS = load_immigration_topics()


def is_immigration_card(card: Any, immigration_topics: frozenset[str] | None = None) -> bool:
    topics = immigration_topics if immigration_topics is not None else IMMIGRATION_TOPICS
    return bool(getattr(card, "immigration", False) or topics.intersection(getattr(card, "topics", ())))


def card_visible(card: Any, mode: Any, immigration_topics: frozenset[str] | None = None) -> bool:
    mode_value = getattr(mode, "value", mode)
    if mode_value == "tourist":
        return "tourist" in card.modes and not is_immigration_card(card, immigration_topics)
    return "resident" in card.modes


def is_immigration_fact(fact: Any, immigration_topics: frozenset[str] | None = None) -> bool:
    """A ledger fact (``LedgerFact`` or its raw row) whose reviewed topics mark it as immigration content."""
    topics = immigration_topics if immigration_topics is not None else IMMIGRATION_TOPICS
    raw = getattr(fact, "raw", fact)
    return bool(topics.intersection(getattr(raw, "topics", None) or ()))


def fact_visible(fact: Any, mode: Any, immigration_topics: frozenset[str] | None = None) -> bool:
    """Tourist mode never shows an immigration-topic fact, whichever path (claim, evidence, contact) found it.

    An unknown fact (``None``) is visible here; ledger admission is the verifier's job, not this policy's.
    """
    if fact is None:
        return True
    mode_value = getattr(mode, "value", mode)
    return not (mode_value == "tourist" and is_immigration_fact(fact, immigration_topics))
