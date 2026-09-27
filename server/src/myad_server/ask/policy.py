"""Loads data/ask_policy.yaml: desk-only classifier lexicons and rules, jurisdiction chain for the generic
desk, immigration topics, action verbs."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

import yaml

from ..topics import unknown_topics
from ..verifier import DESK_ONLY_KINDS
from ..visibility import load_immigration_topics
from .desk_only import DeskOnlyHit, DeskOnlyRule, Lexicon, classify, parse_rules, tokenize

POLICY_PATH = Path(__file__).resolve().parent.parent / "data" / "ask_policy.yaml"
LEVELS = ("country", "state", "county", "city")

__all__ = ["AskPolicy", "DeskOnlyRule", "DeskOnlyHit", "Jurisdictions", "load_policy", "POLICY_PATH"]


@dataclass(frozen=True)
class Jurisdictions:
    """Pack hierarchy used to pick the generic desk (mirrors server/regionpacks/*/manifest.json)."""

    parents: dict[str, str | None]
    levels: dict[str, str]
    unknown: str

    def ancestors(self, pack: str) -> list[str]:
        """`pack` and its parents, most local first."""
        out: list[str] = []
        cur: str | None = pack
        while cur is not None and cur not in out:
            out.append(cur)
            cur = self.parents.get(cur)
        return out

    def depth(self, pack: str) -> int:
        return len(self.ancestors(pack)) if pack in self.parents else -1

    def most_local(self, chain) -> str:
        """The most local known pack of a resolved chain. Unknown, or nothing below the county level known:
        the configured county (never a city the household was not resolved into)."""
        known = [p for p in (chain or ()) if p in self.parents]
        if known:
            best = max(known, key=self.depth)
            if LEVELS.index(self.levels[best]) >= LEVELS.index("county"):
                return best
        return self.unknown


@dataclass(frozen=True)
class AskPolicy:
    desk_only: tuple[DeskOnlyRule, ...]
    immigration_topics: frozenset[str]
    action_verbs: dict[str, re.Pattern[str]]
    lexicons: dict[str, Lexicon] = field(default_factory=dict)
    jurisdictions: Jurisdictions | None = None
    generic_desk_names: tuple[str, ...] = ()
    # Memo of classify() by exact text; the classifier is pure, so this only saves time.
    _memo: dict[str, DeskOnlyHit | None] = field(default_factory=dict, compare=False, repr=False)

    def all_topics(self) -> list[str]:
        return sorted({t for r in self.desk_only for t in r.topics} | set(self.immigration_topics))

    def classify(self, text: str) -> DeskOnlyHit | None:
        if text not in self._memo:
            if len(self._memo) >= 4096:
                self._memo.clear()
            self._memo[text] = classify(self.desk_only, text)
        return self._memo[text]

    def card_desk_only(self, utterances) -> DeskOnlyRule | None:
        """Second line of defence: a card any of whose own utterances is a HARD desk-only question is a
        desk-only card and never grounds an answer."""
        for text in utterances:
            hit = self.classify(text)
            if hit is not None and hit.hard:
                return hit.rule
        return None

    @staticmethod
    def in_domain(rule: DeskOnlyRule, utterances) -> bool:
        """True when a card's utterances use the rule's ambiguous domain (the card is about that domain)."""
        return rule.ambiguous_domain is not None and any(rule.soft(tokenize(t)) for t in utterances)


def _jurisdictions(raw: object, path: Path) -> Jurisdictions:
    if not isinstance(raw, dict):
        raise ValueError(f"{path}: jurisdictions must be a mapping")
    parents, levels, unknown = raw.get("parents"), raw.get("levels"), raw.get("unknown")
    if not isinstance(parents, dict) or not all(isinstance(k, str) and (v is None or isinstance(v, str))
                                                for k, v in parents.items()):
        raise ValueError(f"{path}: jurisdictions.parents must map pack ids to a parent pack id or null")
    if not isinstance(levels, dict) or set(levels) != set(parents) or not set(levels.values()) <= set(LEVELS):
        raise ValueError(f"{path}: jurisdictions.levels must give every pack one of {LEVELS}")
    for pack, parent in parents.items():
        if parent is not None and parent not in parents:
            raise ValueError(f"{path}: jurisdictions: parent {parent!r} of {pack!r} is not declared")
        if parent is not None and LEVELS.index(levels[parent]) >= LEVELS.index(levels[pack]):
            raise ValueError(f"{path}: jurisdictions: {pack!r} must be more local than its parent {parent!r}")
    if unknown not in parents or levels[unknown] != "county":
        raise ValueError(f"{path}: jurisdictions.unknown must be a declared county pack")
    return Jurisdictions(dict(parents), dict(levels), unknown)


def load_policy(path: Path = POLICY_PATH, topics: frozenset[str] | None = None) -> AskPolicy:
    """Validated policy. Parsing is cached per (file, mtime, size, topics): the result is immutable and the
    same file always validates the same way, so a changed file is re-read and re-validated."""
    stat = Path(path).stat()
    return _load_policy(Path(path), stat.st_mtime_ns, stat.st_size, frozenset(topics) if topics is not None else None)


@lru_cache(maxsize=16)
def _load_policy(path: Path, _mtime_ns: int, _size: int, topics: frozenset[str] | None) -> AskPolicy:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: policy must be a mapping")
    raw_lexicons = data.get("lexicons")
    if not isinstance(raw_lexicons, dict) or not raw_lexicons:
        raise ValueError(f"{path}: lexicons must be a non-empty mapping")
    lexicons = {name: Lexicon.parse(name, entries) for name, entries in raw_lexicons.items()}
    rules = parse_rules(data.get("desk_only"), lexicons, DESK_ONLY_KINDS, str(path))
    names = data.get("generic_desk_names", [])
    if not isinstance(names, list) or not all(isinstance(n, str) and n for n in names):
        raise ValueError(f"{path}: generic_desk_names must be a list of desk names")
    immigration_topics = load_immigration_topics(path)
    policy = AskPolicy(
        rules, immigration_topics,
        {k: re.compile(v) for k, v in (data.get("action_verbs") or {}).items()},
        lexicons=lexicons,
        jurisdictions=_jurisdictions(data.get("jurisdictions"), path),
        generic_desk_names=tuple(names),
    )
    # Desk-only rule tags are compiled card topics and must use the research vocabulary.
    bad = unknown_topics([topic for rule in policy.desk_only for topic in rule.topics], topics)
    if bad:
        raise ValueError(f"{path}: unknown topics {bad} (research/topics.yaml)")
    return policy
