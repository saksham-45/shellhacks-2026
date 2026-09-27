"""Most local wins (REVIEW r3 B3) plus the adapter-boundary fixes M1, M2, M3 and M6.

The demo-pin tests read the REAL research ledger (read-only) with a same-signature Regions stub whose
rows mirror the shape Regions returns for the two demo pins (CONTRACT §2, §5). Row values are copied
from the ledger's own demo entries, never typed here, and the verifier re-checks them against the
ledger. If Research has no trash fact for a pin, the only correct answer is the right desk, so the
tests assert that instead of a day. Everything else uses the TEST-ONLY fixtures.
"""
from __future__ import annotations

import copy
import json
import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from myad_server.app import create_app
from myad_server.cards import parse_bundle
from myad_server.harness import Harness
from myad_server.ledger import load_ledger
from myad_server.topics import load_topics

from conftest import FIXTURES, NOW, PROJECT_ROOT

RESEARCH = PROJECT_ROOT / "research"
PIN = {"address": "1 TEST-ONLY Way, Fictiontown", "lat": 25.0, "lon": -80.0}
FID = "us-fl-miamidade.test.trash-days"
WEEKDAYS = {"type": "weekdays", "days": ["tuesday", "friday"]}
BOUNDARY = "us-fl-miamidade.government.municipality"

CITY_TRASH = "us-fl-miami.trash.day"
COUNTY_TRASH = "us-fl-miamidade.trash.garbage-days"
CITY_DESK = "us-fl-miami.solid-waste"
COUNTY_DESK = "us-fl-miamidade.dswm"
# Demo pins (research/facts/pins.json). Coordinates are sent, so no geocoding is implied.
PINS = {
    "pin-sw137": {"address": "11200 SW 137th Ave, Miami, FL 33186", "lat": 25.663194, "lon": -80.416467},
    "pin-nw1st": {"address": "111 NW 1st St, Miami, FL 33128", "lat": 25.775604, "lon": -80.196669},
}


class StubRuntime:
    """Same signature as regionpacks/runtime.py (answer only); returns fixed rows."""

    def __init__(self, rows=None, error=None):
        self.rows = rows or []
        self.error = error
        self.calls = []

    def answer(self, pin, fact_ids=None, topics=None, timeout_s=20.0):
        self.calls.append((pin, fact_ids, topics, timeout_s))
        if self.error:
            raise self.error
        return copy.deepcopy(self.rows)


def row(*, value=None, ledger_id=None, status="ok", pack="us-fl-miamidade", fact_id=FID, **extra):
    demo = extra.pop("is_demo", bool(ledger_id and ".demo." in ledger_id))
    r = {
        "fact_id": fact_id, "ledger_id": ledger_id or fact_id, "pack_id": pack, "status": status,
        "fact_status": "demo" if demo else "verified", "is_demo": demo, "value": value,
        "source_id": "us-fl-miamidade.test-source", "source_name": "TEST-ONLY fictional adapter",
        "url": "https://example.invalid/test-only", "retrieved_at": "2026-09-25T12:00:00-04:00",
        "quote": "TEST-ONLY fictional adapter result.", "jurisdiction": pack,
        "desk": "us-fl-miamidade.test-desk", "basis": {"method": "device_coords"},
    }
    r.update(extra)
    return r


def client(bundle, ledger, runtime, now=NOW):
    h = Harness.build(bundle=bundle, ledger=ledger, now=lambda: now, runtime=runtime)
    return TestClient(create_app(lambda: h))


def week(c, pin=PIN, mode="resident"):
    r = c.post("/v1/household-week", json={"pin": pin, "surface_language": "en", "mode": mode})
    assert r.status_code == 200, r.text
    return r.json()


def claimed(data) -> set[str]:
    items = data.get("items", data.get("steps", []))
    return {ref["fact_id"] for it in items for c in it["claims"] for ref in c["fact_refs"]}


def card(cid, fact_refs, topics, *, desk, pack, scope="household", stages=(1,), modes=("resident", "tourist")):
    return {"id": cid, "title": {"es": "TEST", "en": "TEST", "ht": "TEST"}, "desk": desk, "scope": scope,
            "stages": list(stages), "modes": list(modes), "region_pack": pack, "fact_refs": list(fact_refs),
            "topics": list(topics), "utterances": {"es": [], "en": [], "ht": []}, "actions": [],
            "needs_review": {"es": True, "en": True, "ht": True}, "immigration": False}


# ---- real ledger, both demo pins ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def real_topics():
    return load_topics(RESEARCH / "topics.yaml")


@pytest.fixture(scope="module")
def real_ledger(real_topics):
    return load_ledger(RESEARCH / "facts", RESEARCH / "sources.yaml", real_topics)


def _trash_bundle(topics, *, desk):
    # One bundle serves every pin, so the trash card lists the city and the county answer.
    return parse_bundle({"version": 1, "cards": [
        card("test-only-trash", [CITY_TRASH, COUNTY_TRASH], ["trash"], desk=desk, pack="us-fl-miamidade"),
    ]}, topics)


def _demo_row(ledger, fid, pin_slug, *, pack, desk, source_id):
    """An ok Regions fixture row whose value/url/quote are copied from the ledger's demo entry."""
    entry = ledger.get(f"{fid}.demo.{pin_slug}")
    if entry is None or entry.typed_value is None:
        return None
    r = entry.raw
    return {"fact_id": fid, "ledger_id": entry.id, "pack": pack, "status": "ok", "is_demo": True,
            "value": entry.typed_value.model_dump(mode="json"), "source_id": source_id,
            "url": r.url, "retrieved_at": r.retrieved_at, "quote": r.quote, "jurisdiction": pack,
            "desk": desk, "basis": {"method": "device_coords"}}


def _boundary_row(ledger, pin_slug):
    b = _demo_row(ledger, BOUNDARY, pin_slug, pack="us-fl-miamidade", desk="us-fl-miamidade.311",
                  source_id="us-fl-miamidade.gis-municipality")
    return [b] if b else []


def _source(ledger, fid, fallback):
    f = ledger.get(fid)
    return (f.raw.source_id if f else None) or fallback


@pytest.mark.parametrize("card_desk", [COUNTY_DESK, CITY_DESK])
def test_sw137_unincorporated_claims_county_trash_and_never_a_city_desk(real_ledger, real_topics, card_desk):
    rows = _boundary_row(real_ledger, "pin-sw137")
    county = _demo_row(real_ledger, COUNTY_TRASH, "pin-sw137", pack="us-fl-miamidade", desk=COUNTY_DESK,
                       source_id=_source(real_ledger, COUNTY_TRASH, "us-fl-miamidade.gis-garbage-route"))
    rows += [county] if county else []
    data = week(client(_trash_bundle(real_topics, desk=card_desk), real_ledger, StubRuntime(rows)),
                PINS["pin-sw137"])

    assert "us-fl-miami" not in data["pack_ids"]
    assert not [k for k in data["facts"] if k.startswith("us-fl-miami.")]
    assert not [h["desk_id"] for h in data["handoffs"] if h["desk_id"].startswith("us-fl-miami.")]
    assert not [c["desk_id"] for it in data["items"] for c in it["claims"]
                if (c["desk_id"] or "").startswith("us-fl-miami.")]
    if county is not None:
        assert data["facts"][COUNTY_TRASH]["type"] == "fact"
        assert claimed(data) == {COUNTY_TRASH}
        assert data["facts"][COUNTY_TRASH]["fact"]["is_demo"] is True
    else:  # no trash fact for this place: the county desk, never a made-up day
        assert claimed(data) == set()
        assert any(h["desk_id"].startswith("us-fl-miamidade.") for h in data["handoffs"])


def test_sw137_county_layer_down_hands_off_county_desk_not_city(real_ledger, real_topics):
    rows = _boundary_row(real_ledger, "pin-sw137") + [
        {"fact_id": COUNTY_TRASH, "ledger_id": COUNTY_TRASH, "pack": "us-fl-miamidade", "status": "unavailable",
         "is_demo": False, "value": None, "jurisdiction": "us-fl-miamidade", "desk": COUNTY_DESK,
         "source_id": "us-fl-miamidade.gis-garbage-route", "url": "https://example.invalid/test-only",
         "retrieved_at": "2026-09-25T12:00:00-04:00", "error": "timed out"}]
    data = week(client(_trash_bundle(real_topics, desk=CITY_DESK), real_ledger, StubRuntime(rows)),
                PINS["pin-sw137"])
    assert claimed(data) == set()
    assert data["facts"][COUNTY_TRASH] == {"type": "unavailable", "fact_id": COUNTY_TRASH, "desk_id": COUNTY_DESK}
    desks = [h["desk_id"] for h in data["handoffs"]]
    assert COUNTY_DESK in desks and not [d for d in desks if d.startswith("us-fl-miami.")]
    handoff = next(h for h in data["handoffs"] if h["desk_id"] == COUNTY_DESK)
    assert handoff["contact"], "the county desk handoff must carry its verified contact facts"


def _nw1st_rows(ledger, *, city: str):
    rows = _boundary_row(ledger, "pin-nw1st") + [{
        "fact_id": COUNTY_TRASH, "ledger_id": f"{COUNTY_TRASH}.demo.pin-nw1st", "pack": "us-fl-miamidade",
        "status": "not_applicable", "is_demo": True, "value": None, "jurisdiction": "us-fl-miamidade",
        "desk": COUNTY_DESK, "source_id": "us-fl-miamidade.gis-garbage-route",
        "url": "https://example.invalid/test-only", "retrieved_at": "2026-09-25T12:00:00-04:00",
        "not_applicable": {"reason": "regions.na.county-trash-not-serviced",
                           "defer_to": {"pack_id": "us-fl-miami", "fact_id": CITY_TRASH}}}]
    city_row = _demo_row(ledger, CITY_TRASH, "pin-nw1st", pack="us-fl-miami", desk=CITY_DESK,
                         source_id=_source(ledger, CITY_TRASH, "us-fl-miami.gis-trash-routes"))
    if city == "ok" and city_row is not None:
        rows.append(city_row)
    elif city == "unavailable":
        rows.append({"fact_id": CITY_TRASH, "ledger_id": CITY_TRASH, "pack": "us-fl-miami", "status": "unavailable",
                     "is_demo": False, "value": None, "jurisdiction": "us-fl-miami", "desk": CITY_DESK,
                     "source_id": "us-fl-miami.gis-trash-routes", "url": "https://example.invalid/test-only",
                     "retrieved_at": "2026-09-25T12:00:00-04:00", "error": "timed out"})
    return rows, city_row


def test_nw1st_county_defers_to_city_and_the_city_fact_is_claimed(real_ledger, real_topics):
    rows, city_row = _nw1st_rows(real_ledger, city="ok")
    data = week(client(_trash_bundle(real_topics, desk=COUNTY_DESK), real_ledger, StubRuntime(rows)),
                PINS["pin-nw1st"])
    deferred = data["facts"][COUNTY_TRASH]
    assert deferred["type"] == "deferred"
    assert deferred["defer_to"] == {"pack_id": "us-fl-miami", "fact_id": CITY_TRASH}
    if city_row is not None:
        assert data["facts"][CITY_TRASH]["type"] == "fact"
        assert claimed(data) == {CITY_TRASH}     # the county ref is deferred, not claimed
        assert data["dropped_claims"] == 0
    else:  # no city trash fact in the ledger: the city desk, never a made-up day
        assert claimed(data) == set()
        assert any(h["desk_id"] == CITY_DESK for h in data["handoffs"])


@pytest.mark.parametrize("city", ["missing", "unavailable"])
def test_nw1st_deferred_without_city_answer_hands_off_to_city_desk(real_ledger, real_topics, city):
    rows, _ = _nw1st_rows(real_ledger, city=city)
    data = week(client(_trash_bundle(real_topics, desk=COUNTY_DESK), real_ledger, StubRuntime(rows)),
                PINS["pin-nw1st"])
    assert claimed(data) == set()
    assert data["dropped_claims"] == 1          # dropped and counted, never silent
    handoff = next((h for h in data["handoffs"] if h["desk_id"] == CITY_DESK), None)
    assert handoff is not None, data["handoffs"]
    assert handoff["contact"], "the city desk handoff must carry its verified contact facts"
    for ref in handoff["contact"]:
        assert data["facts"][ref["fact_id"]]["type"] == "fact"
    # The county figure is never used in place of the city's own answer.
    assert data["facts"][COUNTY_TRASH]["type"] == "deferred"


# ---- verifier-level rules on the TEST-ONLY fixture ledger ---------------------------------------------------


def _fixture_bundle(topics, *cards):
    return parse_bundle({"version": 1, "cards": list(cards)}, topics)


CITY_FID = "us-fl-miami.test.trash-days"


def test_city_ref_outside_chain_is_skipped_and_county_ref_answers(ledger, topics):
    b = _fixture_bundle(topics, card("test-only-both", [CITY_FID, FID], ["trash"], desk="us-fl-miami.test-desk",
                                     pack="us-fl-miamidade"))
    data = week(client(b, ledger, StubRuntime([row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1")])))
    assert claimed(data) == {FID}
    assert data["items"][0]["claims"][0]["desk_id"] is None       # the card's city desk does not serve this pin
    assert not [h for h in data["handoffs"] if h["desk_id"].startswith("us-fl-miami.")]


def test_city_only_card_outside_chain_goes_to_a_county_desk(ledger, topics):
    b = _fixture_bundle(topics, card("test-only-city", ["us-fl-miami.test.rent-line"], ["housing"],
                                     desk="us-fl-miami.test-desk", pack="us-fl-miami"))
    data = week(client(b, ledger, StubRuntime([row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1")])))
    assert data["items"] == []
    assert data["dropped_claims"] == 1
    assert [h["desk_id"] for h in data["handoffs"]] == ["us-fl-miamidade.test-desk"]


def test_not_applicable_without_target_passes_to_a_less_local_answer(ledger, topics):
    # County says "not here" with no defer_to; the national figure in the same claim still answers.
    b = _fixture_bundle(topics, card("test-only-pass", [FID, "us.test.fee"], ["trash"],
                                     desk="us-fl-miamidade.test-desk", pack="us-fl-miamidade"))
    rows = [row(status="not_applicable", value=None, ledger_id=FID + ".demo.pin-test1",
                not_applicable={"reason": "TEST-ONLY not here", "defer_to": None})]
    data = week(client(b, ledger, StubRuntime(rows)))
    assert claimed(data) == {"us.test.fee"}
    assert data["facts"][FID]["type"] == "not_applicable"


# ---- M3: one unavailable county layer is not a membership problem ------------------------------------------


def test_one_county_layer_unavailable_keeps_other_county_answers(bundle, ledger):
    rows = [row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1"),
            row(fact_id="us-fl-miamidade.test.year-built", status="unavailable", value=None,
                ledger_id="us-fl-miamidade.test.year-built")]
    data = week(client(bundle, ledger, StubRuntime(rows)))
    assert data["facts"][FID]["type"] == "fact"
    assert FID in claimed(data)
    assert "us-fl-miamidade" in data["pack_ids"]


@pytest.mark.parametrize("status", ["unavailable", "error"])
def test_boundary_layer_failure_makes_membership_unknown(bundle, ledger, status):
    rows = [row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1"),
            row(fact_id=BOUNDARY, status=status, value=None, ledger_id=BOUNDARY)]
    data = week(client(bundle, ledger, StubRuntime(rows)))
    assert FID not in claimed(data)
    assert data["facts"][FID]["type"] == "unavailable"
    assert data["pack_ids"] == ["us", "us-fl"]
    assert BOUNDARY not in data["facts"]               # asked for membership only, never shown


def test_boundary_fact_is_always_requested(bundle, ledger):
    runtime = StubRuntime([row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1")])
    week(client(bundle, ledger, runtime))
    assert BOUNDARY in runtime.calls[0][1]


# ---- M1: Regions' unsourced status ------------------------------------------------------------------------


def test_unsourced_row_becomes_unsourced_outcome_with_desk(bundle, ledger):
    r = row(status="unsourced", value=None)
    for key in ("url", "retrieved_at", "quote", "source_id"):
        r[key] = None
    data = week(client(bundle, ledger, StubRuntime([r])))
    assert data["facts"][FID] == {"type": "unsourced", "fact_id": FID, "desk_id": "us-fl-miamidade.test-desk"}
    assert any(h["desk_id"] == "us-fl-miamidade.test-desk" for h in data["handoffs"])


# ---- M2: one malformed row is skipped and counted ---------------------------------------------------------


@pytest.mark.parametrize("patch", [
    {"fact_id": "us-fl-miamidade.test.Trash-Days", "ledger_id": "us-fl-miamidade.test.Trash-Days.demo.pin-test1"},
    {"source_language": "e"},
    {"source_language": "not a tag"},
    {"source_id": "us-fl-miamidade." + "x" * 200},
    {"pack_id": "us-fl-miami"},
    {"not_applicable": {"reason": "x", "defer_to": {"pack_id": "US", "fact_id": "bad"}}, "status": "not_applicable",
     "value": None},
])
def test_malformed_row_is_skipped_counted_and_never_a_503(bundle, ledger, patch):
    good = row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1")
    bad = {**good, **patch}
    alone = week(client(bundle, ledger, StubRuntime([bad])))
    assert FID not in claimed(alone) and alone["dropped_claims"] >= 1
    if "fact_id" in patch:  # a bad sibling row never takes the good row down with it
        both = week(client(bundle, ledger, StubRuntime([good, bad])))
        assert FID in claimed(both) and both["dropped_claims"] >= 1


def test_wirefact_shape_error_in_verifier_is_an_adapter_error_not_a_crash(ledger):
    from myad_server.adapter import AdapterResult
    from myad_server.values import FactRef, Mode, StringKey
    from myad_server.verifier import DraftClaim, VerifyContext, verify
    # Bypass parse_results on purpose: the verifier must still refuse a result WireFact rejects.
    res = AdapterResult.model_validate(row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1",
                                           source_id="us-fl-miamidade." + "x" * 200))
    verdict = verify([DraftClaim(card_id="c", copy_key=StringKey(key="k", table="T"), fact_refs=[FactRef.of(FID)])],
                     VerifyContext(ledger=ledger, results=(res,), chain=("us", "us-fl", "us-fl-miamidade"),
                                   mode=Mode.resident, now=NOW, pin_slug="pin-test1"))
    assert verdict.claims == [] and verdict.dropped[0].reason == "adapter_error"


# ---- M6: tourist evidence goes through visibility.py ------------------------------------------------------


def test_tourist_household_evidence_never_admits_immigration_fact(tmp_path, topics, bundle):
    shutil.copytree(FIXTURES / "research", tmp_path / "research")
    facts_path = tmp_path / "research" / "facts" / "test.json"
    facts = json.loads(facts_path.read_text())
    facts.append({"id": "us.test.uscis-fee", "claim": "TEST-ONLY immigration fee", "status": "verified",
                  "value": 99, "value_type": "money", "unit": "USD", "jurisdiction": "us",
                  "topics": ["immigration"], "source_id": "us.test-source", "url": "https://example.invalid/imm",
                  "quote": "TEST FIXTURE - not a real quote.", "retrieved_at": "2026-09-20T12:00:00-04:00",
                  "check_every": "P3650D"})
    facts_path.write_text(json.dumps(facts))
    led = load_ledger(tmp_path / "research" / "facts", tmp_path / "research" / "sources.yaml", topics)
    imm = row(fact_id="us.test.uscis-fee", pack="us", value={"type": "money", "amount": 99, "currency": "USD"},
              source_id="us.test-source")
    rows = [row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1"), imm]
    tourist = week(client(bundle, led, StubRuntime(rows)), mode="tourist")
    assert "us.test.uscis-fee" not in tourist["facts"]
    assert FID in tourist["facts"]                      # ordinary evidence is still admitted

    # A card that cites the immigration-topic fact is dropped in tourist mode, even without the card flag.
    b = _fixture_bundle(topics, card("test-only-hidden", ["us.test.uscis-fee"], ["municipality"],
                                     desk="us.test-desk", pack="us"))
    hidden = week(client(b, led, StubRuntime(rows)), mode="tourist")
    assert hidden["items"] == [] and "us.test.uscis-fee" not in hidden["facts"]
    assert week(client(b, led, StubRuntime(rows)), mode="resident")["items"]


def test_evidence_is_limited_to_requested_fact_ids(bundle, ledger):
    extra = row(fact_id="us-fl-miamidade.test.school", value={"type": "place", "place": {
        "name": "TEST-ONLY school", "coordinate": {"latitude": 25.0, "longitude": -80.0}}},
        ledger_id="us-fl-miamidade.test.school")
    data = week(client(bundle, ledger, StubRuntime([row(value=WEEKDAYS, ledger_id=FID + ".demo.pin-test1"), extra])))
    assert "us-fl-miamidade.test.school" not in data["facts"]   # no household card asked for it
