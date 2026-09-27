"""POST /v1/desk/translate and POST /v1/live/token: 503 offline/keyless; happy paths with a fake client."""
from __future__ import annotations

import base64
import io
import wave
from datetime import datetime, timedelta, timezone

import pytest

from demo_support import FakeGenaiClient, go_live, make_client

PCM_1S = b"\x00\x01" * 16_000  # 1 s of 16 kHz mono PCM16 (TEST-ONLY tone-free bytes)


def audio_body(pcm=PCM_1S, **extra):
    return {"audio_b64": base64.b64encode(pcm).decode(), "source_language": "en", "target_language": "es", **extra}


def wav_bytes(rate=16_000, channels=1, seconds=1.0):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * int(rate * seconds) * channels)
    return buf.getvalue()


@pytest.fixture
def client(make_harness):
    return make_client(make_harness)


# ---- /v1/desk/translate -----------------------------------------------------------------------------------


def test_translate_offline_is_503_fallback_unavailable(client, monkeypatch):
    from myad_server.demo import genai as G

    monkeypatch.setenv("GEMINI_API_KEY", "TEST-ONLY-NOT-A-KEY")  # a key does not matter offline
    monkeypatch.setattr(G, "build_client", lambda *a: pytest.fail("offline built a client"))
    r = client.post("/v1/desk/translate", json=audio_body())
    assert r.status_code == 503 and r.json()["error"] == "fallback_unavailable"
    assert r.json()["request_id"] == r.headers["X-Request-ID"]
    r = client.post("/v1/desk/translate", json={"text": "Proof of address?", "source_language": "en",
                                                "target_language": "es"})
    assert r.status_code == 503 and r.json() == {"error": "fallback_unavailable",
                                                 "request_id": r.headers["X-Request-ID"]}


def test_translate_keyless_is_503(client, monkeypatch):
    monkeypatch.setenv("MYAD_OFFLINE", "0")
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    assert client.post("/v1/desk/translate", json=audio_body()).json()["error"] == "fallback_unavailable"


def test_audio_size_is_capped_before_anything_else(client):
    too_long = b"\x00\x00" * (16_000 * 16)  # 16 s: over the schema's base64 cap
    r = client.post("/v1/desk/translate", json=audio_body(too_long))
    assert r.status_code == 413 and r.json()["error"] == "audio_too_large" and "AAAA" not in r.text


def test_decode_audio_limits():
    from myad_server.demo.desk_translate import AudioRejected, decode_audio
    from myad_server.demo_models import MAX_AUDIO_BYTES

    ok = decode_audio(base64.b64encode(b"\x00\x00" * int(16_000 * 15.5)).decode())
    assert ok[:4] == b"RIFF"
    with pytest.raises(AudioRejected) as e:
        decode_audio(base64.b64encode(b"\x00" * (MAX_AUDIO_BYTES + 2)).decode())
    assert e.value.code == "audio_too_large"
    with pytest.raises(AudioRejected) as e:
        decode_audio(base64.b64encode(wav_bytes(channels=2)).decode())
    assert e.value.code == "audio_format"
    assert decode_audio(base64.b64encode(wav_bytes()).decode())[:4] == b"RIFF"


def test_audio_format_is_checked(client):
    assert client.post("/v1/desk/translate", json=audio_body(b"\x00" * 3)).json()["error"] == "audio_format"
    r = client.post("/v1/desk/translate", json=audio_body(wav_bytes(rate=44_100)))
    assert r.status_code == 422 and r.json()["error"] == "audio_format"
    r = client.post("/v1/desk/translate", json={"audio_b64": "!!not-base64!!", "source_language": "en",
                                                "target_language": "es"})
    assert r.json()["error"] == "audio_format"


def test_exactly_one_input(client):
    r = client.post("/v1/desk/translate", json={**audio_body(), "text": "hi"})
    assert r.status_code == 422 and r.json()["error"] == "invalid_request"
    assert client.post("/v1/desk/translate", json={"source_language": "en", "target_language": "es"}).status_code == 422


def test_translate_happy_path_with_fake_client(make_harness, monkeypatch):
    fake = FakeGenaiClient(output={"transcript": "Proof of address?", "translation": "¿Comprobante de domicilio?"})
    builds = go_live(monkeypatch, fake)
    r = make_client(make_harness).post("/v1/desk/translate", json=audio_body())
    assert r.status_code == 200, r.text
    assert r.json() == {"request_id": r.headers["X-Request-ID"], "transcript": "Proof of address?",
                        "translation": "¿Comprobante de domicilio?", "mode": "fallback",
                        "source_language": "en", "target_language": "es"}
    assert builds == [()]
    [call] = fake.interactions.calls
    assert call["model"] == "gemini-3.8-flash"
    assert call["response_format"]["mime_type"] == "application/json"
    assert set(call["response_format"]["schema"]["required"]) == {"transcript", "translation"}
    audio = [p for p in call["input"] if p["type"] == "audio"]
    assert len(audio) == 1 and audio[0]["mime_type"] == "audio/wav"
    assert base64.b64decode(audio[0]["data"])[:4] == b"RIFF"  # raw PCM wrapped in memory, not re-encoded


def test_translate_text_keeps_the_phones_own_transcript(make_harness, monkeypatch):
    go_live(monkeypatch, FakeGenaiClient(output={"transcript": "REWRITTEN", "translation": "¿Comprobante?"}))
    r = make_client(make_harness).post("/v1/desk/translate", json={"text": "Proof?", "source_language": "en",
                                                                    "target_language": "es"})
    assert r.status_code == 200 and r.json()["transcript"] == "Proof?"


def test_translate_model_failure_is_503(make_harness, monkeypatch):
    go_live(monkeypatch, FakeGenaiClient(exc=RuntimeError("TEST-ONLY outage")))
    r = make_client(make_harness).post("/v1/desk/translate", json=audio_body())
    assert r.status_code == 503 and r.json()["error"] == "fallback_unavailable"


# ---- /v1/live/token ---------------------------------------------------------------------------------------


def test_token_offline_and_keyless_are_503(client, monkeypatch):
    r = client.post("/v1/live/token", json={})
    assert r.status_code == 503 and r.json()["error"] == "live_unavailable"
    monkeypatch.setenv("MYAD_OFFLINE", "0")
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    assert client.post("/v1/live/token", json={}).json()["error"] == "live_unavailable"


def test_token_happy_path_locks_the_live_config(make_harness, monkeypatch):
    fake = FakeGenaiClient()
    key = "TEST-ONLY-SERVER-KEY-NEVER-SENT"
    builds = go_live(monkeypatch, fake, key=key)
    before = datetime.now(timezone.utc)
    r = make_client(make_harness).post("/v1/live/token", json={"source_language": "en", "target_language": "es"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["token"] == "auth_tokens/TEST-ONLY-ephemeral" and key not in r.text
    assert body["uses"] == 1 and body["api_version"] == "v1alpha"
    assert body["constraints"] == {"model": "gemini-3.1-flash-live-preview", "response_modalities": ["AUDIO"],
                                   "automatic_activity_detection_disabled": True,
                                   "input_audio_transcription": True, "output_audio_transcription": True}
    assert builds == [("v1alpha",)]
    [config] = fake.auth_tokens.calls
    assert config["uses"] == 1 and config["http_options"] == {"api_version": "v1alpha"}
    assert config["expire_time"] - before <= timedelta(minutes=11)  # short: well under the 30 min default
    assert config["new_session_expire_time"] - before <= timedelta(seconds=61)
    constraints = config["live_connect_constraints"]
    assert constraints["model"] == "gemini-3.1-flash-live-preview"
    live = constraints["config"]
    assert live["realtime_input_config"] == {"automatic_activity_detection": {"disabled": True}}
    assert live["input_audio_transcription"] == {} and live["output_audio_transcription"] == {}
    assert live["response_modalities"] == ["AUDIO"] and "proactivity" not in live
    assert "lock_additional_fields" not in config  # effective setup comes entirely from the constraints


def test_token_model_override_and_failure(make_harness, monkeypatch):
    fake = FakeGenaiClient(token_exc=RuntimeError("TEST-ONLY outage"))
    go_live(monkeypatch, fake)
    monkeypatch.setenv("MYAD_LIVE_MODEL", "gemini-3.8-live")
    r = make_client(make_harness).post("/v1/live/token", json={})
    assert r.status_code == 503 and r.json()["error"] == "live_unavailable"
    assert fake.auth_tokens.calls[0]["live_connect_constraints"]["model"] == "gemini-3.8-live"
