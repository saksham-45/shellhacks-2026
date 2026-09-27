"""Warm Handoff Sheet: the person's own words -> a one-page ENGLISH sheet, verified sentence by sentence.

Plan "## 4. Warm Handoff Sheet" rules: summarization of the person's own words only; no legal analysis; a
status word only if the person said it AND ticked "include"; stays on the phone (nothing is stored or logged
server-side: this module keeps no state, writes no file, and the app logs only counts).

Summarizers (interface):
- `ExtractiveHandoffSummarizer` (offline default): translation-free. English utterances are kept as-is; a
  non-English utterance is kept in the person's own words and marked `needs_translation` — never an invented
  translation.
- `GeminiHandoffSummarizer`: one structured-output call; each sentence cites an utterance index and carries a
  read-back in the person's language.

`verify_sheet` (the HANDOFF VERIFIER) then drops any sentence that:
- cites an utterance that does not exist (`bad_index`);
- does not map to its cited utterance (`unsupported`): content-token overlap, every number present; when the
  person spoke another language the read-back (same language as the utterance) is checked instead — the
  live translation check;
- uses a legal or status word (en/es/ht concepts, data/handoff_words.yaml) the person did not say in that
  utterance (`unsaid_legal_word`);
- uses a status word the person did not tick (`unticked_status_word`); in tourist mode no status word passes.
"""
from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any, Protocol, Sequence

import yaml

from ..demo_models import (HandoffDrop, HandoffReadBack, HandoffSentence, HandoffSheetRequest,
                           HandoffSheetResponse)
from ..values import Mode
from . import genai as G
from .text import compile_words, normalize

_PATH = Path(__file__).resolve().parents[1] / "data" / "handoff_words.yaml"
SUMMARY_TIMEOUT_S = 5.0
MIN_OVERLAP = 0.5
MAX_SENTENCES = 12
_NUMBER = re.compile(r"\d+")


@dataclass(frozen=True)
class Draft:
    """A proposed sheet line before verification."""

    text: str
    source_utterance_index: int
    read_back: str | None = None
    needs_translation: bool = False


@dataclass(frozen=True)
class Words:
    status: dict[str, re.Pattern[str]]
    legal: dict[str, re.Pattern[str]]
    stopwords: frozenset[str]

    def concepts(self, text: str, table: dict[str, re.Pattern[str]]) -> set[str]:
        norm = normalize(text)
        return {name for name, rx in table.items() if rx.search(norm)}

    def status_concepts(self, text: str) -> set[str]:
        return self.concepts(text, self.status)

    def legal_concepts(self, text: str) -> set[str]:
        return self.concepts(text, self.legal)


@lru_cache(maxsize=2)
def load_words(path: Path = _PATH) -> Words:
    data: Any = yaml.safe_load(path.read_text(encoding="utf-8"))
    stop = {normalize(w) for ws in (data.get("stopwords") or {}).values() for w in ws}
    return Words(
        status={k: compile_words(list(v)) for k, v in data["status"].items()},
        legal={k: compile_words(list(v)) for k, v in data["legal"].items()},
        stopwords=frozenset(stop),
    )


def _tokens(text: str, words: Words) -> set[str]:
    return {t for t in normalize(text).split() if len(t) >= 3 and t not in words.stopwords and not t.isdigit()}


def supported(candidate: str, utterance: str, words: Words) -> bool:
    """Every number in the candidate is in the utterance and >= half its content tokens are too."""
    if not set(_NUMBER.findall(candidate)) <= set(_NUMBER.findall(utterance)):
        return False
    cand = _tokens(candidate, words)
    if not cand:
        return bool(_NUMBER.findall(candidate)) or normalize(candidate) == normalize(utterance)
    return len(cand & _tokens(utterance, words)) / len(cand) >= MIN_OVERLAP


def _is_english(language: str) -> bool:
    return language.split("-")[0].casefold() == "en"


class HandoffSummarizer(Protocol):
    name: str

    async def summarize(self, utterances: Sequence[str], language: str) -> list[Draft]: ...


class ExtractiveHandoffSummarizer:
    name = "extractive"

    async def summarize(self, utterances: Sequence[str], language: str) -> list[Draft]:
        english = _is_english(language)
        return [Draft(text=u.strip(), source_utterance_index=i, read_back=u.strip(), needs_translation=not english)
                for i, u in enumerate(utterances) if u.strip()][:MAX_SENTENCES]


def handoff_schema(n_utterances: int) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "sentences": {
                "type": "array",
                "maxItems": MAX_SENTENCES,
                "items": {
                    "type": "object",
                    "properties": {
                        "text": {"type": "string", "description": "One short first-person English sentence."},
                        "read_back": {"type": "string",
                                      "description": "The same sentence in the person's language."},
                        "source_utterance_index": {"type": "integer", "minimum": 0,
                                                   "maximum": max(0, n_utterances - 1)},
                    },
                    "required": ["text", "read_back", "source_utterance_index"],
                },
            },
        },
        "required": ["sentences"],
    }


class GeminiHandoffSummarizer:
    """One structured-output call; any failure -> the extractive summarizer."""

    name = "gemini"

    def __init__(self, gclient: Any, *, model: str | None = None, timeout_s: float = SUMMARY_TIMEOUT_S):
        self._client = gclient
        self.model = model or G.structured_model()
        self.timeout_s = timeout_s
        self.used_fallback = False

    def _call(self, utterances: Sequence[str], language: str) -> dict[str, Any] | None:
        numbered = "\n".join(f"[{i}] {u}" for i, u in enumerate(utterances))
        prompt = (
            "Write a one-page English handoff sheet for a front desk, in the first person, using ONLY what the "
            "person said below. One short sentence per point: what happened, dates, papers they have, what "
            "they ask for, the language they need. Every sentence must cite the index of the utterance it "
            "comes from. Never add legal analysis, advice, or legal or immigration-status words the person "
            f"did not say. read_back is the same sentence in the person's language ({language}).\n{numbered}"
        )
        return G.structured_call(self._client, model=self.model, parts=[{"type": "text", "text": prompt}],
                                 schema=handoff_schema(len(utterances)), timeout_s=self.timeout_s)

    async def summarize(self, utterances: Sequence[str], language: str) -> list[Draft]:
        try:
            raw = await asyncio.wait_for(asyncio.to_thread(self._call, utterances, language), self.timeout_s + 1)
            items = raw.get("sentences") if isinstance(raw, dict) else None
            if not isinstance(items, list):
                raise ValueError("no structured output")
            out: list[Draft] = []
            for item in items[:MAX_SENTENCES]:
                if not isinstance(item, dict):
                    continue
                idx, text, rb = item.get("source_utterance_index"), item.get("text"), item.get("read_back")
                if isinstance(idx, int) and not isinstance(idx, bool) and isinstance(text, str):
                    out.append(Draft(text=text.strip(), source_utterance_index=idx,
                                     read_back=rb.strip() if isinstance(rb, str) else None))
            return out
        except Exception:  # noqa: BLE001 - never log content; degrade to the extractive sheet
            self.used_fallback = True
            return await ExtractiveHandoffSummarizer().summarize(utterances, language)


def _ticked(ticked: Sequence[str], words: Words) -> set[str]:
    return {c for w in ticked for c in words.status_concepts(w)}


def verify_sheet(drafts: Sequence[Draft], req: HandoffSheetRequest, words: Words | None = None
                 ) -> tuple[list[HandoffSentence], list[HandoffReadBack], list[HandoffDrop]]:
    words = words or load_words()
    english = _is_english(req.language)
    ticked = set() if req.mode == Mode.tourist else _ticked(req.ticked_status_words, words)
    sentences: list[HandoffSentence] = []
    read_back: list[HandoffReadBack] = []
    dropped: list[HandoffDrop] = []
    for d in drafts:
        idx = d.source_utterance_index
        if not (0 <= idx < len(req.utterances)):
            dropped.append(HandoffDrop(reason="bad_index"))
            continue
        utterance = req.utterances[idx]
        text = d.text.strip()
        rb = (d.read_back or "").strip()
        if not text:
            dropped.append(HandoffDrop(reason="empty", source_utterance_index=idx))
            continue
        if d.needs_translation:
            # Extractive, untranslated: the sentence IS the utterance.
            ok = normalize(text) == normalize(utterance)
            rb = text
        elif english:
            ok = supported(text, utterance, words)
            rb = text
        else:
            # Live translation check: the read-back (same language as the utterance) must map to it, and
            # the English sentence may not carry a number the person did not say.
            ok = bool(rb) and supported(rb, utterance, words) and \
                set(_NUMBER.findall(text)) <= set(_NUMBER.findall(utterance))
        if not ok:
            dropped.append(HandoffDrop(reason="unsupported", source_utterance_index=idx))
            continue
        said_status = words.status_concepts(utterance)
        said_legal = words.legal_concepts(utterance)
        used_status = words.status_concepts(text) | words.status_concepts(rb)
        used_legal = words.legal_concepts(text) | words.legal_concepts(rb)
        if (used_legal - said_legal) or (used_status - said_status):
            dropped.append(HandoffDrop(reason="unsaid_legal_word", source_utterance_index=idx))
            continue
        if used_status - ticked:
            dropped.append(HandoffDrop(reason="unticked_status_word", source_utterance_index=idx))
            continue
        sentences.append(HandoffSentence(text=text[:600], source_utterance_index=idx,
                                         needs_translation=d.needs_translation))
        read_back.append(HandoffReadBack(text=rb[:600], source_utterance_index=idx))
    return sentences, read_back, dropped


def select_summarizer() -> HandoffSummarizer:
    if not G.live_enabled():
        return ExtractiveHandoffSummarizer()
    try:
        return GeminiHandoffSummarizer(G.client())
    except Exception:  # noqa: BLE001
        return ExtractiveHandoffSummarizer()


async def run(req: HandoffSheetRequest, *, request_id: str, summarizer: HandoffSummarizer) -> HandoffSheetResponse:
    drafts = await summarizer.summarize(req.utterances, req.language)
    sentences, read_back, dropped = verify_sheet(drafts, req)
    name = "gemini" if summarizer.name == "gemini" and not getattr(summarizer, "used_fallback", False) \
        else "extractive"
    return HandoffSheetResponse(
        request_id=request_id,
        person_id=req.person_id,
        desk_id=req.desk_id,
        read_back_language=req.language,
        summarizer=name,
        sentences=sentences,
        read_back=read_back,
        dropped=dropped,
    )
