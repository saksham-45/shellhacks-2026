"""Live answer with one-shot multimodal and TTS fallback."""
from __future__ import annotations

import asyncio
import base64
import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from google.genai import types

try:
    from .live_ptt import DEFAULT_TIMEOUT_S, LIVE_MODELS, LiveTurn, PendingKeyError, build_client, run_push_to_talk
except ImportError:  # script execution
    from live_ptt import DEFAULT_TIMEOUT_S, LIVE_MODELS, LiveTurn, PendingKeyError, build_client, run_push_to_talk

DEFAULT_FALLBACK_MODEL = "gemini-3.8-flash"
DEFAULT_TTS_MODEL = "gemini-3.8-flash-tts"
FALLBACK_MODEL_DOC_URL = "https://ai.google.dev/gemini-api/docs/models"
TTS_MODEL_DOC_URL = "https://ai.google.dev/gemini-api/docs/speech-generation"


@dataclass
class TurnResult:
    transcript_in: Optional[str]
    text_out: Optional[str]
    audio_out: Optional[bytes]
    path: str
    latencies: dict[str, Optional[float] | str] = field(default_factory=dict)

    def public(self) -> dict[str, Any]:
        """A report-safe projection; content and audio are intentionally omitted."""
        return {
            "path": self.path,
            "transcript_in_arrived": self.transcript_in is not None,
            "text_out_arrived": self.text_out is not None,
            "audio_out": self.audio_out is not None,
            "audio_bytes": len(self.audio_out) if self.audio_out is not None else 0,
            "latencies": dict(self.latencies),
        }


def fallback_model_id() -> str:
    return os.environ.get("MYAD_FALLBACK_MODEL") or DEFAULT_FALLBACK_MODEL


def _value(obj: Any, name: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


async def _maybe_await(value: Any) -> Any:
    if hasattr(value, "__await__"):
        return await value
    return value


def _response_text(response: Any) -> str:
    text = _value(response, "text", "")
    if isinstance(text, str):
        return text
    return ""


def _parse_answer(raw: str) -> tuple[Optional[str], Optional[str]]:
    """Parse the requested JSON envelope without ever logging its contents."""
    candidate = raw.strip()
    if candidate.startswith("```"):
        candidate = candidate.split("\n", 1)[1] if "\n" in candidate else candidate
        if candidate.endswith("```"):
            candidate = candidate[:-3].rstrip()
    try:
        data = json.loads(candidate)
    except (TypeError, ValueError, json.JSONDecodeError):
        return None, raw or None
    if not isinstance(data, dict):
        return None, raw or None
    transcript = data.get("transcript_in")
    text = data.get("text_out")
    return (
        transcript if isinstance(transcript, str) else None,
        text if isinstance(text, str) and text else raw or None,
    )


def _audio_from_tts(response: Any) -> Optional[bytes]:
    output = _value(response, "output_audio")
    data = _value(output, "data")
    if data is None:
        return None
    if isinstance(data, bytes):
        return data
    if isinstance(data, bytearray):
        return bytes(data)
    if isinstance(data, str):
        try:
            return base64.b64decode(data)
        except (ValueError, base64.binascii.Error):
            return None
    return None


async def _generate_fallback(client: Any, clip: bytes, model: str) -> tuple[Optional[str], Optional[str]]:
    prompt = (
        "Transcribe the attached 16 kHz mono PCM user utterance and write a short helpful reply. "
        "Return only JSON with string keys transcript_in and text_out."
    )
    contents = [types.Part.from_bytes(data=clip, mime_type="audio/pcm;rate=16000"), prompt]
    resource = getattr(getattr(client, "aio", None), "models", None) or client.models
    response = await _maybe_await(resource.generate_content(model=model, contents=contents))
    return _parse_answer(_response_text(response))


async def _speak(client: Any, text: str, model: str) -> Optional[bytes]:
    resource = getattr(getattr(client, "aio", None), "interactions", None) or client.interactions
    response = await _maybe_await(
        resource.create(
            model=model,
            input=[{
                "type": "user_input",
                "content": [{"type": "text", "text": text}],
            }],
            response_format={"type": "audio"},
            generation_config={"speech_config": [{"voice": "Kore"}]},
        )
    )
    return _audio_from_tts(response)


async def answer_turn(
    clip: bytes,
    client: Any = None,
    live_model: str = LIVE_MODELS[0],
    timeout_s: float = DEFAULT_TIMEOUT_S,
    fallback_model: Optional[str] = None,
    tts_model: str = DEFAULT_TTS_MODEL,
) -> TurnResult:
    """Return live output or a text-first fallback turn.

    The result retains content for an interactive caller. Call ``public()``
    before writing metrics or logs.
    """
    started = time.monotonic()
    if client is None:
        try:
            client = build_client()
        except PendingKeyError:
            return TurnResult(None, None, None, "text_only", {"status": "pending key"})

    live = await run_push_to_talk(client, live_model, clip, timeout_s)
    live_ms = (time.monotonic() - started) * 1000.0
    if live.answered:
        return TurnResult(
            transcript_in=live.input_transcript,
            text_out=live.output_text or live.output_transcript,
            audio_out=live.audio_bytes or None,
            path="live",
            latencies={
                "live_first_audio_ms": live.first_audio_ms,
                "live_first_transcript_ms": live.first_transcript_ms,
                "live_total_ms": live_ms,
            },
        )

    fallback_started = time.monotonic()
    try:
        transcript, text = await _generate_fallback(client, clip, fallback_model or fallback_model_id())
    except Exception:
        return TurnResult(
            None,
            None,
            None,
            "text_only",
            {"live_timeout_ms": live_ms, "fallback_ms": None, "status": "fallback error"},
        )
    fallback_ms = (time.monotonic() - fallback_started) * 1000.0
    if not text:
        return TurnResult(
            transcript,
            None,
            None,
            "text_only",
            {"live_timeout_ms": live_ms, "fallback_ms": fallback_ms, "tts_ms": None},
        )

    tts_started = time.monotonic()
    audio: Optional[bytes] = None
    try:
        audio = await _speak(client, text, tts_model)
    except Exception:
        # Text remains the user-visible answer if speech generation fails.
        audio = None
    tts_ms = (time.monotonic() - tts_started) * 1000.0
    return TurnResult(
        transcript,
        text,
        audio,
        "fallback" if audio else "text_only",
        {
            "live_timeout_ms": live_ms,
            "fallback_ms": fallback_ms,
            "tts_ms": tts_ms,
            "total_ms": (time.monotonic() - started) * 1000.0,
        },
    )
