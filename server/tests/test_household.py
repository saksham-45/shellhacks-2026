"""Offline household-week tests; the Regions seam is replaced with a same-signature stub."""
from __future__ import annotations

import json
import logging
from pathlib import Path

from fastapi.testclient import TestClient
from pydantic import TypeAdapter

from myad_server.adapter import AdapterResult
from myad_server.app import create_app
from myad_server.models import HouseholdWeekRequest, HouseholdWeekResponse

GOLDENS = Path(__file__).resolve().parents[2] / "contracts" / "v1"
PIN = {"address": "1 TEST-ONLY Way, Fictiontown", "lat": 25.0, "lon": -80.0}
FID = "us-fl-miamidade.test.trash-days"


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


def row(*, value=None, ledger_id=None, status="ok", pack="us-fl-miamidade", fact_id=FID, **extra):
    demo = extra.pop("is_demo", bool(ledger_id and ".demo." in ledger_id))
    return {
        "fact_id": fact_id,
        "ledger_id": ledger_id or fact_id,
        "pack_id": pack,
        "status": status,
        "fact_status": "demo" if demo else "verified",
        "is_demo": demo,
        "value": value,
        "source_id": "us-fl-miamidade.test-source",
        "source_name": "TEST-ONLY fictional adapter",
        "url": "https://example.invalid/test-only",
        "retrieved_at": "2026-09-25T12:00:00-04:00",
        "quote": "TEST-ONLY fictional adapter result.",
        "jurisdiction": pack,
        "desk": "us-fl-miamidade.test-desk",
        "basis": {"method": "device_coords"},
        **extra,
    }


def request(**extra):
    body = {"pin": PIN, "surface_language": "es", "mode": "resident"}
    body.update(extra)
    return body


def app_for(make_harness, runtime):
    h = make_harness()
    h.runtime = runtime
    return create_app(lambda: h)


def test_golden_request_and_response_shape(make_harness):
    request_data = json.loads((GOLDENS / "household_week.request.json").read_text())
    response_data = json.loads((GOLDENS / "household_week.response.json").read_text())
    HouseholdWeekRequest.model_validate(request_data)
    HouseholdWeekResponse.model_validate(response_data)
    client = TestClient(app_for(make_harness, StubRuntime()))
    response = client.post("/v1/household-week", json=request_data)
    assert response.status_code == 200
    HouseholdWeekResponse.model_validate(response.json())


def test_device_coords_basis_and_demo_label(make_harness):
    runtime = StubRuntime([row(value={"type": "weekdays", "days": ["tuesday", "friday"]},
                               ledger_id=FID + ".demo.pin-test1")])
    response = TestClient(app_for(make_harness, runtime)).post("/v1/household-week", json=request())
    assert response.status_code == 200
    data = response.json()
    fact = data["facts"][FID]["fact"]
    assert fact["basis"] == {"method": "device_coords"}
    assert data["has_demo"] is True
    assert fact["is_demo"] is True
    assert runtime.calls[0][0] == PIN
    assert runtime.calls[0][3] <= 20.0


def test_missing_adapter_provenance_is_dropped_at_endpoint(make_harness):
    bad = row(value={"type": "weekdays", "days": ["monday"]})
    for key in ("ledger_id", "is_demo", "fact_status"):
        bad.pop(key)
    response = TestClient(app_for(make_harness, StubRuntime([bad]))).post(
        "/v1/household-week", json=request())
    assert response.status_code == 200
    data = response.json()
    assert data["dropped_claims"] >= 1
    assert data["facts"].get(FID, {}).get("type") != "fact"
    # The trash card cites only the malformed row; national-fact cards need no adapter row (B4).
    assert not any(item["card_id"] == "test-trash-day" for item in data["items"])
    assert not any(ref["fact_id"] == FID for item in data["items"] for claim in item["claims"]
                   for ref in claim["fact_refs"])


def test_timeout_becomes_desk_unavailable(make_harness):
    response = TestClient(app_for(make_harness, StubRuntime(error=TimeoutError()))).post(
        "/v1/household-week", json=request())
    assert response.status_code == 200
    data = response.json()
    assert data["facts"][FID]["type"] == "unavailable"
    assert any(h["desk_id"] == "us-fl-miamidade.test-desk" for h in data["handoffs"])


def test_membership_unknown_never_claims_city(make_harness):
    # The fixture bundle has no city card; this explicit adapter row exercises the same invariant
    # with a small replacement bundle in the runtime result boundary.
    runtime = StubRuntime([row(fact_id="us-fl-miami.test.trash-days", pack="us-fl-miami",
                               value={"type": "weekdays", "days": ["monday"]},
                               membership_unknown=True)])
    response = TestClient(app_for(make_harness, runtime)).post("/v1/household-week", json=request())
    assert response.status_code == 200
    data = response.json()
    assert not any(item["claims"] and any("us-fl-miami" in ref["fact_id"]
                                           for ref in item["claims"][0]["fact_refs"])
                   for item in data["items"])


def test_membership_unknown_suppresses_city_static_fact(make_harness):
    bundle = {
        "version": 1,
        "cards": [{
            "id": "test-city-household-membership", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"},
            "desk": "us-fl-miami.test-desk", "scope": "household", "stages": [1],
            "modes": ["resident"], "region_pack": "us-fl-miami",
            "fact_refs": ["us-fl-miami.test.rent-line"], "topics": ["housing"],
            "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": False, "en": False, "ht": False}, "immigration": False,
        }],
    }
    from myad_server.cards import parse_bundle
    runtime = StubRuntime([row(fact_id="us-fl-miami.test.rent-line", pack="us-fl-miami",
                               status="membership_unknown", value=None)])
    harness = make_harness()
    from myad_server.harness import Harness
    harness = Harness.build(bundle=parse_bundle(bundle), ledger=harness.deps.ledger,
                            runtime=runtime, now=harness.deps.now)
    response = TestClient(create_app(lambda: harness)).post("/v1/household-week", json=request())
    assert response.status_code == 200
    data = response.json()
    assert data["items"] == []
    assert data["facts"]["us-fl-miami.test.rent-line"]["type"] == "unavailable"
    assert any(handoff["desk_id"] == "us-fl-miami.test-desk" for handoff in data["handoffs"])


def test_unverifiable_claim_is_dropped(make_harness):
    runtime = StubRuntime([row(value={"type": "text", "text": "TEST wrong", "language": "en"})])
    response = TestClient(app_for(make_harness, runtime)).post("/v1/household-week", json=request())
    assert response.status_code == 200
    data = response.json()
    assert data["dropped_claims"] >= 1
    assert not any(item["card_id"] == "test-trash-day" for item in data["items"])


def test_extra_fields_rejected(make_harness):
    client = TestClient(app_for(make_harness, StubRuntime()))
    assert client.post("/v1/household-week", json=request(extra_field="TEST-ONLY")).status_code == 422


def test_pin_and_address_never_appear_in_logs(make_harness, caplog):
    address = "UNIQUE-TEST-ONLY-ADDRESS-DO-NOT-LOG"
    client = TestClient(app_for(make_harness, StubRuntime(error=TimeoutError())))
    with caplog.at_level(logging.INFO):
        response = client.post("/v1/household-week", json=request(pin={"address": address, "lat": 0, "lon": 0}))
    assert response.status_code == 200
    assert address not in caplog.text
    assert "25.0" not in caplog.text
