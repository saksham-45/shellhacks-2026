"""Tourist visibility regressions using explicitly TEST-ONLY cards."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from myad_server.app import create_app
from myad_server.cards import BundleCard, CardError, CardBundle, parse_bundle
from myad_server.harness import Harness
from myad_server.visibility import IMMIGRATION_TOPICS, is_immigration_card


def _card(card_id: str, scope: str) -> BundleCard:
    return BundleCard.model_validate({
        "id": card_id,
        "title": {"es": "TEST-ONLY immigration", "en": "TEST-ONLY immigration", "ht": "TEST-ONLY immigration"},
        "desk": "us.test-immigration-desk", "scope": scope, "stages": [1, 7],
        "modes": ["tourist"], "region_pack": "us", "fact_refs": ["us.test.fee"],
        "topics": ["immigration"],
        "utterances": {"es": ["ayuda de inmigracion"], "en": ["immigration help"], "ht": ["ede imigrasyon"]},
        "actions": [], "needs_review": {"es": True, "en": True, "ht": True},
        "immigration": False,
    })


def _harness(make_harness, card: BundleCard):
    base = make_harness()
    return Harness.build(
        bundle=CardBundle(cards={card.id: card}, missing=False),
        ledger=base.deps.ledger,
        runtime=None,
        now=base.deps.now,
    )


def test_immigration_topic_set_is_validated_and_used():
    assert {"immigration", "tps", "visa", "asylum", "uscis", "status"}.issubset(IMMIGRATION_TOPICS)
    card = _card("test-topic-immigration", "person")
    assert is_immigration_card(card)


def test_bundle_rejects_topic_flag_mismatch():
    with pytest.raises(CardError, match="immigration topic requires immigration: true"):
        parse_bundle({
            "version": 1,
            "cards": [{
                "id": "test-bad-immigration", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
                "desk": "us.test-desk", "scope": "person", "stages": [1], "modes": ["tourist"],
                "region_pack": "us", "fact_refs": ["us.test.fee"], "topics": ["immigration"],
                "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
                "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
            }],
        })


def test_topic_immigration_card_has_no_tourist_claim_in_person_household_or_ask(make_harness):
    person = _harness(make_harness, _card("test-topic-person", "person"))
    household = _harness(make_harness, _card("test-topic-household", "household"))
    ask = _harness(make_harness, _card("test-topic-ask", "household"))

    person_body = {
        "person": {"person_id": "person-test-only", "age": 30, "origin_lenses": [], "stage": 1,
                    "mode": "tourist", "goal": "visit", "status_word": None},
        "surface_language": "en", "pin": {"address": "TEST-ONLY pin", "lat": 25.0, "lon": -80.0},
    }
    household_body = {"pin": {"address": "TEST-ONLY pin", "lat": 25.0, "lon": -80.0},
                      "surface_language": "en", "mode": "tourist"}
    ask_body = {"utterance": {"text": "immigration help", "language": "en"}, "stage": 1, "mode": "tourist"}

    with TestClient(create_app(lambda: person)) as client:
        person_response = client.post("/v1/person-next-steps", json=person_body)
    with TestClient(create_app(lambda: household)) as client:
        household_response = client.post("/v1/household-week", json=household_body)
    with TestClient(create_app(lambda: ask)) as client:
        ask_response = client.post("/v1/ask", json=ask_body)

    assert person_response.status_code == household_response.status_code == ask_response.status_code == 200
    assert person_response.json()["steps"] == []
    assert household_response.json()["items"] == []
    ask_data = ask_response.json()
    assert ask_data["action"] is None
    assert ask_data["grounding"] is None or ask_data["grounding"].get("card_id") != "test-topic-ask"
