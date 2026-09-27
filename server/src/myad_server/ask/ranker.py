"""Ranking boundary for /ask.

The model ranker is optional.  Offline and keyless execution always uses the
same deterministic implementation.
"""
from __future__ import annotations

import os
from collections.abc import Sequence
from typing import Protocol

from .retrieval import Candidate


class Ranker(Protocol):
    def rank(self, candidates: Sequence[Candidate], utterance: str | None = None) -> Candidate | None:
        """Choose one already-retrieved candidate, or return no choice."""


class StubRanker:
    """Deterministically select the retrieval winner."""

    def rank(self, candidates: Sequence[Candidate], utterance: str | None = None) -> Candidate | None:
        return candidates[0] if candidates else None


def select_ranker(*, offline: bool = False) -> Ranker:
    """Select Gemini only when online, keyed, and optional ADK are available."""
    if offline or not os.environ.get("GEMINI_API_KEY"):
        return StubRanker()
    try:
        # The import is deliberately lazy so the base install stays offline-safe.
        import google.adk  # noqa: F401
        from .gemini_ranker import GeminiRanker

        return GeminiRanker()
    except Exception:  # noqa: BLE001 - optional live path must never break /ask
        return StubRanker()
