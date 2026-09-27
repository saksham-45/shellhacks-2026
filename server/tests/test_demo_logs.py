"""Log capture across all four demo routes: only request_id, route, status, latency and counts are logged."""
from __future__ import annotations

import base64
import logging
import re

from demo_support import FakeGenaiClient, go_live, make_client

SECRET = "ZEBRAQUARTZ"  # appears in every piece of user input below
ACCESS = re.compile(r"^request_id=[A-Za-z0-9-]+ route=/[\w/-]+ status=\d{3} latency_ms=\d+\.\d counts=[\w:,]*$")


def _exercise(client):
    client.post("/v1/fee-check", json={"region": "us-fl-miamidade", "language": "es",
                                       "text": f"{SECRET} me cobra 300 dólares por la licencia"})
    client.post("/v1/fee-check", json={"region": "us-fl-miamidade", "language": "en", "text": SECRET * 300})
    client.post("/v1/handoff-sheet", json={"person_id": "p-test", "language": "es", "desk_id": "us.test-desk",
                                           "utterances": [f"{SECRET} mi casero", "tengo asilo"],
                                           "ticked_status_words": []})
    client.post("/v1/desk/translate", json={"text": f"{SECRET}?", "source_language": "en", "target_language": "es"})
    client.post("/v1/desk/translate", json={"audio_b64": base64.b64encode(SECRET.encode() * 2).decode(),
                                            "source_language": "en", "target_language": "es"})
    client.post("/v1/live/token", json={"source_language": "en", "target_language": "es"})


def _assert_clean(caplog, key=None):
    access = [r.getMessage() for r in caplog.records if r.name == "myad.access"]
    assert len(access) == 6
    for line in access:
        assert ACCESS.match(line), line
    everything = caplog.text + " ".join(str(r.args) for r in caplog.records)
    assert SECRET not in everything
    assert "WkVCUkFR" not in everything  # base64 of the audio bytes
    if key:
        assert key not in everything


def test_offline_logs_carry_no_user_text(make_harness, caplog):
    client = make_client(make_harness)
    with caplog.at_level(logging.DEBUG):
        _exercise(client)
    _assert_clean(caplog)


def test_live_paths_log_no_user_text_no_key_no_token(make_harness, monkeypatch, caplog):
    key = "TEST-ONLY-SERVER-KEY-XYZ"
    go_live(monkeypatch, FakeGenaiClient(output={"transcript": SECRET, "translation": SECRET,
                                                 "payee_type": "unknown", "purpose_key": "unknown",
                                                 "amount_cents": None, "method": "unknown", "sentences": []}),
            key=key)
    client = make_client(make_harness)
    with caplog.at_level(logging.DEBUG):
        _exercise(client)
    _assert_clean(caplog, key)
    assert "auth_tokens/TEST-ONLY-ephemeral" not in caplog.text
