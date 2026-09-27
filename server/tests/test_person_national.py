"""National and state facts need no address (REVIEW r3 B4), and the person golden is reproducible."""
from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from myad_server.app import create_app
from myad_server.cards import load_bundle, parse_bundle
from myad_server.harness import Harness
from myad_server.ledger import load_ledger
from myad_server.models import PersonNextStepsResponse
from myad_server.topics import load_topics

from conftest import FIXTURES, NOW, PROJECT_ROOT

GOLDENS = PROJECT_ROOT / "contracts" / "v1"
GOLDEN_FIXTURES = FIXTURES / "golden"
RESEARCH = PROJECT_ROOT / "research"
PIN = {"address": "1 TEST-ONLY Way, Fictiontown", "lat": 25.0, "lon": -80.0}


class StubRuntime:
    def __init__(self, rows=None):
        self.rows = rows or []
        self.calls = []

    def answer(self, pin, fact_ids=None, topics=None, timeout_s=20.0):
        self.calls.append(fact_ids)
        return list(self.rows)


def _card(cid, fact_refs, *, desk, pack, topics=("work",), stages=(1,), modes=("resident",), scope="person"):
    return {"id": cid, "title": {"es": "TEST", "en": "TEST", "ht": "TEST"}, "desk": desk, "scope": scope,
            "stages": list(stages), "modes": list(modes), "region_pack": pack, "fact_refs": list(fact_refs),
            "topics": list(topics), "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": True, "en": True, "ht": True}, "immigration": False}


def _post(bundle, ledger, body, runtime=None):
    h = Harness.build(bundle=bundle, ledger=ledger, now=lambda: NOW, runtime=runtime)
    r = TestClient(create_app(lambda: h)).post("/v1/person-next-steps", json=body)
    assert r.status_code == 200, r.text
    return r.json()


def _body(pin=None, stage=1, goal="work"):
    body = {"person": {"person_id": "p-test-only", "stage": stage, "mode": "resident", "goal": goal},
            "surface_language": "en"}
    if pin is not None:
        body["pin"] = pin
    return body


def _claimed(data):
    return {ref["fact_id"] for s in data["steps"] for c in s["claims"] for ref in c["fact_refs"]}


def test_person_golden_response_is_reproduced_exactly():
    topics = load_topics(FIXTURES / "research" / "topics.yaml")
    ledger = load_ledger(GOLDEN_FIXTURES / "research" / "facts", GOLDEN_FIXTURES / "research" / "sources.yaml",
                         topics)
    bundle = load_bundle(GOLDEN_FIXTURES / "cards.json", topics)
    request = json.loads((GOLDENS / "person_next_steps.request.json").read_text())
    golden = json.loads((GOLDENS / "person_next_steps.response.json").read_text())
    assert request["pin"] is None
    data = _post(bundle, ledger, request, runtime=StubRuntime())
    assert data == golden
    PersonNextStepsResponse.model_validate(golden)


@pytest.mark.parametrize("pin", [None, PIN])
def test_national_static_fact_claimed_with_or_without_regions_rows(ledger, topics, pin):
    b = parse_bundle({"version": 1, "cards": [_card("test-only-national", ["us.test.fee"], desk="us.test-desk",
                                                    pack="us")]}, topics)
    runtime = StubRuntime([])
    data = _post(b, ledger, _body(pin), runtime=runtime)
    assert _claimed(data) == {"us.test.fee"}
    assert data["handoffs"] == [] and data["dropped_claims"] == 0
    assert bool(runtime.calls) is (pin is not None)   # no pin, no address lookup


def test_local_fact_without_pin_is_still_never_claimed_but_the_handoff_has_contacts(ledger, topics):
    b = parse_bundle({"version": 1, "cards": [
        _card("test-only-city", ["us-fl-miami.test.rent-line"], desk="us-fl-miami.test-desk", pack="us-fl-miami",
              topics=("housing",))]}, topics)
    data = _post(b, ledger, _body())
    assert data["steps"] == []
    handoff = next(h for h in data["handoffs"] if h["desk_id"] == "us-fl-miami.test-desk")
    contact = {ref["fact_id"] for ref in handoff["contact"]}
    assert contact == {"us-fl-miami.test-desk.name", "us-fl-miami.test-desk.phone"}
    for fid in contact:
        assert data["facts"][fid]["type"] == "fact"


def test_real_ledger_national_and_state_facts_without_pin(topics):
    real_topics = load_topics(RESEARCH / "topics.yaml")
    real = load_ledger(RESEARCH / "facts", RESEARCH / "sources.yaml", real_topics)
    national, state = "us.uscis.forms-free", "us-fl.flhsmv.fee.id-card-original"
    present = [fid for fid in (national, state) if real.get(fid) is not None and real.get(fid).status == "verified"]
    if not present:
        pytest.skip("research ledger has neither probe fact as verified")
    cards = [_card(f"test-only-{i}", [fid], desk=f"{fid.split('.')[0]}.test-only-desk", pack=fid.split(".")[0],
                   topics=("license",)) for i, fid in enumerate(present)]
    data = _post(parse_bundle({"version": 1, "cards": cards}, real_topics), real,
                 {**_body(), "pin": None})
    assert _claimed(data) == set(present)
