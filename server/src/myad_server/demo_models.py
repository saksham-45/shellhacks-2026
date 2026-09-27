"""/v1 wire models for the demo endpoints (FM-MYAD-DEMO-DESK; owner: myAD Agents). Golden files live in
contracts/v1/demo/{fee_check,handoff_sheet,desk_translate,live_token,demo_error}.*.json and are decoded by
tests/test_contracts.py. Re-exported from models.py.

Privacy: request text, OCR text, utterances and audio are request-only. They are never logged or stored, and
no response echoes them except where the phone needs its own words back (the handoff sheet and the
transcript of its own clip).
"""
from __future__ import annotations

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from .models import Envelope, Id, RequestId
from .values import LanguageTag, Mode, Strict, SurfaceLanguage, _check_bcp47

RegionId = Annotated[str, Field(pattern=r"^[a-z]{2}(-[a-z0-9]+)*$", max_length=64)]

# ---- /v1/fee-check ------------------------------------------------------------------------------------------

PayeeType = Literal["government", "private", "unknown"]
PayMethod = Literal["cash", "card", "check", "money_order", "unknown"]
FeeOutcome = Literal[
    "official_fee",        # a verified ledger money fact answers
    "official_rule",       # a verified ledger rule (text) answers, e.g. taxi meter rules, FTC gift cards
    "immigration_lines",   # only the USCIS lines present in the ledger, then the accredited-help desk
    "private_no_verdict",  # a private price: never called fair or unfair, only the desk
    "no_official_fee",     # no admitted ledger fact: desk only
    "not_shown_tourist",   # immigration content hidden in tourist mode: desk only
]


class FeeCheckRequest(Strict):
    """What a person typed or said about a charge, and/or text read on the device from a receipt."""

    request_id: RequestId | None = None
    region: RegionId
    language: SurfaceLanguage
    mode: Mode = Mode.resident
    text: str | None = Field(default=None, min_length=1, max_length=2000)
    ocr_text: str | None = Field(default=None, min_length=1, max_length=4000)

    @model_validator(mode="after")
    def _some_text(self) -> "FeeCheckRequest":
        if not (self.text or self.ocr_text):
            raise ValueError("text or ocr_text is required")
        return self


class FeeAsk(Strict):
    """The extracted ask. amount_cents is kept only if that amount literally appears in the request text."""

    payee_type: PayeeType
    purpose_key: str = Field(min_length=1, max_length=200)
    amount_cents: int | None = Field(default=None, ge=0, le=100_000_000)
    method: PayMethod


class FeeAnswerLine(Strict):
    """One sentence in the request language. Every ledger value in `text` is one of `fact_ids`, and each of
    those ids is an admitted `fact` outcome in the response's `facts` map."""

    text: str = Field(min_length=1)
    fact_ids: list[Id] = Field(default_factory=list)
    source_id: Id | None = None
    source_name: str | None = None
    url: str | None = None


class FeeCheckResponse(Envelope):
    region: RegionId
    mode: Mode
    extractor: Literal["rule", "gemini"]
    ask: FeeAsk
    outcome: FeeOutcome
    lines: list[FeeAnswerLine] = Field(min_length=1, max_length=4)
    desk_id: Id | None = None


# ---- /v1/handoff-sheet --------------------------------------------------------------------------------------

HandoffDropReason = Literal[
    "bad_index",            # cites an utterance that does not exist
    "unsupported",          # does not map to its cited utterance
    "unsaid_legal_word",    # a legal/status word the person did not say
    "unticked_status_word", # a status word the person did not tick
    "empty",
]


class HandoffSheetRequest(Strict):
    request_id: RequestId | None = None
    person_id: Id
    language: LanguageTag  # the person's language; the sheet itself is always English
    mode: Mode = Mode.resident
    utterances: list[Annotated[str, Field(min_length=1, max_length=1000)]] = Field(min_length=1, max_length=20)
    ticked_status_words: list[Annotated[str, Field(min_length=1, max_length=40)]] = Field(
        default_factory=list, max_length=10)
    desk_id: Id

    @field_validator("language")
    @classmethod
    def _lang(cls, v: str) -> str:
        return _check_bcp47(v)


class HandoffSentence(Strict):
    text: str = Field(min_length=1, max_length=600)
    source_utterance_index: int = Field(ge=0)
    # True when the person spoke another language and no verified translation exists (offline): the text is
    # their own words, untranslated, and the desk must get it translated. Never an invented translation.
    needs_translation: bool = False


class HandoffReadBack(Strict):
    text: str = Field(min_length=1, max_length=600)
    source_utterance_index: int = Field(ge=0)


class HandoffDrop(Strict):
    reason: HandoffDropReason
    source_utterance_index: int | None = None


class HandoffSheetResponse(Strict):
    request_id: RequestId
    person_id: Id
    desk_id: Id
    language: Literal["en"] = "en"
    read_back_language: LanguageTag
    summarizer: Literal["gemini", "extractive"]
    sentences: list[HandoffSentence] = Field(max_length=20)
    read_back: list[HandoffReadBack] = Field(max_length=20)
    approved: Literal[False] = False  # the person approves on the phone; the server never does
    dropped: list[HandoffDrop] = Field(default_factory=list)

    @model_validator(mode="after")
    def _aligned(self) -> "HandoffSheetResponse":
        if [s.source_utterance_index for s in self.sentences] != [r.source_utterance_index for r in self.read_back]:
            raise ValueError("read_back must mirror sentences one to one")
        return self


# ---- /v1/desk/translate -------------------------------------------------------------------------------------

# 15 s of 16 kHz mono PCM16 is 480,000 bytes; +0.5 s slack and a WAV header. Base64 is 4/3 larger.
MAX_AUDIO_SECONDS = 15.5
MAX_AUDIO_BYTES = int(16_000 * 2 * MAX_AUDIO_SECONDS) + 44
MAX_AUDIO_B64_CHARS = (MAX_AUDIO_BYTES + 2) // 3 * 4


class DeskTranslateRequest(Strict):
    request_id: RequestId | None = None
    audio_b64: str | None = Field(default=None, min_length=4, max_length=MAX_AUDIO_B64_CHARS)
    text: str | None = Field(default=None, min_length=1, max_length=2000)
    source_language: LanguageTag
    target_language: LanguageTag

    @field_validator("source_language", "target_language")
    @classmethod
    def _lang(cls, v: str) -> str:
        return _check_bcp47(v)

    @model_validator(mode="after")
    def _one_input(self) -> "DeskTranslateRequest":
        if (self.audio_b64 is None) == (self.text is None):
            raise ValueError("send exactly one of audio_b64 or text")
        return self


class DeskTranslateResponse(Strict):
    request_id: RequestId
    transcript: str
    translation: str
    mode: Literal["fallback"] = "fallback"
    source_language: LanguageTag
    target_language: LanguageTag


# ---- /v1/live/token -----------------------------------------------------------------------------------------


class LiveTokenRequest(Strict):
    request_id: RequestId | None = None
    source_language: LanguageTag | None = None
    target_language: LanguageTag | None = None

    @field_validator("source_language", "target_language")
    @classmethod
    def _lang(cls, v: str | None) -> str | None:
        return None if v is None else _check_bcp47(v)


class LiveConstraints(Strict):
    """What the token locks (the phone cannot change it): model, audio out, push-to-talk only, transcripts."""

    model: str
    response_modalities: list[Literal["AUDIO"]] = Field(default_factory=lambda: ["AUDIO"])
    automatic_activity_detection_disabled: Literal[True] = True
    input_audio_transcription: Literal[True] = True
    output_audio_transcription: Literal[True] = True


class LiveTokenResponse(Strict):
    request_id: RequestId
    token: str = Field(min_length=1)  # AuthToken.name: use it as the API key for one Live session
    api_version: Literal["v1alpha"] = "v1alpha"
    uses: Literal[1] = 1
    expire_time: str
    new_session_expire_time: str
    constraints: LiveConstraints


# ---- stable error body (503 / 413 / 422 from the demo routes) -------------------------------------------------

DemoErrorCode = Literal["fallback_unavailable", "live_unavailable", "audio_too_large", "audio_format",
                        "invalid_request"]


class DemoErrorBody(Strict):
    """`fallback_unavailable` / `live_unavailable` (503): show the labelled cached replay. Never echoes input."""

    error: DemoErrorCode
    request_id: RequestId | None = None
