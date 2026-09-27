"""Small, deterministic, offline intent retrieval.

The index deliberately has no language classifier.  Every card is indexed with its
Spanish, English, and Haitian Creole utterances in one pool; this is what lets a
code-switched request such as ``cuándo es el trash day`` match one card.
"""
from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable, Mapping
from dataclasses import dataclass

from ..cards import BundleCard, CardBundle
from ..values import Mode
from ..visibility import is_immigration_card

_PUNCT = re.compile(r"[^\w\s]|_", re.UNICODE)
_WS = re.compile(r"\s+")

# Function words are not useful evidence for an intent.  They are removed only
# for scoring; normalize() itself remains a faithful text normalizer.
_STOPWORDS = frozenset("""
a an the i my me to of for is are am do does how what where when can could you your it
in on at and or please want need would like be this that with about
el la los las un una unos unas de del y o que como donde cuando mi mis me yo es son por para
en al se lo le les puedo quiero necesito hay tengo su sus te tu favor esta este esto
mwen m ou li nou yo nan pou ak ki se kijan kote kile eske ye sa yon gen vle bezwen kapab kap fe
""".split())

def normalize(text: str) -> str:
    """Case-fold, remove accents, replace punctuation with spaces, and trim."""
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    unaccented = "".join(c for c in decomposed if not unicodedata.combining(c))
    return _WS.sub(" ", _PUNCT.sub(" ", unaccented)).strip()


def _tokens(text: str) -> tuple[str, ...]:
    return tuple(t for t in normalize(text).split() if t not in _STOPWORDS)



@dataclass(frozen=True)
class Candidate:
    card_id: str
    q: float
    rank_score: float
    matched_language: str

    # Compatibility aliases used by callers that describe retrieval quality.
    @property
    def score(self) -> float:
        return self.q


@dataclass(frozen=True)
class _Doc:
    card: BundleCard
    utterances: tuple[tuple[str, tuple[str, ...]], ...]
    pooled: frozenset[str]


def _cards(value: CardBundle | Mapping[str, BundleCard] | Iterable[BundleCard]) -> list[BundleCard]:
    if isinstance(value, CardBundle):
        return list(value.cards.values())
    if isinstance(value, Mapping):
        return list(value.values())
    return list(value)


class IntentIndex:
    """An immutable index over the three-language card utterance pool."""

    MIN_Q = 0.20

    def __init__(self, cards: Iterable[BundleCard]):
        self._docs = []
        for card in cards:
            utterances = tuple(
                (language, _tokens(text))
                for language, texts in (("es", card.utterances.es), ("en", card.utterances.en), ("ht", card.utterances.ht))
                for text in texts
                if _tokens(text)
            )
            pooled = frozenset(token for _, words in utterances for token in words)
            self._docs.append(_Doc(card, utterances, pooled))

    def __len__(self) -> int:
        return len(self._docs)

    @staticmethod
    def _quality(query: tuple[str, ...], pooled: frozenset[str]) -> float:
        if not query or not pooled:
            return 0.0
        matched = sum(token in pooled for token in set(query))
        # Query coverage is deliberately dominant: pooled utterances contain
        # several languages, so a code-switched query should not be penalized
        # for words in the other two language columns.
        coverage = matched / len(set(query))
        density = matched / min(len(set(query)), len(pooled))
        return round(0.8 * coverage + 0.2 * density, 4)

    def search(
        self,
        normalized_query: str,
        *,
        stage: int | None = None,
        mode: Mode | str | None = None,
        allowed: set[str] | None = None,
        exclude: set[str] | frozenset[str] = frozenset(),
        k: int = 8,
        immigration_topics: frozenset[str] | None = None,
    ) -> list[Candidate]:
        query = _tokens(normalized_query)
        if not query:
            return []
        mode_value = mode.value if isinstance(mode, Mode) else mode
        scored: list[Candidate] = []
        for doc in self._docs:
            card = doc.card
            if card.id in exclude or (allowed is not None and card.id not in allowed):
                continue
            if stage is not None and stage not in card.stages:
                continue
            if mode_value is not None and mode_value not in card.modes:
                continue
            if mode_value == Mode.tourist.value and is_immigration_card(card, immigration_topics):
                continue
            q = self._quality(query, doc.pooled)
            if q < self.MIN_Q:
                continue
            # Stable tie-breaker only; q remains the reported confidence basis.
            overlap = sum(token in doc.pooled for token in set(query))
            lang = "title"
            if doc.utterances:
                lang = max(doc.utterances, key=lambda item: sum(t in item[1] for t in set(query)))[0]
            scored.append(Candidate(card.id, q, round(q + overlap / 10000, 4), lang))
        scored.sort(key=lambda c: (-c.rank_score, -c.q, c.card_id))
        return scored[: max(0, k)]


def retrieve(
    utterance: str,
    cards: CardBundle | Mapping[str, BundleCard] | Iterable[BundleCard],
    *,
    stage: int | None = None,
    mode: Mode | str | None = None,
    k: int = 8,
    immigration_topics: frozenset[str] | None = None,
) -> list[Candidate]:
    """Normalize and retrieve eligible card candidates without I/O or models."""
    return IntentIndex(_cards(cards)).search(normalize(utterance), stage=stage, mode=mode, k=k, immigration_topics=immigration_topics)

