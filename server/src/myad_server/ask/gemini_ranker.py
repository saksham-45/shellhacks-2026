"""Optional Gemini-backed candidate ranker.

The model is allowed to select an already-retrieved card id or ``none``.  It
never supplies user-facing prose, and every failure returns the deterministic
stub result.
"""
from __future__ import annotations

import json
import os
from collections.abc import Sequence
from typing import Any

from .retrieval import Candidate
from .ranker import StubRanker

DEFAULT_MODEL = "gemini-3.5-flash-lite"
RANK_TIMEOUT_MS = 4_000


class GeminiRanker:
    """Rank candidates with one constrained Gemini API call.

    ADK's agent runner is useful for multi-step agent execution, but this
    boundary needs one synchronous structured call.  It therefore uses the
    google-genai ``response_schema`` directly while importing both optional
    Google packages lazily here.  ``google-adk`` remains the capability gate
    selected by :func:`select_ranker`.
    """

    def __init__(self, *, model: str | None = None, client: Any | None = None):
        # Checked 2026-09-25 against https://ai.google.dev/gemini-api/docs/models:
        # Gemini 3.5 Flash-Lite is listed there with endpoint
        # ``gemini-3.5-flash-lite``.
        self.model = model or os.environ.get("MYAD_RANKER_MODEL") or DEFAULT_MODEL
        self._fallback = StubRanker()
        self._api_key = os.environ.get("GEMINI_API_KEY")

        # Keep all optional imports inside the optional implementation.  The
        # base server and offline CI do not need either Google package.
        from google import adk as _adk  # noqa: F401  # capability/import check
        from google import genai

        self._genai = genai
        self._client = client or genai.Client(
            api_key=self._api_key,
            http_options={"timeout": RANK_TIMEOUT_MS},
        )

    @staticmethod
    def _schema(candidate_ids: Sequence[str]) -> dict[str, Any]:
        """Return the per-request enum schema, with no values outside it."""
        values = list(dict.fromkeys(candidate_ids))
        values.append("none")
        return {"type": "STRING", "enum": values}

    @staticmethod
    def _response_id(response: Any) -> str | None:
        text = getattr(response, "text", None)
        if not isinstance(text, str):
            return None
        value = text.strip()
        if not value:
            return None
        # JSON structured output commonly serializes a string as a JSON string;
        # accept that representation as well as a test/client plain string.
        try:
            decoded = json.loads(value)
        except (TypeError, ValueError):
            decoded = value
        return decoded if isinstance(decoded, str) else None

    def rank(self, candidates: Sequence[Candidate], utterance: str | None = None) -> Candidate | None:
        """Choose one candidate, or ``None`` when the model selects ``none``."""
        if not candidates or not self._api_key or not isinstance(utterance, str):
            return self._fallback.rank(candidates)

        candidate_ids = list(dict.fromkeys(candidate.card_id for candidate in candidates))
        schema = self._schema(candidate_ids)
        prompt = (
            "Select the best matching candidate card id for this user utterance. "
            "Return exactly one enum value and never explain. Return none when "
            "no candidate matches.\n"
            f"User utterance: {utterance}\n"
            f"Candidate ids: {', '.join(candidate_ids)}"
        )
        try:
            response = self._client.models.generate_content(
                model=self.model,
                contents=prompt,
                config={
                    "response_mime_type": "application/json",
                    "response_schema": schema,
                },
            )
            answer = self._response_id(response)
        except Exception:  # noqa: BLE001 - model failures use the safe local path
            return self._fallback.rank(candidates)

        if answer == "none":
            return None
        if answer not in candidate_ids:
            return self._fallback.rank(candidates)
        return next(candidate for candidate in candidates if candidate.card_id == answer)
