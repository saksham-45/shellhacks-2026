from __future__ import annotations

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

try:
    from . import fallback, live_ptt
    from .audio_fixtures import RATE, ensure_clips
except ImportError:  # direct pytest execution
    import fallback
    import live_ptt
    from audio_fixtures import RATE, ensure_clips


class FakeSession:
    def __init__(self, events=(), fail=False):
        self.events = list(events)
        self.sent = []
        self.fail = fail

    async def __aenter__(self):
        if self.fail:
            raise RuntimeError("automatic detection rejected")
        return self

    async def __aexit__(self, *args):
        return False

    async def send_realtime_input(self, **kwargs):
        if "activity_start" in kwargs:
            self.sent.append("activity_start")
        elif "activity_end" in kwargs:
            self.sent.append("activity_end")
        elif "audio" in kwargs:
            self.sent.append("audio")

    async def receive(self):
        for event in self.events:
            yield event


class FakeConnect:
    def __init__(self, session):
        self.session = session

    def __call__(self, *, model, config):
        self.model = model
        self.config = config
        return self.session


class FakeClient:
    def __init__(self, live_events=(), fallback_text=None, tts_bytes=b"tts", tts_error=False):
        self.session = FakeSession(live_events)
        self.aio = SimpleNamespace(
            live=SimpleNamespace(connect=FakeConnect(self.session)),
            models=SimpleNamespace(generate_content=self.generate_content),
            interactions=SimpleNamespace(create=self.create_tts),
        )
        self.fallback_text = fallback_text or '{"transcript_in":"hidden question","text_out":"TEST-ONLY fictional response"}'
        self.tts_bytes = tts_bytes
        self.tts_error = tts_error
        self.generate_calls = []
        self.tts_calls = []

    async def generate_content(self, **kwargs):
        self.generate_calls.append(kwargs)
        return SimpleNamespace(text=self.fallback_text)

    async def create_tts(self, **kwargs):
        self.tts_calls.append(kwargs)
        if self.tts_error:
            raise RuntimeError("tts unavailable")
        import base64
        return SimpleNamespace(output_audio=SimpleNamespace(data=base64.b64encode(self.tts_bytes).decode()))


def clip() -> bytes:
    return b"\x01\x00" * 1600


def test_silent_model_triggers_fallback():
    client = FakeClient()
    result = asyncio.run(fallback.answer_turn(clip(), client=client, timeout_s=0.01))
    assert result.path == "fallback"
    assert result.text_out == "TEST-ONLY fictional response"
    assert result.audio_out == b"tts"
    assert client.generate_calls
    assert any(getattr(item, "inline_data", None) is not None for item in client.generate_calls[0]["contents"] if not isinstance(item, str))


def test_fallback_always_returns_text_when_tts_fails():
    client = FakeClient(tts_error=True)
    result = asyncio.run(fallback.answer_turn(clip(), client=client, timeout_s=0.01))
    assert result.path == "text_only"
    assert result.text_out == "TEST-ONLY fictional response"
    assert result.audio_out is None


def test_push_to_talk_boundaries_surround_audio():
    client = FakeClient()
    measurement = asyncio.run(live_ptt.run_push_to_talk(client, "gemini-3.8-live", clip(), timeout_s=0.01))
    assert client.session.sent[0] == "activity_start"
    assert client.session.sent[-1] == "activity_end"
    assert client.session.sent[1:-1] and all(event == "audio" for event in client.session.sent[1:-1])
    assert client.aio.live.connect.config["realtime_input_config"]["automatic_activity_detection"]["disabled"] is True
    assert not measurement.answered


def test_no_transcript_content_in_logs_or_report_projection(caplog):
    content = SimpleNamespace(
        input_transcription=SimpleNamespace(text="PRIVATE INPUT"),
        output_transcription=SimpleNamespace(text="PRIVATE OUTPUT"),
        model_turn=SimpleNamespace(parts=[SimpleNamespace(text="PRIVATE OUTPUT")]),
        turn_complete=True,
    )
    client = FakeClient(live_events=[SimpleNamespace(server_content=content)])
    measurement = asyncio.run(live_ptt.run_push_to_talk(client, "gemini-3.8-live", clip(), timeout_s=1))
    logged = " ".join(record.getMessage() for record in caplog.records)
    assert "PRIVATE" not in logged
    assert "PRIVATE" not in json.dumps(measurement.public())


def test_no_key_is_pending(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    with pytest.raises(live_ptt.PendingKeyError, match="pending key"):
        live_ptt.build_client()
    result = asyncio.run(fallback.answer_turn(clip(), client=None, timeout_s=0.01))
    assert result.latencies["status"] == "pending key"
    assert result.transcript_in is None and result.text_out is None


def test_audio_fixtures_are_16khz_pcm(tmp_path: Path):
    info = ensure_clips(tmp_path)
    assert info["sample_rate"] == RATE
    assert info["channels"] == 1
    assert (tmp_path / "english.pcm").stat().st_size % 2 == 0
    assert (tmp_path / "spanish.pcm").stat().st_size % 2 == 0
