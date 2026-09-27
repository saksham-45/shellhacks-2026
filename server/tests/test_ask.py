"""Phase 1c-i /ask coverage using obviously fake, test-only fixture bundles."""
from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from myad_server.ask.ranker import StubRanker
from myad_server.cards import BundleCard
from myad_server.ask.resolve import resolve_intent
from myad_server.app import create_app
from myad_server.intent import AskRequest, IntentResolution
from myad_server.values import Mode


def request(text: str, language: str = "en", *, stage: int = 1, mode: str = "resident") -> AskRequest:
    return AskRequest.model_validate({
        "utterance": {"text": text, "language": language},
        "stage": stage,
        "mode": mode,
    })


def harness_with(make_harness, *extra: BundleCard):
    """A harness whose bundle is a COPY of the session fixture plus `extra` (never mutates shared state)."""
    from myad_server.harness import Harness

    base = make_harness()
    bundle = type(base.deps.bundle)(cards={**base.deps.bundle.cards, **{c.id: c for c in extra}},
                                    source=base.deps.bundle.source, missing=False)
    return Harness.build(bundle=bundle, ledger=base.deps.ledger, command_keys=base.deps.command_keys,
                         now=base.deps.now)


def resolved(make_harness, text: str, language: str = "en", *, mode: str = "resident"):
    h = make_harness()
    return resolve_intent(request(text, language, mode=mode), h.deps.bundle, h.deps.ledger, StubRanker())


@pytest.mark.parametrize(("text", "language"), [
    ("when is trash day", "en"),
    ("cuándo pasa la basura", "es"),
    ("kilè kamyon fatra a pase", "ht"),
])
def test_confident_match_in_each_supported_language(make_harness, text, language):
    result = resolved(make_harness, text, language)
    assert result.grounding.type == "card"
    assert result.grounding.card_id == "test-trash-day"
    assert result.reply_language == language
    assert result.action.type == "navigate"


def test_code_switched_utterance_reaches_trash_card(make_harness):
    result = resolved(make_harness, "cuándo es el trash day", "es")
    assert result.grounding.type == "card"
    assert result.grounding.card_id == "test-trash-day"


def test_close_candidates_make_two_or_three_navigation_options(make_harness):
    result = resolved(make_harness, "trash", "en")
    assert result.clarification is not None
    assert 2 <= len(result.clarification.options) <= 3
    assert all(option.action.type == "navigate" for option in result.clarification.options)
    assert all(option.label.key.startswith("card.") and option.label.key.endswith(".title")
               for option in result.clarification.options)


def test_no_match_falls_back_to_a_ledger_desk(make_harness):
    result = resolved(make_harness, "something not in the cards", "en")
    assert result.grounding.type == "desk"
    assert result.grounding.desk_id
    assert result.action is None


@pytest.mark.parametrize(("text", "topic"), [
    ("will I get a visa", "visa_outcome"),
    ("how much does the clinic cost", "clinic_price"),
    ("can you give me a job", "job"),
    ("when is the next appointment slot", "appointment_slot"),
    ("am I eligible for the school bus", "school_bus_eligibility"),
])
def test_each_desk_only_topic_is_a_handoff(make_harness, text, topic):
    result = resolved(make_harness, text)
    assert result.grounding.type == "desk"
    assert result.grounding.reason.key == f"ask.reason.desk_only.{topic}"
    assert result.action.destination.type == "desk"


def test_tourist_mode_drops_immigration_cards(make_harness):
    result = resolved(make_harness, "renew my work permit", mode="tourist")
    assert not (result.action and result.action.destination.type == "card"
                and result.action.destination.card_id == "test-work-permit")


@pytest.mark.parametrize("extra", [{"pin": {"address": "TEST ONLY"}}, {"papers": {"status_word": "TEST"}}])
def test_extra_ask_fields_are_rejected(extra):
    with pytest.raises(ValidationError):
        AskRequest.model_validate({
            "utterance": {"text": "hello", "language": "en"},
            "stage": 1,
            "mode": "resident",
            **extra,
        })


def test_endpoint_utterance_never_appears_in_logs(make_harness, caplog):
    sentinel = "TEST-ONLY unique ask sentinel 9f2e"
    app = create_app(lambda: make_harness())
    with caplog.at_level(logging.DEBUG):
        with TestClient(app) as client:
            response = client.post("/v1/ask", json={
                "utterance": {"text": sentinel, "language": "en"},
                "stage": 1,
                "mode": "resident",
            })
    assert response.status_code == 200
    assert all(sentinel not in record.getMessage() for record in caplog.records)


def test_endpoint_desk_only_policy_wins_over_matching_test_card(make_harness):
    harness = harness_with(make_harness, BundleCard.model_validate({
        "id": "test-visa-outcome",
        "title": {"es": "TEST-ONLY visa", "en": "TEST-ONLY visa", "ht": "TEST-ONLY visa"},
        "desk": "us.test-desk",
        "scope": "household",
        "stages": [1],
        "modes": ["resident", "tourist"],
        "region_pack": "us",
        "fact_refs": ["us.test.fee"],
        "topics": ["immigration"],
        "utterances": {"es": ["me van a dar la visa"], "en": ["will I get a visa"], "ht": []},
        "actions": [],
        "needs_review": {"es": True, "en": True, "ht": True},
        "immigration": True,
    }))
    app = create_app(lambda: harness)
    with TestClient(app) as client:
        response = client.post("/v1/ask", json={
            "utterance": {"text": "me van a dar la visa", "language": "es"},
            "stage": 1,
            "mode": "resident",
        })
    body = response.json()
    assert response.status_code == 200
    assert body["grounding"]["type"] == "desk"
    assert body["grounding"]["reason"]["key"] == "ask.reason.desk_only.visa_outcome"
    assert body["action"]["destination"]["type"] == "desk"
    assert body["action"]["destination"]["desk_id"] == "us.test-desk"


@pytest.mark.parametrize(("text", "language", "stage", "topic"), [
    ("Èske viza mwen ap jwenn apwobasyon?", "ht", 1, "visa_outcome"),
    ("me van a dar la visa", "es", 1, "visa_outcome"),
    ("me van a approve la visa", "es", 1, "visa_outcome"),
    ("cuánto cuesta la clínica", "es", 6, "clinic_price"),
    ("me van a dar un trabajo", "es", 1, "job"),
])
def test_endpoint_desk_only_policy_in_all_supported_wording(make_harness, text, language, stage, topic):
    app = create_app(lambda: make_harness())
    with TestClient(app) as client:
        response = client.post("/v1/ask", json={
            "utterance": {"text": text, "language": language},
            "stage": stage,
            "mode": "resident",
        })
    body = response.json()
    assert response.status_code == 200
    assert body["grounding"]["type"] == "desk"
    assert body["grounding"]["reason"]["key"] == f"ask.reason.desk_only.{topic}"
    assert body["action"]["destination"]["type"] == "desk"


def test_endpoint_tourist_mode_hides_immigration_desk(make_harness):
    harness = harness_with(make_harness, BundleCard.model_validate({
        "id": "test-visa-outcome",
        "title": {"es": "TEST-ONLY visa", "en": "TEST-ONLY visa", "ht": "TEST-ONLY visa"},
        "desk": "us.test-desk",
        "scope": "household",
        "stages": [1],
        "modes": ["resident", "tourist"],
        "region_pack": "us",
        "fact_refs": ["us.test.fee"],
        "topics": ["immigration"],
        "utterances": {"es": ["me van a dar la visa"], "en": ["will I get a visa"], "ht": []},
        "actions": [],
        "needs_review": {"es": True, "en": True, "ht": True},
        "immigration": True,
    }))
    app = create_app(lambda: harness)
    with TestClient(app) as client:
        response = client.post("/v1/ask", json={
            "utterance": {"text": "me van a dar la visa", "language": "es"},
            "stage": 1,
            "mode": "tourist",
        })
    body = response.json()
    assert response.status_code == 200
    assert body["action"] is None
    assert body["grounding"]["reason"]["key"] == "router.no_answer"
    assert body["grounding"]["desk_id"] != "us.test-desk"


def test_endpoint_tourist_mode_keeps_nonimmigration_clinic_handoff(make_harness):
    app = create_app(lambda: make_harness())
    with TestClient(app) as client:
        response = client.post("/v1/ask", json={
            "utterance": {"text": "cuánto cuesta la clínica", "language": "es"},
            "stage": 6,
            "mode": "tourist",
        })
    body = response.json()
    assert response.status_code == 200
    assert body["grounding"]["reason"]["key"] == "ask.reason.desk_only.clinic_price"
    assert body["action"]["destination"]["type"] == "desk"


def test_endpoint_rejects_extra_fields_and_returns_contract_shape(make_harness):
    app = create_app(lambda: make_harness())
    with TestClient(app) as client:
        response = client.post("/v1/ask", json={
            "utterance": {"text": "when is trash day", "language": "en"},
            "stage": 1,
            "mode": "resident",
            "pin": {"address": "TEST ONLY"},
        })
        assert response.status_code == 422
        response = client.post("/v1/ask", json={
            "utterance": {"text": "when is trash day", "language": "en"},
            "stage": 1,
            "mode": "resident",
        })
        assert response.status_code == 200
        IntentResolution.model_validate(response.json())


def test_resolution_round_trips_intent_goldens():
    root = Path(__file__).resolve().parents[2] / "contracts" / "intent"
    for path in root.glob("intent_resolution.*.json"):
        payload = json.loads(path.read_text(encoding="utf-8"))["value"]
        IntentResolution.model_validate(payload)


def _desk_only_cards():
    specs = {
        "visa_outcome": ("can I get a visa", "puedo obtener una visa", "mwen ka jwenn yon viza"),
        "clinic_price": ("free clinic", "clinica gratis", "klinik gratis"),
        "job": ("I need employment", "Necesito empleo", "M bezwen travay"),
        "appointment_slot": ("I want an appointment", "Quiero una cita", "Mwen bezwen yon randevou"),
        "school_bus_eligibility": ("school bus", "bus escolar", "bis lekòl"),
    }
    return [BundleCard.model_validate({
        "id": f"test-{topic.replace('_', '-')}",
        "title": {"es": "TEST-ONLY desk", "en": "TEST-ONLY desk", "ht": "TEST-ONLY desk"},
        "desk": f"us.test-{topic}-desk", "scope": "household", "stages": [1],
        "modes": ["resident", "tourist"], "region_pack": "us",
        "fact_refs": ["us.test.fee"], "topics": [topic],
        "utterances": {"en": [phrases[0]], "es": [phrases[1]], "ht": [phrases[2]]},
        "actions": [], "needs_review": {"es": True, "en": True, "ht": True},
        "immigration": topic == "visa_outcome",
    }) for topic, phrases in specs.items()]


@pytest.mark.parametrize(("text", "language", "topic"), [
    ("can I get a visa", "en", "visa_outcome"),
    ("puedo obtener una visa", "es", "visa_outcome"),
    ("mwen ka jwenn yon viza", "ht", "visa_outcome"),
    ("free clinic", "en", "clinic_price"),
    ("clinica gratis", "es", "clinic_price"),
    ("klinik gratis", "ht", "clinic_price"),
    ("I need employment", "en", "job"),
    ("Necesito empleo", "es", "job"),
    ("M bezwen travay", "ht", "job"),
    ("I want an appointment", "en", "appointment_slot"),
    ("Quiero una cita", "es", "appointment_slot"),
    ("Mwen bezwen yon randevou", "ht", "appointment_slot"),
    ("school bus", "en", "school_bus_eligibility"),
    ("bus escolar", "es", "school_bus_eligibility"),
    ("bis lekòl", "ht", "school_bus_eligibility"),
])
def test_endpoint_all_desk_only_topics_in_all_languages(make_harness, text, language, topic):
    harness = harness_with(make_harness, *_desk_only_cards())
    app = create_app(lambda: harness)
    with TestClient(app) as client:
        response = client.post("/v1/ask", json={
            "utterance": {"text": text, "language": language},
            "stage": 1,
            "mode": "resident",
        })
    body = response.json()
    assert response.status_code == 200
    assert body["grounding"]["type"] == "desk"
    assert body["grounding"]["reason"]["key"] == f"ask.reason.desk_only.{topic}"
    assert body["action"]["destination"]["type"] == "desk"
    assert body["action"]["destination"]["desk_id"].endswith(f"{topic}-desk")


def test_bus_and_trash_questions_still_ground_normally(make_harness):
    harness = make_harness()
    bus = BundleCard.model_validate({
        "id": "test-bus-route", "title": {"es": "TEST-ONLY bus", "en": "TEST-ONLY bus", "ht": "TEST-ONLY bus"},
        "desk": "us.test-transit-desk", "scope": "household", "stages": [1],
        "modes": ["resident"], "region_pack": "us", "fact_refs": ["us.test.fee"],
        "topics": ["transit"], "utterances": {"es": ["ruta de bus"], "en": ["bus route"], "ht": ["wout bis"]},
        "actions": [], "needs_review": {"es": True, "en": True, "ht": True}, "immigration": False,
    })
    from myad_server.harness import Harness
    harness = Harness.build(
        bundle=type(harness.deps.bundle)(cards={**harness.deps.bundle.cards, bus.id: bus},
                                        source=harness.deps.bundle.source, missing=False),
        ledger=harness.deps.ledger, now=harness.deps.now,
    )
    app = create_app(lambda: harness)
    with TestClient(app) as client:
        bus_response = client.post("/v1/ask", json={
            "utterance": {"text": "bus route", "language": "en"}, "stage": 1, "mode": "resident",
        })
        bus_alone_response = client.post("/v1/ask", json={
            "utterance": {"text": "bus", "language": "en"}, "stage": 1, "mode": "resident",
        })
        trash_response = client.post("/v1/ask", json={
            "utterance": {"text": "when is trash day", "language": "en"}, "stage": 1, "mode": "resident",
        })
    assert bus_response.status_code == bus_alone_response.status_code == trash_response.status_code == 200
    assert bus_response.json()["grounding"]["type"] == "card"
    assert bus_response.json()["grounding"]["card_id"] == "test-bus-route"
    bus_alone = bus_alone_response.json()
    assert not (bus_alone["grounding"] and bus_alone["grounding"].get("reason", {}).get("key") ==
                "ask.reason.desk_only.school_bus_eligibility")
    assert trash_response.json()["grounding"]["type"] == "card"
    assert trash_response.json()["grounding"]["card_id"] == "test-trash-day"
