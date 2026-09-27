"""Pure verifier tests using only obviously fake, TEST-ONLY ledger data."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from pydantic import TypeAdapter

from myad_server.adapter import AdapterResult
from myad_server.models import OFact, ODeferred, ONotApplicable, OUnavailable
from myad_server.values import FactRef, FactValue, Mode, StringKey
from myad_server.verifier import DraftClaim, VerifyContext, verify

from conftest import PROJECT_ROOT

_NOW = datetime(2026, 9, 25, 17, 0, tzinfo=timezone(timedelta(hours=-4)))
_CHAIN = ("us", "us-fl", "us-fl-miamidade")
_COUNTY = "us-fl-miamidade.test.trash-days"
_CITY = "us-fl-miami.test.trash-days"


def value(data: dict):
    return TypeAdapter(FactValue).validate_python(data)


def draft(fid: str, *, asserted=None, kind=None, topic=None, question=None, desk_id=None, immigration=False):
    return DraftClaim(
        card_id="test-card",
        copy_key=StringKey(key="test-only.copy", table="TEST-ONLY"),
        fact_refs=[FactRef.of(fid)],
        asserted=asserted or {},
        kind=kind,
        topic=topic,
        question=question,
        desk_id=desk_id,
        immigration=immigration,
    )


def result(fid: str, *, value_data=None, status="ok", ledger_id=None, pack=None, jurisdiction=None,
           url="https://example.invalid/test-only-result", retrieved_at="2026-09-25T12:00:00-04:00",
           quote="TEST FIXTURE ONLY; fictional adapter quote.", desk="us-fl-miamidade.test-desk",
           fact_status=None, is_demo=False, defer_to=None):
    is_demo = is_demo or fact_status == "demo" or bool(ledger_id and ".demo." in ledger_id)
    row = {
        "fact_id": fid,
        "ledger_id": ledger_id or fid,
        "pack_id": pack or fid.split(".", 1)[0],
        "status": status,
        "fact_status": fact_status,
        "is_demo": is_demo,
        "value": value_data,
        "source_id": "us-fl-miamidade.test-source",
        "source_name": "TEST-ONLY fictional adapter",
        "url": url,
        "retrieved_at": retrieved_at,
        "quote": quote,
        "jurisdiction": jurisdiction or fid.split(".", 1)[0],
        "desk": desk,
    }
    if defer_to is not None:
        row["not_applicable"] = {"reason": "TEST-ONLY fictional defer", "defer_to": defer_to}
    return AdapterResult.model_validate(row)


def context(ledger, results=(), *, chain=_CHAIN, mode=Mode.resident, pin_slug="pin-sw137", **kwargs):
    return VerifyContext(ledger=ledger, results=tuple(results), chain=tuple(chain), mode=mode, now=_NOW,
                         pin_slug=pin_slug, **kwargs)


def test_static_fact_positive_and_asserted_value_must_equal_ledger(ledger):
    fid = "us.test.fee"
    good = ledger.get(fid).typed_value
    verdict = verify([draft(fid, asserted={fid: good})], context(ledger))
    assert len(verdict.claims) == 1
    assert verdict.dropped == []


def test_static_value_mismatch_drops_claim(ledger):
    fid = "us.test.fee"
    wrong = value({"type": "money", "amount": "999", "currency": "USD"})
    verdict = verify([draft(fid, asserted={fid: wrong})], context(ledger))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "value_mismatch"


def test_unknown_fact_is_dropped(ledger):
    fid = "us.test.not-in-ledger"
    verdict = verify([draft(fid)], context(ledger))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "unknown_fact"


def test_lookup_requires_same_request_result_with_same_fact_id(ledger):
    good = {"type": "weekdays", "days": ["tuesday", "friday"]}
    verdict = verify([draft(_COUNTY)], context(ledger, [result(_CITY, value_data=good)]))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "no_lookup_evidence"


def test_lookup_positive_and_value_type_is_admitted(ledger):
    res = result(_COUNTY, value_data={"type": "weekdays", "days": ["tuesday", "friday"]})
    verdict = verify([draft(_COUNTY)], context(ledger, [res]))
    assert len(verdict.claims) == 1
    assert isinstance(verdict.facts[_COUNTY], OFact)


def test_lookup_type_mismatch_drops_claim(ledger):
    res = result(_COUNTY, value_data={"type": "text", "text": "TEST ONLY", "language": "en"})
    verdict = verify([draft(_COUNTY)], context(ledger, [res]))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "type_mismatch"


@pytest.mark.parametrize("missing", ["url", "retrieved_at", "quote"])
def test_ok_adapter_requires_url_retrieved_at_and_quote(ledger, missing):
    kwargs = {missing: ""}
    res = result(_COUNTY, value_data={"type": "weekdays", "days": ["monday"]}, **kwargs)
    verdict = verify([draft(_COUNTY)], context(ledger, [res]))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "adapter_error"


def test_ok_adapter_requires_offset_bearing_retrieved_at(ledger):
    res = result(_COUNTY, value_data={"type": "weekdays", "days": ["monday"]}, retrieved_at="2026-09-25T12:00:00")
    verdict = verify([draft(_COUNTY)], context(ledger, [res]))
    assert verdict.dropped[0].reason == "adapter_error"


def test_demo_result_uses_ledger_id_and_is_labelled(ledger):
    fid = "us-fl-miami.test.trash-days"
    res = result(fid, ledger_id=fid + ".demo.pin-sw137", fact_status="demo",
                 value_data={"type": "weekdays", "days": ["monday"]}, pack="us-fl-miami",
                 jurisdiction="us-fl-miami", desk="us-fl-miami.test-desk")
    verdict = verify([draft(fid)], context(ledger, [res], chain=(*_CHAIN, "us-fl-miami")))
    assert len(verdict.claims) == 1
    assert verdict.has_demo is True
    assert verdict.facts[fid].fact.is_demo is True


def test_explicit_demo_bit_with_live_ledger_id_is_never_verified(ledger):
    # Exact review regression: ok + is_demo=true + ledger_id=fact_id + valid value.
    fid = _COUNTY
    res = result(fid, is_demo=True, ledger_id=fid,
                 value_data={"type": "weekdays", "days": ["monday"]})
    verdict = verify([draft(fid)], context(ledger, [res]))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "contradictory_provenance"
    assert verdict.has_demo is False
    assert not isinstance(verdict.facts.get(fid), OFact)


def test_contradictory_demo_provenance_is_dropped(ledger):
    fid = _COUNTY
    res = result(fid, is_demo=True, fact_status="verified", ledger_id=fid,
                 value_data={"type": "weekdays", "days": ["monday"]})
    verdict = verify([draft(fid)], context(ledger, [res]))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "contradictory_provenance"
    assert verdict.has_demo is False


def test_demo_result_for_wrong_pin_is_dropped(ledger):
    fid = "us-fl-miami.test.trash-days"
    res = result(fid, ledger_id=fid + ".demo.pin-sw137", fact_status="demo",
                 value_data={"type": "weekdays", "days": ["monday"]}, pack="us-fl-miami",
                 jurisdiction="us-fl-miami", desk="us-fl-miami.test-desk")
    verdict = verify([draft(fid)], context(ledger, [res], chain=(*_CHAIN, "us-fl-miami"), pin_slug="pin-nw1st"))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "wrong_demo_pin"


def test_demo_result_value_must_equal_demo_ledger(ledger):
    fid = "us-fl-miami.test.trash-days"
    res = result(fid, ledger_id=fid + ".demo.pin-sw137", fact_status="demo",
                 value_data={"type": "weekdays", "days": ["sunday"]}, pack="us-fl-miami",
                 jurisdiction="us-fl-miami", desk="us-fl-miami.test-desk")
    verdict = verify([draft(fid)], context(ledger, [res], chain=(*_CHAIN, "us-fl-miami")))
    assert verdict.dropped[0].reason == "value_mismatch"


@pytest.mark.parametrize("status", ["not_applicable", "error", "unavailable"])
def test_non_ok_adapter_results_never_become_claims_and_handoff(ledger, status):
    res = result(_COUNTY, status=status, value_data=None)
    verdict = verify([draft(_COUNTY)], context(ledger, [res]))
    assert verdict.claims == []
    assert len(verdict.handoffs) == 1
    assert verdict.handoffs[0].desk_id == "us-fl-miamidade.test-desk"
    assert isinstance(verdict.facts.get(_COUNTY), (OUnavailable, ONotApplicable))


def test_not_applicable_defer_to_routes_to_target_desk(ledger):
    res = result(_COUNTY, status="not_applicable", value_data=None, desk="us-fl-miami.test-desk",
                 defer_to={"pack_id": "us-fl-miami", "fact_id": _CITY})
    verdict = verify([draft(_COUNTY)], context(ledger, [res], chain=(*_CHAIN, "us-fl-miami")))
    assert verdict.claims == []
    assert verdict.handoffs[0].desk_id == "us-fl-miami.test-desk"
    assert isinstance(verdict.facts[_COUNTY], ODeferred)


def test_jurisdiction_chain_drops_city_figure_at_unincorporated_pin(ledger):
    res = result(_CITY, value_data={"type": "weekdays", "days": ["monday"]}, pack="us-fl-miami",
                 jurisdiction="us-fl-miami", desk="us-fl-miami.test-desk")
    verdict = verify([draft(_CITY)], context(ledger, [res]))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "wrong_jurisdiction"


def test_city_figure_survives_when_chain_contains_city(ledger):
    res = result(_CITY, value_data={"type": "weekdays", "days": ["monday"]}, pack="us-fl-miami",
                 jurisdiction="us-fl-miami", desk="us-fl-miami.test-desk")
    verdict = verify([draft(_CITY)], context(ledger, [res], chain=(*_CHAIN, "us-fl-miami")))
    assert len(verdict.claims) == 1


def test_unanswered_question_uses_fact_desk_then_default_pack_desk(ledger):
    verdict = verify([], context(ledger, chain=_CHAIN, planned_questions=("trash.garbage.days",),
                             question_facts={"trash.garbage.days": _COUNTY}, default_desk="us.test-desk"))
    assert verdict.handoffs[0].desk_id == "us-fl-miamidade.test-desk"


def test_unanswered_question_falls_back_to_pack_default_desk(ledger):
    verdict = verify([], context(ledger, chain=_CHAIN, planned_questions=("TEST unanswered",),
                             default_desk="us.test-desk"))
    assert verdict.handoffs[0].desk_id == "us.test-desk"


@pytest.mark.parametrize("topic", ["visa outcome", "clinic price", "job", "appointment slot", "school-bus eligibility"])
def test_desk_only_topics_always_drop_and_handoff(ledger, topic):
    verdict = verify([draft("us.test.fee", topic=topic, desk_id="us.test-desk")], context(ledger))
    assert verdict.claims == []
    assert verdict.dropped[0].reason == "desk_only"
    assert verdict.handoffs[0].desk_id == "us.test-desk"


def test_school_bus_eligibility_uses_transportation_desk_when_declared(ledger):
    verdict = verify([draft("us.test.fee", kind="school_bus_eligibility",
                            desk_id="us-fl-miamidade.test-school-desk")], context(ledger))
    assert verdict.claims == []
    assert verdict.handoffs[0].desk_id == "us-fl-miamidade.test-school-desk"


def test_tourist_drops_immigration_without_claim_or_handoff(ledger):
    verdict = verify([draft("us.test.fee", immigration=True, desk_id="us.test-desk")],
                     context(ledger, mode=Mode.tourist))
    assert verdict.claims == []
    assert verdict.handoffs == []
    assert verdict.dropped[0].reason == "tourist_immigration"


def test_resident_may_ground_same_immigration_fact(ledger):
    verdict = verify([draft("us.test.fee", immigration=True)], context(ledger, mode=Mode.resident))
    assert len(verdict.claims) == 1


def test_desk_handoff_contacts_only_displayable_ledger_facts(ledger):
    verdict = verify([draft(_COUNTY)], context(ledger, [result(_COUNTY, value_data=None, status="error")]))
    contacts = {r.fact_id for r in verdict.handoffs[0].contact}
    assert "us-fl-miamidade.test-desk.name" in contacts
    assert "us-fl-miamidade.test-desk.phone" in contacts
    assert "us-fl-miamidade.test-desk.hours" not in contacts


# ---- B1 (verifier half): the desk-only card-topic backstop names only real research topics ----------------


def test_desk_only_topics_named_by_policy_exist_in_research_topics():
    from myad_server import verifier
    from myad_server.topics import load_topics

    vocab = load_topics(PROJECT_ROOT / "research" / "topics.yaml")
    assert vocab, "research/topics.yaml must exist"
    missing = sorted(set(verifier.DESK_ONLY_TOPICS) - vocab)
    assert not missing, f"desk-only topics not in research/topics.yaml: {missing}"
    assert set(verifier.DESK_ONLY_TOPICS.values()) <= set(verifier.DESK_ONLY_KINDS)
    # The loader itself enforces the same rule at start-up.
    assert verifier.load_desk_only_topics(vocab=vocab) == dict(verifier.DESK_ONLY_TOPICS)


def test_desk_only_topic_loader_rejects_a_topic_missing_from_the_vocabulary(tmp_path):
    from myad_server.verifier import load_desk_only_topics

    policy = tmp_path / "policy.yaml"
    policy.write_text("desk_only:\n  - id: job\n    all_of: ['x']\n    topics: [no-such-topic]\n")
    assert load_desk_only_topics(policy) == {"no-such-topic": "job"}
    with pytest.raises(ValueError, match="no-such-topic"):
        load_desk_only_topics(policy, vocab=frozenset({"work", "health"}))
    policy.write_text("desk_only:\n  - id: not-a-kind\n    topics: [work]\n")
    with pytest.raises(ValueError, match="unknown desk-only kind"):
        load_desk_only_topics(policy)


def test_card_with_a_mapped_desk_only_topic_hands_off_and_never_grounds(ledger, monkeypatch):
    from myad_server import verifier
    from myad_server.cards import parse_bundle

    monkeypatch.setattr(verifier, "DESK_ONLY_TOPICS", {"health": "clinic_price"})
    bundle = parse_bundle({"version": 1, "cards": [{
        "id": "test-card", "title": {"es": "TEST", "en": "TEST", "ht": "TEST"}, "desk": "us.test-clinic-desk",
        "scope": "household", "stages": [1], "modes": ["resident"], "region_pack": "us",
        "fact_refs": ["us.test.fee"], "topics": ["health"], "utterances": {"es": [], "en": [], "ht": []},
        "actions": [], "needs_review": {"es": True, "en": True, "ht": True}, "immigration": False}]})
    card = bundle.cards["test-card"]
    v = verify([draft("us.test.fee")], context(ledger, cards={"test-card": card}))
    assert v.claims == [] and v.dropped[0].reason == "desk_only"
    assert v.handoffs[0].reason.key == "handoff.reason.desk_only.clinic_price"
    assert verifier.grounding_facts(card, ledger, _NOW) == []
    monkeypatch.setattr(verifier, "DESK_ONLY_TOPICS", {})
    assert verifier.grounding_facts(card, ledger, _NOW)
