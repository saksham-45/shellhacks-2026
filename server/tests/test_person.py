"""Offline phase-1e person flow tests using explicitly TEST-ONLY data."""
from __future__ import annotations

import json
import logging
from pathlib import Path

from fastapi.testclient import TestClient
from pydantic import TypeAdapter, ValidationError
import pytest

from myad_server.app import create_app
from myad_server.cards import parse_bundle
from myad_server.models import PersonNextStepsRequest, PersonNextStepsResponse
from myad_server.values import FactValue

GOLDENS = Path(__file__).resolve().parents[2] / "contracts" / "v1"


class StubRuntime:
    def __init__(self, rows=None, error=None):
        self.rows = rows or []
        self.error = error
        self.calls = []

    def answer(self, pin, fact_ids=None, topics=None, timeout_s=20.0):
        self.calls.append((pin, fact_ids, topics, timeout_s))
        if self.error:
            raise self.error
        return self.rows


def row(*, fact_id="us-fl-miamidade.test.school", value=None, ledger_id=None, status="ok", **extra):
    demo = extra.pop("is_demo", bool(ledger_id and ".demo." in ledger_id))
    return {
        "fact_id": fact_id,
        "ledger_id": ledger_id or fact_id,
        "pack_id": fact_id.split(".", 1)[0],
        "status": status,
        "fact_status": "demo" if demo else "verified",
        "is_demo": demo,
        "value": value,
        "source_id": "us-fl-miamidade.test-source",
        "source_name": "TEST-ONLY fictional adapter",
        "url": "https://example.invalid/test-only",
        "retrieved_at": "2026-09-25T12:00:00-04:00",
        "quote": "TEST-ONLY fictional adapter result.",
        "jurisdiction": "us-fl-miamidade",
        "desk": "us-fl-miamidade.test-school-desk",
        **extra,
    }


def request(**updates):
    body = {
        "person": {
            "person_id": "person-test-only-a",
            "age": 30,
            "origin_lenses": [],
            "stage": 7,
            "mode": "resident",
            "goal": "study",
            "status_word": None,
        },
        "surface_language": "en",
        "pin": {"address": "TEST-ONLY person pin", "lat": 25.0, "lon": -80.0},
    }
    body.update(updates)
    return body


def app_for(make_harness, runtime, *, bundle=None):
    harness = make_harness()
    if bundle is not None:
        from myad_server.harness import Harness
        harness = Harness.build(bundle=bundle, ledger=harness.deps.ledger, runtime=runtime,
                                now=harness.deps.now)
    else:
        harness.runtime = runtime
    return create_app(lambda: harness)


def test_golden_request_decodes_and_response_has_golden_shape(make_harness):
    request_data = json.loads((GOLDENS / "person_next_steps.request.json").read_text())
    golden_response = json.loads((GOLDENS / "person_next_steps.response.json").read_text())
    PersonNextStepsRequest.model_validate(request_data)
    PersonNextStepsResponse.model_validate(golden_response)
    response = TestClient(app_for(make_harness, StubRuntime())).post("/v1/person-next-steps", json=request_data)
    assert response.status_code == 200
    decoded = PersonNextStepsResponse.model_validate(response.json())
    assert set(decoded.model_dump()) == set(golden_response)
    assert decoded.language == request_data["surface_language"]


def test_stage_mode_goal_selection_and_three_step_cap(make_harness, topics, ledger):
    # TEST-ONLY cards deliberately cover two stages and one tourist-ineligible paper card.
    base = json.loads((Path(__file__).parent / "fixtures" / "cards.json").read_text())
    base["cards"] = [c for c in base["cards"] if c["scope"] in ("person", "person-papers")]
    for i in range(3):
        base["cards"].append({
            "id": f"test-study-step-{i}", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
            "desk": "us-fl-miamidade.test-school-desk", "scope": "person", "stages": [7],
            "modes": ["resident"], "region_pack": "us-fl-miamidade", "fact_refs": ["us-fl-miamidade.test.school"],
            "topics": ["school"], "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
        })
    bundle = parse_bundle(base, topics)
    runtime = StubRuntime([row(value={"type": "place", "place": {"name": "TEST-ONLY school", "coordinate": {"latitude": 25.0, "longitude": -80.0}}})])
    response = TestClient(app_for(make_harness, runtime, bundle=bundle)).post("/v1/person-next-steps", json=request())
    assert response.status_code == 200
    data = response.json()
    assert len(data["steps"]) == 3
    assert all(step["card_id"] in {"test-school", "test-study-step-0", "test-study-step-1", "test-study-step-2"} for step in data["steps"])
    assert runtime.calls and runtime.calls[0][3] <= 20.0


def test_desk_only_topic_is_handoff(make_harness, topics, monkeypatch):
    # Desk-only card topics come from the ask policy (research topic ids); map a fixture-vocabulary
    # topic here so the test does not depend on which ids the policy owner has mapped so far.
    from myad_server import verifier
    monkeypatch.setattr(verifier, "DESK_ONLY_TOPICS", {"work": "job"})
    data = {
        "version": 1,
        "cards": [{
            "id": "test-job-card", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
            "desk": "us.test-desk", "scope": "person", "stages": [7], "modes": ["resident"],
            "region_pack": "us", "fact_refs": ["us.test.fee"], "topics": ["work"],
            "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
        }],
    }
    bundle = parse_bundle(data, topics)
    response = TestClient(app_for(make_harness, StubRuntime(), bundle=bundle)).post("/v1/person-next-steps", json=request())
    assert response.status_code == 200
    body = response.json()
    assert body["steps"] == []
    assert body["handoffs"][0]["desk_id"] == "us.test-desk"
    assert body["handoffs"][0]["reason"]["key"] == "handoff.reason.desk_only.job"


def test_missing_origin_fact_is_unavailable_desk(make_harness, topics):
    data = {
        "version": 1,
        "cards": [{
            "id": "lens-haiti-test", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
            "desk": "us.test-desk", "scope": "person", "stages": [7], "modes": ["resident"],
            "region_pack": "us", "fact_refs": ["us.test-only.missing-origin"], "topics": ["origin"],
            "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
        }],
    }
    bundle = parse_bundle(data)
    body = request()
    body["person"]["origin_lenses"] = ["haiti"]
    response = TestClient(app_for(make_harness, StubRuntime(), bundle=bundle)).post("/v1/person-next-steps", json=body)
    assert response.status_code == 200
    result = response.json()
    assert result["facts"]["us.test-only.missing-origin"]["type"] == "unavailable"
    assert result["handoffs"][0]["desk_id"] == "us.test-desk"


def test_unverifiable_claim_dropped(make_harness, topics):
    data = {
        "version": 1,
        "cards": [{
            "id": "test-unverifiable", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
            "desk": "us.test-desk", "scope": "person", "stages": [7], "modes": ["resident"],
            "region_pack": "us", "fact_refs": ["us.test.unsourced-thing"], "topics": ["study"],
            "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
        }],
    }
    bundle = parse_bundle(data)
    response = TestClient(app_for(make_harness, StubRuntime(), bundle=bundle)).post("/v1/person-next-steps", json=request())
    body = response.json()
    assert body["dropped_claims"] >= 1
    assert body["steps"] == []


def test_other_person_fields_and_papers_rejected(make_harness):
    client = TestClient(app_for(make_harness, StubRuntime()))
    body = request()
    body["person"]["papers"] = {"TEST-ONLY": True}
    assert client.post("/v1/person-next-steps", json=body).status_code == 422
    body = request()
    body["other_person"] = {"person_id": "person-test-only-b"}
    assert client.post("/v1/person-next-steps", json=body).status_code == 422


def test_person_data_never_appears_in_logs(make_harness, caplog):
    person_id = "UNIQUE-TEST-ONLY-PERSON-ID"
    body = request()
    body["person"]["person_id"] = person_id
    client = TestClient(app_for(make_harness, StubRuntime()))
    with caplog.at_level(logging.INFO):
        assert client.post("/v1/person-next-steps", json=body).status_code == 200
    assert person_id not in caplog.text
    assert "TEST-ONLY person pin" not in caplog.text


def _city_card(*, fact_id="us-fl-miami.test.rent-line", scope="person"):
    return {
        "id": "test-city-membership-card", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
        "desk": "us-fl-miami.test-desk", "scope": scope, "stages": [7], "modes": ["resident"],
        "region_pack": "us-fl-miami", "fact_refs": [fact_id], "topics": ["housing"],
        "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
        "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
    }


def test_no_pin_never_claims_city_static_fact(make_harness):
    bundle = parse_bundle({"version": 1, "cards": [_city_card()]})
    body = request()
    body.pop("pin")
    response = TestClient(app_for(make_harness, StubRuntime(), bundle=bundle)).post(
        "/v1/person-next-steps", json=body)
    assert response.status_code == 200
    data = response.json()
    assert data["steps"] == []
    assert not any("us-fl-miami" in ref["fact_id"]
                    for step in data["steps"] for claim in step["claims"] for ref in claim["fact_refs"])
    assert any(handoff["desk_id"] == "us-fl-miami.test-desk" for handoff in data["handoffs"])
    assert data["facts"]["us-fl-miami.test.rent-line"]["type"] == "unavailable"


def test_membership_unknown_never_claims_city_person(make_harness):
    bundle = parse_bundle({"version": 1, "cards": [_city_card()]})
    runtime = StubRuntime([row(fact_id="us-fl-miami.test.rent-line", value=None,
                                status="membership_unknown", pack="us-fl-miami")])
    response = TestClient(app_for(make_harness, runtime, bundle=bundle)).post(
        "/v1/person-next-steps", json=request())
    assert response.status_code == 200
    data = response.json()
    assert data["steps"] == []
    assert data["facts"]["us-fl-miami.test.rent-line"]["type"] == "unavailable"
    assert any(handoff["desk_id"] == "us-fl-miami.test-desk" for handoff in data["handoffs"])


def test_demo_labelling(make_harness, topics):
    data = {
        "version": 1,
        "cards": [{
            "id": "test-demo-card", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
            "desk": "us-fl-miamidade.test-desk", "scope": "person", "stages": [7], "modes": ["resident"],
            "region_pack": "us-fl-miamidade", "fact_refs": ["us-fl-miamidade.test.grocery-price"], "topics": ["study"],
            "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
        }],
    }
    bundle = parse_bundle(data)
    runtime = StubRuntime([row(fact_id="us-fl-miamidade.test.grocery-price",
                                value={"type": "money", "amount": 1.23, "currency": "USD"})])
    result = TestClient(app_for(make_harness, runtime, bundle=bundle)).post("/v1/person-next-steps", json=request())
    assert result.status_code == 200
    body = result.json()
    fact = body["facts"]["us-fl-miamidade.test.grocery-price"]["fact"]
    assert fact["is_demo"] is True
    assert body["has_demo"] is True
