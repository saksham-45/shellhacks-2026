"""Offline-friendly push-to-talk client for the Gemini Live API.

The module deliberately exposes only boolean/count/latency projections for
measurements. Transcript and audio bytes are kept in returned objects for the
interactive caller, but are never logged or serialized by this module.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import time
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Optional

from google import genai
from google.genai import types

LIVE_MODELS = (
    "gemini-3.8-live",
    "gemini-3.8-live-extended-thinking",
    "gemini-3.1-flash-live-preview",
)
DEFAULT_TIMEOUT_S = 6.0
SAMPLE_RATE = 16_000
CHUNK_MS = 100


class PendingKeyError(RuntimeError):
    """Raised without exposing or loading a key from anywhere but the env."""


@dataclass
class LiveTurn:
    answered_audio: bool = False
    answered_text: bool = False
    first_audio_ms: Optional[float] = None
    first_transcript_ms: Optional[float] = None
    input_transcription_arrived: bool = False
    output_transcription_arrived: bool = False
    elapsed_ms: Optional[float] = None
    timed_out: bool = False
    input_transcript: Optional[str] = field(default=None, repr=False)
    output_transcript: Optional[str] = field(default=None, repr=False)
    output_text: Optional[str] = field(default=None, repr=False)
    audio_bytes: bytes = field(default=b"", repr=False)

    @property
    def answered(self) -> bool:
        return self.answered_audio or self.answered_text

    def public(self) -> dict[str, Any]:
        """Return a report-safe projection with no audio or transcript content."""
        return {
            "answered_audio": self.answered_audio,
            "answered_text": self.answered_text,
            "first_audio_ms": self.first_audio_ms,
            "first_transcript_ms": self.first_transcript_ms,
            "input_transcription_arrived": self.input_transcription_arrived,
            "output_transcription_arrived": self.output_transcription_arrived,
            "elapsed_ms": self.elapsed_ms,
            "timed_out": self.timed_out,
        }


def api_key_from_env() -> Optional[str]:
    """Read the only supported credential source without printing it."""
    return os.environ.get("GEMINI_API_KEY") or None


def build_client() -> genai.Client:
    key = api_key_from_env()
    if not key:
        raise PendingKeyError("pending key")
    return genai.Client(api_key=key)


def live_config() -> dict[str, Any]:
    return {
        "response_modalities": ["AUDIO"],
        "input_audio_transcription": {},
        "output_audio_transcription": {},
        "realtime_input_config": {
            "automatic_activity_detection": {"disabled": True}
        },
    }


def _value(obj: Any, name: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _part_audio(part: Any) -> bytes:
    inline = _value(part, "inline_data")
    data = _value(inline, "data")
    if isinstance(data, bytes):
        return data
    if isinstance(data, bytearray):
        return bytes(data)
    return b""


def _part_text(part: Any) -> Optional[str]:
    text = _value(part, "text")
    return text if isinstance(text, str) and text else None


def _server_content(response: Any) -> Any:
    return _value(response, "server_content") or _value(response, "serverContent")


async def _consume_until_complete(session: Any, result: LiveTurn, started: float) -> None:
    async for response in session.receive():
        now_ms = (time.monotonic() - started) * 1000.0
        content = _server_content(response)
        if content is None:
            continue

        input_tx = _value(content, "input_transcription") or _value(content, "inputTranscription")
        output_tx = _value(content, "output_transcription") or _value(content, "outputTranscription")
        if input_tx is not None:
            result.input_transcription_arrived = True
            result.input_transcript = (result.input_transcript or "") + (_value(input_tx, "text", "") or "")
            if result.first_transcript_ms is None:
                result.first_transcript_ms = now_ms
        if output_tx is not None:
            result.output_transcription_arrived = True
            result.output_transcript = (result.output_transcript or "") + (_value(output_tx, "text", "") or "")
            if result.first_transcript_ms is None:
                result.first_transcript_ms = now_ms

        model_turn = _value(content, "model_turn") or _value(content, "modelTurn")
        for part in _value(model_turn, "parts", []) or []:
            audio = _part_audio(part)
            text = _part_text(part)
            if audio:
                result.audio_bytes += audio
                result.answered_audio = True
                if result.first_audio_ms is None:
                    result.first_audio_ms = now_ms
            if text:
                result.output_text = (result.output_text or "") + text
                result.answered_text = True
                if result.first_transcript_ms is None:
                    result.first_transcript_ms = now_ms

        # Some SDK versions expose a top-level text convenience property.
        top_text = _value(response, "text")
        if isinstance(top_text, str) and top_text:
            result.output_text = (result.output_text or "") + top_text
            result.answered_text = True
            if result.first_transcript_ms is None:
                result.first_transcript_ms = now_ms

        if _value(content, "turn_complete", _value(content, "turnComplete", False)):
            break


async def run_push_to_talk(
    client: Any,
    model: str,
    clip: bytes,
    timeout_s: float = DEFAULT_TIMEOUT_S,
    chunk_ms: int = CHUNK_MS,
) -> LiveTurn:
    """Send one manually delimited turn and measure response arrival."""
    result = LiveTurn()
    started = time.monotonic()
    chunk_bytes = max(2, SAMPLE_RATE * 2 * chunk_ms // 1000)
    async with client.aio.live.connect(model=model, config=live_config()) as session:
        await session.send_realtime_input(activity_start=types.ActivityStart())
        for offset in range(0, len(clip), chunk_bytes):
            await session.send_realtime_input(
                audio=types.Blob(
                    data=clip[offset : offset + chunk_bytes],
                    mime_type="audio/pcm;rate=16000",
                )
            )
        await session.send_realtime_input(activity_end=types.ActivityEnd())
        try:
            await asyncio.wait_for(_consume_until_complete(session, result, started), timeout=timeout_s)
        except asyncio.TimeoutError:
            result.timed_out = True

    result.elapsed_ms = (time.monotonic() - started) * 1000.0
    return result


async def _main_async(args: argparse.Namespace) -> int:
    try:
        client = build_client()
    except PendingKeyError:
        print('{"status": "pending key"}')
        return 0
    clip = open(args.clip, "rb").read()
    measurement = await run_push_to_talk(client, args.model, clip, args.timeout)
    print(measurement.public())
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Gemini Live manual push-to-talk probe")
    parser.add_argument("clip", help="raw mono 16-bit PCM clip at 16 kHz")
    parser.add_argument("--model", default=LIVE_MODELS[0], choices=LIVE_MODELS)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    return asyncio.run(_main_async(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
