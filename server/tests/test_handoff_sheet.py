"""POST /v1/handoff-sheet (offline; fake summarizers stand in for Gemini)."""
from __future__ import annotations

import builtins
import os

import pytest

from demo_support import FakeGenaiClient, go_live, make_client


def body(utterances, language="en", ticked=(), **extra):
    return {"person_id": "p-test-only", "language": language, "utterances": list(utterances),
            "ticked_status_words": list(ticked), "desk_id": "us-fl-miamidade.test-desk", **extra}


class FakeSummarizer:
    """Stands in for GeminiHandoffSummarizer: returns exactly the drafts it was given."""

    name = "gemini"

    def __init__(self, drafts):
        self.drafts = drafts

    async def summarize(self, utterances, language):
        return list(self.drafts)


def draft(text, idx, read_back=None):
    from myad_server.demo.handoff import Draft

    return Draft(text=text, source_utterance_index=idx, read_back=read_back)


def client_with(make_harness, drafts):
    return make_client(make_harness, summarizer_factory=lambda: FakeSummarizer(drafts))


def post(client, payload):
    r = client.post("/v1/handoff-sheet", json=payload)
    assert r.status_code == 200, r.text
    return r.json()


def test_extractive_english_keeps_the_persons_words(make_harness):
    utts = ["My landlord changed the locks on 9/20.", "I have my lease and the receipts."]
    sheet = post(make_client(make_harness), body(utts))
    assert sheet["summarizer"] == "extractive" and sheet["language"] == "en" and sheet["approved"] is False
    assert [s["text"] for s in sheet["sentences"]] == utts
    assert [s["source_utterance_index"] for s in sheet["sentences"]] == [0, 1]
    assert [r["text"] for r in sheet["read_back"]] == utts and sheet["dropped"] == []
    assert not any(s["needs_translation"] for s in sheet["sentences"])


def test_extractive_spanish_marks_needs_translation_and_never_invents_one(make_harness):
    utts = ["Mi casero cambió las cerraduras el 20 de septiembre."]
    sheet = post(make_client(make_harness), body(utts, "es"))
    [s] = sheet["sentences"]
    assert s == {"text": utts[0], "source_utterance_index": 0, "needs_translation": True}
    assert sheet["read_back"] == [{"text": utts[0], "source_utterance_index": 0}]
    assert sheet["read_back_language"] == "es"


def test_unsupported_sentence_is_dropped(make_harness):
    drafts = [draft("My rent is due on the first.", 0), draft("The landlord threatened to hurt my family.", 0)]
    sheet = post(client_with(make_harness, drafts), body(["My rent is due on the first of the month."]))
    assert [s["text"] for s in sheet["sentences"]] == ["My rent is due on the first."]
    assert sheet["dropped"] == [{"reason": "unsupported", "source_utterance_index": 0}]


def test_number_the_person_never_said_is_unsupported(make_harness):
    sheet = post(client_with(make_harness, [draft("My rent is 2500 dollars.", 0)]), body(["My rent is 1500 dollars."]))
    assert sheet["sentences"] == [] and sheet["dropped"][0]["reason"] == "unsupported"


def test_unsaid_legal_word_is_dropped(make_harness):
    drafts = [draft("My landlord illegally changed the locks yesterday.", 0)]
    sheet = post(client_with(make_harness, drafts), body(["My landlord changed the locks yesterday."]))
    assert sheet["sentences"] == []
    assert sheet["dropped"] == [{"reason": "unsaid_legal_word", "source_utterance_index": 0}]


def test_unsaid_status_word_is_dropped_even_if_ticked(make_harness):
    drafts = [draft("I have TPS and a work card.", 0)]
    sheet = post(client_with(make_harness, drafts), body(["I have a work card."], ticked=["TPS"]))
    assert sheet["dropped"] == [{"reason": "unsaid_legal_word", "source_utterance_index": 0}]


def test_legal_word_the_person_said_is_kept(make_harness):
    drafts = [draft("My landlord said he will evict me.", 0)]
    sheet = post(client_with(make_harness, drafts), body(["My landlord said he will evict me next week."]))
    assert [s["text"] for s in sheet["sentences"]] == ["My landlord said he will evict me."]


def test_unticked_status_word_is_dropped(make_harness):
    utts = ["Tengo asilo pendiente y necesito ayuda con la renta."]
    sheet = post(make_client(make_harness), body(utts, "es"))
    assert sheet["sentences"] == []
    assert sheet["dropped"] == [{"reason": "unticked_status_word", "source_utterance_index": 0}]
    for tick in (["asilo"], ["asylum"]):  # the tick counts in any language
        kept = post(make_client(make_harness), body(utts, "es", ticked=tick))
        assert [s["text"] for s in kept["sentences"]] == utts


def test_tourist_mode_never_carries_a_status_word(make_harness):
    sheet = post(make_client(make_harness), body(["I am here on a visa and lost my passport."], ticked=["visa"],
                                                  mode="tourist"))
    assert sheet["sentences"] == [] and sheet["dropped"][0]["reason"] == "unticked_status_word"


def test_live_translation_check_uses_the_read_back(make_harness):
    utts = ["Mi casero cambió las cerraduras ayer."]
    good = draft("My landlord changed the locks yesterday.", 0, "Mi casero cambió las cerraduras ayer.")
    bad = draft("My landlord owes me 500 dollars.", 0, "Mi casero me debe 500 dólares.")
    sheet = post(client_with(make_harness, [good, bad]), body(utts, "es"))
    assert [s["text"] for s in sheet["sentences"]] == ["My landlord changed the locks yesterday."]
    assert sheet["read_back"] == [{"text": "Mi casero cambió las cerraduras ayer.", "source_utterance_index": 0}]
    assert sheet["dropped"] == [{"reason": "unsupported", "source_utterance_index": 0}]


def test_bad_index_is_dropped(make_harness):
    sheet = post(client_with(make_harness, [draft("I need an interpreter.", 7)]), body(["I need an interpreter."]))
    assert sheet["sentences"] == [] and sheet["dropped"] == [{"reason": "bad_index", "source_utterance_index": None}]


def test_gemini_summarizer_via_fake_client(make_harness, monkeypatch):
    utts = ["Mi casero cambió las cerraduras ayer.", "Tengo el contrato."]
    fake = FakeGenaiClient(output={"sentences": [
        {"text": "My landlord changed the locks yesterday.", "read_back": "Mi casero cambió las cerraduras ayer.",
         "source_utterance_index": 0},
        {"text": "I have the lease and I am undocumented.", "read_back": "Tengo el contrato y soy indocumentado.",
         "source_utterance_index": 1},
    ]})
    go_live(monkeypatch, fake)
    sheet = post(make_client(make_harness), body(utts, "es"))
    assert sheet["summarizer"] == "gemini"
    assert [s["text"] for s in sheet["sentences"]] == ["My landlord changed the locks yesterday."]
    assert sheet["dropped"] == [{"reason": "unsaid_legal_word", "source_utterance_index": 1}]
    [call] = fake.interactions.calls
    assert call["model"] == "gemini-3.8-flash"
    item = call["response_format"]["schema"]["properties"]["sentences"]["items"]
    assert item["properties"]["source_utterance_index"]["maximum"] == 1


def test_gemini_failure_falls_back_to_extractive(make_harness, monkeypatch):
    go_live(monkeypatch, FakeGenaiClient(exc=RuntimeError("TEST-ONLY outage")))
    sheet = post(make_client(make_harness), body(["I need help with my rent."]))
    assert sheet["summarizer"] == "extractive" and len(sheet["sentences"]) == 1


def test_nothing_is_stored(make_harness, monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    real_open = builtins.open

    def guarded_open(file, mode="r", *args, **kwargs):
        if any(flag in mode for flag in ("w", "a", "x", "+")):
            pytest.fail(f"handoff wrote a file: {file!r}")
        return real_open(file, mode, *args, **kwargs)

    client = make_client(make_harness)
    client.post("/v1/handoff-sheet", json=body(["warm-up"]))  # load the word lists before guarding
    monkeypatch.setattr(builtins, "open", guarded_open)
    first = post(client, body(["UNIQUE-TEST-ONLY-ALPHA my heater is broken."]))
    second = post(client, body(["I need a Spanish interpreter."]))
    assert "ALPHA" in first["sentences"][0]["text"]
    assert "ALPHA" not in str(second)  # no carry-over between requests
    assert os.listdir(tmp_path) == []


def test_validation_limits(make_harness):
    client = make_client(make_harness)
    assert client.post("/v1/handoff-sheet", json=body([])).status_code == 422
    r = client.post("/v1/handoff-sheet", json=body(["x" * 1001]))
    assert r.status_code == 422 and "xxxx" not in r.text
