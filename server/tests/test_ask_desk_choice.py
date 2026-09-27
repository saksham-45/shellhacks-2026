"""/v1/ask desk choice by jurisdiction (review r3, M4) and reply_language for regional tags (M9).
TEST-ONLY ledgers, cards and wording."""
from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from myad_server.app import create_app
from myad_server.ask.desks import DeskScope
from myad_server.ask.language import reply_language
from myad_server.ask.policy import load_policy
from myad_server.ask.ranker import StubRanker
from myad_server.ask.resolve import resolve_intent
from myad_server.cards import BundleCard
from myad_server.intent import AskRequest

PROJECT_ROOT = Path(__file__).resolve().parents[2]
COUNTY = ["us", "us-fl", "us-fl-miamidade"]
CITY = ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"]


def request(text: str, language: str = "en", mode: str = "resident") -> AskRequest:
    return AskRequest.model_validate({"utterance": {"text": text, "language": language}, "mode": mode})


def stub_ledger(**status_by_fact: str):
    """Only what desk choice reads: fact ids and their status. TEST-ONLY ids."""
    return SimpleNamespace(facts={fid: SimpleNamespace(raw=SimpleNamespace(status=s)) for fid, s in status_by_fact.items()})


# ---- M4: generic desk ----------------------------------------------------------------------------------

def test_no_answer_desk_is_the_county_when_jurisdiction_is_unknown(make_harness):
    h = make_harness()
    # The fixture ledger has City and County desks; the City one sorts first alphabetically.
    assert sorted(["us-fl-miamidade.test-desk", "us-fl-miami.test-desk"])[0] == "us-fl-miami.test-desk"
    result = resolve_intent(request("zzqx TEST-ONLY nonsense"), h.deps.bundle, h.deps.ledger, StubRanker(), h.deps.policy)
    assert result.grounding.type == "desk" and result.action is None
    assert result.grounding.desk_id == "us-fl-miamidade.test-desk"


@pytest.mark.parametrize(("chain", "desk"), [
    (None, "us-fl-miamidade.test-desk"),
    ([], "us-fl-miamidade.test-desk"),
    (["us"], "us-fl-miamidade.test-desk"),               # county layer unreadable: still the county
    (["us", "us-fl"], "us-fl-miamidade.test-desk"),
    (COUNTY, "us-fl-miamidade.test-desk"),               # unincorporated: never the City
    (CITY, "us-fl-miami.test-desk"),                      # inside the City: its own desk
])
def test_no_answer_desk_follows_the_resolved_jurisdiction(make_harness, chain, desk):
    h = make_harness()
    result = resolve_intent(request("zzqx TEST-ONLY nonsense"), h.deps.bundle, h.deps.ledger, StubRanker(),
                            h.deps.policy, jurisdiction=chain)
    assert result.grounding.desk_id == desk


def test_declared_generic_desk_wins_over_alphabetical_order():
    ledger = stub_ledger(**{
        "us-fl-miamidade.aaa-first.name": "verified",
        "us-fl-miamidade.311.phone": "verified",
        "us-fl-miami.311.name": "verified",
        "us-fl-miami.aaa.name": "verified",
        "us-fl.bbb.name": "verified",
    })
    policy = load_policy()
    assert DeskScope(policy, ledger).generic() == "us-fl-miamidade.311"
    assert DeskScope(policy, ledger, COUNTY).generic() == "us-fl-miamidade.311"
    assert DeskScope(policy, ledger, CITY).generic() == "us-fl-miami.311"


def test_unverified_generic_desk_is_skipped_and_city_is_never_the_fallback():
    ledger = stub_ledger(**{
        "us-fl-miamidade.311.name": "unsourced",
        "us-fl-miamidade.parks.name": "verified",
        "us-fl-miami.311.name": "verified",
    })
    scope = DeskScope(load_policy(), ledger)
    assert scope.generic() == "us-fl-miamidade.parks"
    assert not scope.allows("us-fl-miami.311") and scope.allows("us-fl.anything") and scope.allows("us.anything")


def test_no_desk_at_all_gives_the_empty_resolution():
    policy = load_policy()
    result = resolve_intent(request("zzqx TEST-ONLY nonsense"), {}, stub_ledger(), StubRanker(), policy)
    assert result.grounding is None and result.action is None and result.confidence == 0.0


def _city_clinic_card() -> BundleCard:
    return BundleCard.model_validate({
        "id": "test-city-free-clinic", "title": {"es": "TEST-ONLY", "en": "TEST-ONLY", "ht": "TEST-ONLY"},
        "desk": "us-fl-miami.test-desk", "scope": "household", "stages": [1], "modes": ["resident", "tourist"],
        "region_pack": "us-fl-miami", "fact_refs": ["us.test.fee"], "topics": ["health"],
        "utterances": {"es": [], "en": ["free clinic downtown"], "ht": []}, "actions": [],
        "needs_review": {"es": True, "en": True, "ht": True}, "immigration": False,
    })


@pytest.mark.parametrize(("chain", "desk"), [(None, "us-fl-miamidade.test-desk"), (COUNTY, "us-fl-miamidade.test-desk"),
                                              (CITY, "us-fl-miami.test-desk")])
def test_desk_only_handoff_never_names_a_city_desk_outside_the_city(make_harness, chain, desk):
    h = make_harness()
    cards = {**h.deps.bundle.cards, "test-city-free-clinic": _city_clinic_card()}
    result = resolve_intent(request("free clinic downtown"), cards, h.deps.ledger, StubRanker(), h.deps.policy,
                            jurisdiction=chain)
    assert result.grounding.reason.key == "ask.reason.desk_only.clinic_price"
    assert result.grounding.desk_id == desk and result.action.destination.desk_id == desk


def test_endpoint_no_answer_desk_is_not_a_city_desk(make_harness):
    with TestClient(create_app(lambda: make_harness())) as client:
        body = client.post("/v1/ask", json={"utterance": {"text": "zzqx TEST-ONLY nonsense", "language": "en"},
                                            "mode": "resident"}).json()
    assert body["grounding"]["desk_id"] == "us-fl-miamidade.test-desk"


def test_policy_jurisdictions_mirror_the_regions_manifests():
    manifests = sorted((PROJECT_ROOT / "server" / "regionpacks").glob("*/manifest.json"))
    if not manifests:
        pytest.skip("Regions manifests not present")
    j = load_policy().jurisdictions
    for path in manifests:
        m = json.loads(path.read_text(encoding="utf-8"))
        assert m["id"] in j.parents, f"{m['id']} missing from ask_policy.yaml jurisdictions"
        assert j.parents[m["id"]] == m.get("parent") and j.levels[m["id"]] == m.get("level"), m["id"]
    assert j.levels[j.unknown] == "county"


# ---- M9: reply_language --------------------------------------------------------------------------------

@pytest.mark.parametrize(("tag", "expected"), [
    ("es", "es"), ("en", "en"), ("ht", "ht"), ("es-US", "es"), ("es-419", "es"), ("ht-HT", "ht"),
    ("en-GB", "en"), ("ES-us", "es"), ("fr-CA", "en"), ("fr", "en"),
])
def test_reply_language_maps_regional_tags_to_the_base_language(tag, expected):
    assert reply_language(tag) == expected


@pytest.mark.parametrize(("text", "tag", "expected"), [
    ("cuándo pasa la basura", "es-US", "es"),       # card
    ("¿Me aprueban la visa?", "es-419", "es"),      # desk-only
    ("kilè kamyon fatra a pase", "ht-HT", "ht"),    # card
    ("zzqx TEST-ONLY", "ht-HT", "ht"),              # no answer
])
def test_endpoint_reply_language_for_regional_tags(make_harness, text, tag, expected):
    with TestClient(create_app(lambda: make_harness())) as client:
        body = client.post("/v1/ask", json={"utterance": {"text": text, "language": tag}, "mode": "resident"}).json()
    assert body["reply_language"] == expected
