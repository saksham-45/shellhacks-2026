"""Probe server-side automatic activity detection without logging content."""
from __future__ import annotations

import argparse
import asyncio
import time
from typing import Any, Optional

from google.genai import types

try:
    from .live_ptt import LIVE_MODELS, SAMPLE_RATE, api_key_from_env, build_client, PendingKeyError
except ImportError:  # script execution
    from live_ptt import LIVE_MODELS, SAMPLE_RATE, api_key_from_env, build_client, PendingKeyError


def _value(obj: Any, name: str, default: Any = None) -> Any:
    if obj is None:
        return default
    if isinstance(obj, dict):
        return obj.get(name, default)
    return getattr(obj, name, default)


def _content(response: Any) -> Any:
    return _value(response, "server_content") or _value(response, "serverContent")


def _has_model_part(content: Any) -> bool:
    turn = _value(content, "model_turn") or _value(content, "modelTurn")
    for part in _value(turn, "parts", []) or []:
        if _value(part, "text") or _value(_value(part, "inline_data"), "data"):
            return True
    return False


def automatic_vad_config() -> dict[str, Any]:
    return {
        "response_modalities": ["AUDIO"],
        "input_audio_transcription": {},
        "output_audio_transcription": {},
        "realtime_input_config": {"automatic_activity_detection": {"disabled": False}},
    }


async def probe_model(
    client: Any,
    model: str,
    clip: bytes,
    timeout_s: float = 6.0,
    silence_s: float = 1.2,
) -> dict[str, Any]:
    started = time.monotonic()
    result: dict[str, Any] = {
        "model": model,
        "automatic_detection_enabled": False,
        "detection_on_error": False,
        "triggered": False,
        "interrupted": False,
        "turn_complete": False,
        "response_arrived": False,
        "fired_after_ms": None,
        "elapsed_ms": None,
    }
    chunk_bytes = SAMPLE_RATE * 2 * 100 // 1000
    try:
        async with client.aio.live.connect(model=model, config=automatic_vad_config()) as session:
            result["automatic_detection_enabled"] = True
            for offset in range(0, len(clip), chunk_bytes):
                await session.send_realtime_input(
                    audio=types.Blob(data=clip[offset : offset + chunk_bytes], mime_type="audio/pcm;rate=16000")
                )
            silence_bytes = b"\x00" * chunk_bytes
            for _ in range(max(1, int(silence_s * 1000 / 100))):
                await session.send_realtime_input(
                    audio=types.Blob(data=silence_bytes, mime_type="audio/pcm;rate=16000")
                )
            try:
                async for response in await _receive_with_timeout(session, timeout_s):
                    content = _content(response)
                    if content is None:
                        continue
                    interrupted = bool(_value(content, "interrupted", False))
                    complete = bool(_value(content, "turn_complete", _value(content, "turnComplete", False)))
                    response_here = interrupted or complete or _has_model_part(content)
                    result["interrupted"] = result["interrupted"] or interrupted
                    result["turn_complete"] = result["turn_complete"] or complete
                    result["response_arrived"] = result["response_arrived"] or response_here
                    if response_here and result["fired_after_ms"] is None:
                        result["fired_after_ms"] = (time.monotonic() - started) * 1000.0
                    result["triggered"] = result["triggered"] or response_here
                    if complete:
                        break
            except asyncio.TimeoutError:
                pass
    except Exception:
        # The report records only that enabling automatic detection failed.
        result["detection_on_error"] = True
        result["automatic_detection_enabled"] = False
    result["elapsed_ms"] = (time.monotonic() - started) * 1000.0
    return result


async def _receive_with_timeout(session: Any, timeout_s: float):
    async def collect():
        async for item in session.receive():
            yield item
    # A wrapper whose async iterator is bounded by a task is awkward; use a
    # queue so the public loop remains simple and compatible with fake sessions.
    queue: asyncio.Queue[Any] = asyncio.Queue()
    done = object()

    async def pump():
        try:
            async for item in session.receive():
                await queue.put(item)
        finally:
            await queue.put(done)

    task = asyncio.create_task(pump())

    async def bounded():
        try:
            while True:
                item = await asyncio.wait_for(queue.get(), timeout=timeout_s)
                if item is done:
                    return
                yield item
        finally:
            if not task.done():
                task.cancel()

    return bounded()


def main() -> int:
    parser = argparse.ArgumentParser(description="Gemini Live automatic VAD probe")
    parser.add_argument("clip")
    parser.add_argument("--timeout", type=float, default=6.0)
    args = parser.parse_args()
    if not api_key_from_env():
        print('{"status": "pending key"}')
        return 0
    client = build_client()
    clip = open(args.clip, "rb").read()

    async def run():
        for model in LIVE_MODELS:
            print(await probe_model(client, model, clip, args.timeout))

    asyncio.run(run())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
