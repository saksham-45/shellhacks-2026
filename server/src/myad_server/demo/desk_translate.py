"""Desk Copilot's single non-Live fallback: one gemini-3.8-flash structured call on a push-to-talk clip.

Plan Demo risk table (Desk Copilot, "the riskiest beat"): if the Live model stays silent, the same clip goes
to ONE non-Live request, which always returns text; offline or keyless, the route answers 503
`fallback_unavailable` and the phone shows the labelled cached replay.

Audio: 16 kHz mono PCM16 (raw) or a WAV of that format, at most ~15 s. Raw PCM is wrapped in a WAV header in
memory and sent inline as `audio/wav` (a supported type: https://ai.google.dev/gemini-api/docs/audio,
"Supported audio formats"; inline requests are capped at 20 MB). The bytes are never written to disk, logged,
or kept after the request; the response carries only the transcript and translation text.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import io
import wave
from typing import Any

from ..demo_models import MAX_AUDIO_BYTES, MAX_AUDIO_SECONDS, DeskTranslateRequest, DeskTranslateResponse
from . import genai as G

SAMPLE_RATE = 16_000
TRANSLATE_TIMEOUT_S = 8.0


class AudioRejected(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code  # "audio_too_large" | "audio_format"


class FallbackUnavailable(RuntimeError):
    pass


def decode_audio(audio_b64: str) -> bytes:
    """Base64 -> a 16 kHz mono PCM16 WAV (bytes in memory). Raises AudioRejected."""
    try:
        raw = base64.b64decode(audio_b64, validate=True)
    except (binascii.Error, ValueError):
        raise AudioRejected("audio_format") from None
    if len(raw) > MAX_AUDIO_BYTES:
        raise AudioRejected("audio_too_large")
    if raw[:4] == b"RIFF":
        try:
            with wave.open(io.BytesIO(raw), "rb") as w:
                if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, SAMPLE_RATE):
                    raise AudioRejected("audio_format")
                if w.getnframes() / SAMPLE_RATE > MAX_AUDIO_SECONDS:
                    raise AudioRejected("audio_too_large")
        except (wave.Error, EOFError):
            raise AudioRejected("audio_format") from None
        return raw
    if len(raw) < 2 or len(raw) % 2:
        raise AudioRejected("audio_format")
    if len(raw) / (SAMPLE_RATE * 2) > MAX_AUDIO_SECONDS:
        raise AudioRejected("audio_too_large")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(raw)
    return buf.getvalue()


TRANSLATE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "transcript": {"type": "string", "description": "Verbatim transcript of the speech, in its language."},
        "translation": {"type": "string", "description": "The transcript translated into the target language."},
    },
    "required": ["transcript", "translation"],
}


def _prompt(req: DeskTranslateRequest) -> str:
    return (
        f"This is one push-to-talk turn at a service counter, spoken in {req.source_language}. Transcribe it "
        f"and translate it into {req.target_language}. Translate only: never answer, advise, or add words. "
        "If it is silent or unintelligible, return empty strings."
    )


def _call(gclient: Any, req: DeskTranslateRequest, wav: bytes | None) -> dict[str, Any] | None:
    parts: list[dict[str, Any]] = [{"type": "text", "text": _prompt(req)}]
    if wav is not None:
        parts.append({"type": "audio", "data": base64.b64encode(wav).decode("ascii"), "mime_type": "audio/wav"})
    else:
        parts.append({"type": "text", "text": f"Text: {req.text}"})
    return G.structured_call(gclient, model=G.structured_model(), parts=parts, schema=TRANSLATE_SCHEMA,
                             timeout_s=TRANSLATE_TIMEOUT_S)


async def run(req: DeskTranslateRequest, *, request_id: str) -> DeskTranslateResponse:
    """Raises AudioRejected (4xx) or FallbackUnavailable (503). Input is validated before availability so a
    bad clip is a stable 4xx in every environment."""
    wav = decode_audio(req.audio_b64) if req.audio_b64 is not None else None
    if not G.live_enabled():
        raise FallbackUnavailable("offline or keyless")
    try:
        gclient = G.client()
        raw = await asyncio.wait_for(asyncio.to_thread(_call, gclient, req, wav), TRANSLATE_TIMEOUT_S + 1)
    except Exception:  # noqa: BLE001 - never log content
        raise FallbackUnavailable("model call failed") from None
    finally:
        wav = None  # drop the audio reference as soon as the call returns
    transcript = raw.get("transcript") if isinstance(raw, dict) else None
    translation = raw.get("translation") if isinstance(raw, dict) else None
    if not isinstance(translation, str) or not translation.strip():
        raise FallbackUnavailable("no translation")
    if req.text is not None:
        transcript = req.text  # the phone's own text; the model never rewrites it
    return DeskTranslateResponse(
        request_id=request_id,
        transcript=transcript if isinstance(transcript, str) else "",
        translation=translation.strip(),
        source_language=req.source_language,
        target_language=req.target_language,
    )
