"""Fee Check extractors: text -> FeeAsk {payee_type, purpose_key, amount_cents, method}.

The extractor is an interface. `RuleFeeExtractor` (regex amounts, en/es/ht keyword tables) is the offline
default and the fallback for every live failure; `GeminiFeeExtractor` makes ONE structured-output call.
Neither ever produces an answer: the deterministic matcher in fee_check.py compares the ask with ledger facts
only. Whatever an extractor returns is re-validated here:
- purpose_key must be one of this request's enum values (else "unknown");
- amount_cents survives only if that amount literally appears in the request text (a model cannot inject a
  number the person never said);
- payee_type / method must be in their enums (pydantic).
"""
from __future__ import annotations

import asyncio
import re
from decimal import Decimal, InvalidOperation
from typing import Any, Protocol, Sequence

from ..demo_models import FeeAsk
from . import genai as G
from .fee_vocab import FeeVocab, load_vocab
from .text import normalize, strip_accents

EXTRACT_TIMEOUT_S = 4.0
PRIVATE_SERVICE = "private_service"
UNKNOWN = "unknown"

_NUM = r"(\d{1,3}(?:,\d{3})+|\d+)(?:[.,](\d{2}))?"
_AMOUNT_PATTERNS = (
    re.compile(r"(?:us\s?)?\$\s?" + _NUM + r"\b"),
    re.compile(r"\b" + _NUM + r"\s?(?:\$|usd\b|dollars?\b|dolares\b|dolar\b|dola\b|bucks\b)"),
)


def amounts_in(text: str) -> list[int]:
    """Every dollar amount written in the text, in cents, in order of appearance (deduplicated)."""
    t = strip_accents(text).casefold()
    found: list[tuple[int, int]] = []
    for rx in _AMOUNT_PATTERNS:
        for m in rx.finditer(t):
            try:
                whole = Decimal(m.group(1).replace(",", ""))
            except InvalidOperation:
                continue
            cents = int(whole * 100) + (int(m.group(2)) if m.group(2) else 0)
            found.append((m.start(), cents))
    out: list[int] = []
    for _, cents in sorted(found):
        if cents not in out:
            out.append(cents)
    return out


def _combined(text: str | None, ocr_text: str | None) -> str:
    return "\n".join(t for t in (text, ocr_text) if t)


class FeeExtractor(Protocol):
    name: str

    async def extract(self, text: str, purposes: Sequence[str]) -> FeeAsk: ...


class RuleFeeExtractor:
    """Deterministic, offline. The first matching purpose rule that the region offers wins."""

    name = "rule"

    def __init__(self, vocab: FeeVocab | None = None):
        self.vocab = vocab or load_vocab()

    def extract_sync(self, text: str, purposes: Sequence[str]) -> FeeAsk:
        norm = normalize(text)
        offered = set(purposes)
        purpose = UNKNOWN
        for rule in self.vocab.purposes:
            if rule.key in offered and rule.matches(norm):
                purpose = rule.key
                break
        payee = "unknown"
        if self.vocab.payee["private"].search(norm):
            payee = "private"
        elif self.vocab.payee["government"].search(norm):
            payee = "government"
        method = "unknown"
        for name, rx in self.vocab.method:
            if rx.search(norm):
                method = name
                break
        amounts = amounts_in(text)
        return FeeAsk(payee_type=payee, purpose_key=purpose, amount_cents=amounts[0] if amounts else None,
                      method=method)

    async def extract(self, text: str, purposes: Sequence[str]) -> FeeAsk:
        return self.extract_sync(text, purposes)


def fee_schema(purposes: Sequence[str]) -> dict[str, Any]:
    """JSON Schema subset documented at https://ai.google.dev/gemini-api/docs/structured-output: string
    enums, integer with minimum, and null via a type array."""
    return {
        "type": "object",
        "properties": {
            "payee_type": {"type": "string", "enum": ["government", "private", "unknown"],
                           "description": "Who is asking for the money."},
            "purpose_key": {"type": "string", "enum": list(dict.fromkeys([*purposes, PRIVATE_SERVICE, UNKNOWN])),
                            "description": "What the payment is for; unknown if none fits."},
            "amount_cents": {"type": ["integer", "null"], "minimum": 0,
                             "description": "The amount the person was asked to pay, in cents, only if they "
                                            "said a number; otherwise null. Never compute or guess."},
            "method": {"type": "string", "enum": ["cash", "card", "check", "money_order", "unknown"]},
        },
        "required": ["payee_type", "purpose_key", "amount_cents", "method"],
    }


class GeminiFeeExtractor:
    """One structured-output call (gemini-3.8-flash by default). Any failure -> the rule extractor."""

    name = "gemini"

    def __init__(self, gclient: Any, *, model: str | None = None, fallback: RuleFeeExtractor | None = None,
                 timeout_s: float = EXTRACT_TIMEOUT_S):
        self._client = gclient
        self.model = model or G.structured_model()
        self.fallback = fallback or RuleFeeExtractor()
        self.timeout_s = timeout_s
        self.used_fallback = False

    def _call(self, text: str, purposes: Sequence[str]) -> dict[str, Any] | None:
        prompt = (
            "Extract the payment ask from the person's words below. Return only the schema fields. "
            "purpose_key must be one enum value; use private_service for a private service with no "
            "government fee, unknown if nothing fits. amount_cents is only a number the person said.\n"
            f"Words: {text}"
        )
        return G.structured_call(self._client, model=self.model, parts=[{"type": "text", "text": prompt}],
                                 schema=fee_schema(purposes), timeout_s=self.timeout_s)

    async def extract(self, text: str, purposes: Sequence[str]) -> FeeAsk:
        try:
            raw = await asyncio.wait_for(asyncio.to_thread(self._call, text, purposes), self.timeout_s + 1)
            if raw is None:
                raise ValueError("no structured output")
            return FeeAsk.model_validate({k: raw.get(k) for k in ("payee_type", "purpose_key", "amount_cents",
                                                                  "method")})
        except Exception:  # noqa: BLE001 - never log model content; degrade to the deterministic path
            self.used_fallback = True
            return await self.fallback.extract(text, purposes)


def sanitize(ask: FeeAsk, text: str, purposes: Sequence[str]) -> tuple[FeeAsk, int]:
    """Re-validate an extractor's output against the request. Returns (ask, number of fields dropped)."""
    dropped = 0
    offered = set(purposes) | {PRIVATE_SERVICE, UNKNOWN}
    purpose = ask.purpose_key
    if purpose not in offered:
        purpose, dropped = UNKNOWN, dropped + 1
    amount = ask.amount_cents
    if amount is not None and amount not in amounts_in(text):
        amount, dropped = None, dropped + 1
    return FeeAsk(payee_type=ask.payee_type, purpose_key=purpose, amount_cents=amount, method=ask.method), dropped


def select_extractor() -> FeeExtractor:
    """Gemini only when not offline and a key exists; the rule extractor otherwise (no client is built)."""
    if not G.live_enabled():
        return RuleFeeExtractor()
    try:
        return GeminiFeeExtractor(G.client())
    except Exception:  # noqa: BLE001 - SDK missing or client error: offline path
        return RuleFeeExtractor()


combined_text = _combined
