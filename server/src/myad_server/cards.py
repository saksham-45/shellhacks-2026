"""Compiled card bundle (ARCHITECTURE.md §13.x): `contracts/content/cards.json` (+ cards.schema.json),
written by Lead's tools/build_content_bundle.py; the path is overridable by env MYAD_CARDS_BUNDLE.

The model mirrors contracts/content/cards.schema.json exactly (every field required, no extra keys), so a
bundle that drifts from the schema fails at start-up. The server uses the bundle as its intent index
(card utterances) and never renders its copy as prose of its own.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from .topics import unknown_topics
from .visibility import IMMIGRATION_TOPICS
from .values import FACT_ID

ActionName = Literal["call_desk", "open_map", "read_aloud", "navigate", "next_step", "previous_step"]


class CardError(ValueError):
    def __init__(self, problems: list[str]):
        super().__init__(f"{len(problems)} card bundle problem(s):\n" + "\n".join(problems))
        self.problems = problems


class Lang3Text(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    es: str
    en: str
    ht: str

    def values(self) -> list[str]:
        return [self.es, self.en, self.ht]


class Lang3Phrases(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    es: list[str]
    en: list[str]
    ht: list[str]


class Lang3Flags(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)
    es: bool
    en: bool
    ht: bool


class ActionObject(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True)
    type: ActionName


class BundleCard(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    id: str = Field(pattern=r"^[a-z0-9]+(-[a-z0-9]+)*$")
    title: Lang3Text
    desk: str = Field(min_length=1)  # every card names a desk (§12)
    scope: Literal["household", "person", "person-papers"]
    stages: list[int]
    modes: list[Literal["resident", "tourist"]] = Field(min_length=1)
    region_pack: Literal["us", "us-fl", "us-fl-miamidade", "us-fl-miami"]
    fact_refs: list[str]
    topics: list[str]
    utterances: Lang3Phrases
    actions: list[ActionName | ActionObject]
    needs_review: Lang3Flags
    immigration: bool

    @field_validator("stages")
    @classmethod
    def _stages(cls, v: list[int]) -> list[int]:
        if any(not 1 <= s <= 10 for s in v) or len(set(v)) != len(v):
            raise ValueError("stages are unique, 1-10")
        return v

    @field_validator("modes")
    @classmethod
    def _modes(cls, v: list[str]) -> list[str]:
        if len(set(v)) != len(v):
            raise ValueError("modes repeat")
        return v

    @property
    def action_keys(self) -> frozenset[str]:
        return frozenset(a if isinstance(a, str) else a.type for a in self.actions)

    def all_utterances(self) -> list[tuple[str, str]]:
        u = self.utterances
        return [(lang, text) for lang, texts in (("es", u.es), ("en", u.en), ("ht", u.ht)) for text in texts
                if text.strip()]


@dataclass
class CardBundle:
    cards: dict[str, BundleCard] = field(default_factory=dict)
    source: str = "empty"
    missing: bool = True

    def get(self, card_id: str) -> BundleCard | None:
        return self.cards.get(card_id)


def parse_bundle(data: Any, topics: frozenset[str] | None = None, source: str = "<memory>") -> CardBundle:
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("cards"), list) \
            or set(data) - {"version", "cards"}:
        raise CardError([f"{source}: expected {{\"version\": 1, \"cards\": [...]}} (cards.schema.json)"])
    rows = data["cards"]
    problems: list[str] = []
    bundle = CardBundle(source=source, missing=False)
    for i, row in enumerate(rows):
        try:
            card = BundleCard.model_validate(row)
        except ValidationError as e:
            rid = row.get("id") if isinstance(row, dict) else None
            err = e.errors()[0]
            problems.append(f"{source}[{i}] {rid!r}: {err['loc']} {err['msg']}")
            continue
        if card.id in bundle.cards:
            problems.append(f"{card.id}: duplicate card id")
        bad_refs = [r for r in card.fact_refs if not FACT_ID.match(r)]
        if bad_refs:
            problems.append(f"{card.id}: bad fact ids {bad_refs}")
        bad = unknown_topics(card.topics, topics)
        if bad:
            problems.append(f"{card.id}: unknown topics {bad} (research/topics.yaml)")
        if set(card.topics).intersection(IMMIGRATION_TOPICS) and not card.immigration:
            problems.append(f"{card.id}: immigration topic requires immigration: true")
        bundle.cards[card.id] = card
    if problems:
        raise CardError(problems)
    return bundle


def load_bundle(path: Path, topics: frozenset[str] | None = None) -> CardBundle:
    """Missing file -> an empty bundle (the /ask flow then answers with confidence 0, no grounding)."""
    if not path.is_file():
        return CardBundle(source=str(path), missing=True)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise CardError([f"{path}: not JSON ({e.msg})"]) from e
    return parse_bundle(data, topics, source=path.name)
