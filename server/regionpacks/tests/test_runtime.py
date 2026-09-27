"""Entry point, pin step, resolution, parallel safety, timeouts, and result shape."""
import json
from concurrent.futures import ThreadPoolExecutor

import pytest

import runtime
from myad_regions import geocode
from myad_regions.pins import DEMO_PINS
from myad_regions.transport import Deadline, FixtureTransport
from myad_regions.types import PinInput, Raw, validate_result


class Spy:
    live = False

    def __init__(self, inner):
        self.inner, self.urls = inner, []

    def fetch(self, req, deadline):
        self.urls.append(req.url)
        return self.inner.fetch(req, deadline)


def test_resolve_pack_chains(fx, pin_a, pin_b):
    assert runtime.resolve(pin_a, transport=fx) == ["us", "us-fl", "us-fl-miamidade"]
    assert runtime.resolve(pin_b, transport=fx) == ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"]


def test_pin_with_coords_never_calls_geocoder(fx, pin_a):
    spy = Spy(fx)
    results = runtime.answer(pin_a, transport=spy)
    assert not [u for u in spy.urls if u.startswith((geocode.CENSUS, geocode.COUNTY_LOCATOR))]
    assert all(r["basis"]["method"] == "device_coords" for r in results)


@pytest.mark.parametrize("pin_id", ["pin-sw137", "pin-nw1st"])
def test_address_only_pin_uses_the_county_point_address(fx, pin_id):
    """The county locator's PointAddress is the demo pin itself, so every fixture URL matches."""
    pin = DEMO_PINS[pin_id]
    spy = Spy(fx)
    results = runtime.answer({"address": pin.address}, topics=["trash"], transport=spy)
    assert spy.urls[0].startswith(geocode.COUNTY_LOCATOR)
    assert not [u for u in spy.urls if u.startswith(geocode.CENSUS)]
    assert {r["basis"]["method"] for r in results} == {"county_locator"}
    assert results and {r["status"] for r in results} <= {"ok", "not_applicable"}  # nothing missed a fixture
    assert any(r["status"] == "ok" for r in results)
    rp = geocode.resolve_point(PinInput(address=pin.address, lat=None, lon=None), fx, Deadline(5))
    assert (rp.lat, rp.lon, rp.method) == (pin.lat, pin.lon, "county_locator")
    assert rp.evidence["url"] == geocode.county_locator_url(pin.address) and rp.evidence["retrieved_at"]


def _locator(candidates):
    return json.dumps({"candidates": candidates}).encode()


def _cand(kind, score, x, y):
    return {"address": "X", "location": {"x": x, "y": y}, "score": score, "attributes": {"Addr_type": kind, "Score": score}}


class Scripted:
    """County locator answers with `county` (bytes, or None for unreachable); Census answers from the fixture."""
    live = False

    def __init__(self, county, fx):
        self.county, self.fx, self.urls = county, fx, []

    def fetch(self, req, deadline):
        self.urls.append(req.url)
        if req.url.startswith(geocode.COUNTY_LOCATOR):
            if self.county is None:
                return Raw(req, None, b"", "2026-09-25T18:00:00-04:00", error="timed out", unreachable=True)
            return Raw(req, 200, self.county, "2026-09-25T18:00:00-04:00")
        return self.fx.fetch(req, deadline)


@pytest.mark.parametrize("county", [
    None,                                                           # county locator down
    _locator([]),                                                   # no candidates
    _locator([_cand("StreetAddress", 99.9, -80.1, 25.7)]),          # interpolated only: never used
    _locator([_cand("PointAddress", 90.0, -80.1, 25.7)]),           # PointAddress below the score floor
    b"<html>Request Rejected</html>",                               # non-JSON
])
def test_county_locator_falls_back_to_census(fx, pin_a, county):
    t = Scripted(county, fx)
    rp = geocode.resolve_point(PinInput(address=pin_a.address, lat=None, lon=None), t, Deadline(5))
    assert rp.method == "census_geocoder" and t.urls[1].startswith(geocode.CENSUS)
    assert (rp.lat, rp.lon) != (pin_a.lat, pin_a.lon)  # the saved Census point is the old interpolated one


def test_county_locator_takes_the_best_point_address():
    t = Scripted(_locator([_cand("StreetAddress", 99.9, -80.3, 25.3), _cand("PointAddress", 96.0, -80.2, 25.2),
                           _cand("PointAddress", 99.0, -80.1, 25.1)]), None)
    rp = geocode.resolve_point(PinInput(address="1 Main St, Miami, FL 33101", lat=None, lon=None), t, Deadline(5))
    assert (rp.lat, rp.lon, rp.method) == (25.1, -80.1, "county_locator") and len(t.urls) == 1


def test_geocoder_rejection_is_unavailable_not_raised():
    class Rejecting:
        live = False

        def fetch(self, req, deadline):
            return Raw(req, 200, b"<html><title>Request Rejected</title></html>", "2026-09-25T17:15:43-04:00")

    results = runtime.answer({"address": "11200 SW 137th Ave, Miami, FL 33186"}, topics=["trash"], transport=Rejecting())
    assert results and {r["status"] for r in results} == {"unavailable"}
    assert all(r["desk"] for r in results)
    assert not any("11200" in (r["error"] or "") for r in results)  # messages never carry the address


def test_every_result_is_valid_and_ids_are_declared(answers):
    from myad_regions.manifests import all_adapters
    declared = {f.id for a in all_adapters() for f in a.facts}
    for pin, res in answers.items():
        for fid, r in res.items():
            assert validate_result(r) == [], (pin, fid, validate_result(r))
            assert fid in declared
            if r["basis"].get("lookup") == "ledger":  # Fee Check: Research's own row, never a demo id
                assert r["is_demo"] is False and r["ledger_id"] == fid
            else:
                assert r["is_demo"] is True and r["ledger_id"] == f"{fid}.demo.{pin}"


def test_fact_ids_are_stable_across_pins(answers):
    a, b = answers["pin-sw137"], answers["pin-nw1st"]
    assert set(a) == set(b) - {"us-fl-miami.trash.day"}


def test_narrowing_by_fact_ids_and_topics(fx, pin_b):
    r = runtime.answer(pin_b, fact_ids=["us-fl-miami.trash.day"], transport=fx)
    assert [x["fact_id"] for x in r] == ["us-fl-miami.trash.day"]
    ids = {x["fact_id"] for x in runtime.answer(pin_b, topics=["parcel"], transport=fx)}
    assert ids == {"us-fl-miamidade.parcel.folio", "us-fl-miamidade.parcel.year-built",
                   "us-fl-miamidade.parcel.condo", "us-fl-miamidade.parcel.use"}


def test_parallel_matches_serial(fx):
    pins = list(DEMO_PINS.values()) * 4
    serial = [runtime.answer(p, transport=fx) for p in pins]
    with ThreadPoolExecutor(max_workers=8) as pool:
        parallel = list(pool.map(lambda p: runtime.answer(p, transport=fx), pins))
    strip = lambda rs: [{k: v for k, v in r.items() if not (k == "retrieved_at" and r["status"] in ("unsourced",))} for r in rs]
    assert [strip(x) for x in parallel] == [strip(x) for x in serial]


def test_timeout_is_clamped_and_expired_budget_returns_errors_not_raises(fx, pin_a):
    assert Deadline(999).budget == 20.0
    assert Deadline(-1).budget == 0.0
    results = runtime.answer(pin_a, timeout_s=0, transport=fx)
    assert results and all(r["status"] in ("unavailable", "unsourced") for r in results)
    assert all(r["desk"] for r in results)


def test_slow_source_times_out_as_unavailable(pin_b):
    import time

    class Slow:
        live = False

        def __init__(self):
            self.inner = FixtureTransport()

        def fetch(self, req, deadline):
            if "MD_Libraries" in req.url:
                time.sleep(min(deadline.remaining(), 3.0))
            return self.inner.fetch(req, deadline)

    t0 = time.monotonic()
    results = {r["fact_id"]: r for r in runtime.answer(pin_b, topics=["libraries", "trash"], timeout_s=0.5, transport=Slow())}
    assert time.monotonic() - t0 < 2.5
    assert results["us-fl-miamidade.library.nearest.1"]["status"] == "unavailable"
    assert results["us-fl-miami.trash.day"]["status"] == "ok"


def test_answer_question_most_local_wins(fx, pin_a, pin_b):
    qb = runtime.answer_question(pin_b, "trash.schedule", transport=fx)
    assert qb["owner"] == "us-fl-miami" and qb["results"][0]["value"]["days"] == ["tuesday"]
    qa = runtime.answer_question(pin_a, "trash.schedule", transport=fx)
    assert qa["owner"] == "us-fl-miamidade" and qa["passed_over"] == []


def test_missing_fixture_is_unavailable_with_desk(fx):
    results = runtime.answer(PinInput(address=None, lat=25.0, lon=-80.0), topics=["water"], transport=fx)
    assert results and {r["status"] for r in results} == {"unavailable"}
    assert {r["desk"] for r in results} == {"us-fl-miamidade.wasd"}


class Down:
    """Every source unreachable (HTTP 503), as in a full county outage."""
    live = False

    def fetch(self, req, deadline):
        return Raw(req, 503, b"", "2026-09-25T17:00:00-04:00", error="HTTP 503", unreachable=True)


def test_answer_question_keeps_desk_when_county_is_down(pin_a):
    for question, desk_prefix in (("trash.schedule", "us-fl-miamidade."), ("rent.line", "us-fl-miamidade.")):
        q = runtime.answer_question(pin_a, question, transport=Down())
        assert q["owner"] == "us-fl-miamidade", (question, q)
        assert q["membership_unknown"] is True
        assert q["results"] and all(r["status"] in ("unavailable", "unsourced") for r in q["results"])
        assert all(r["desk"] and r["desk"].startswith(desk_prefix) for r in q["results"])
        assert not any(r["pack"] == "us-fl-miami" for r in q["results"])


def test_answer_question_keeps_desk_when_geocoder_is_down():
    q = runtime.answer_question(PinInput(address="11200 SW 137th Ave, Miami, FL 33186", lat=None, lon=None),
                                "trash.schedule", transport=Down())
    assert q["owner"] == "us-fl-miamidade" and q["membership_unknown"] is True
    assert q["results"] and all(r["status"] == "unavailable" and r["desk"] for r in q["results"])


def test_answer_question_membership_known_in_fixture_mode(fx, pin_b):
    assert runtime.answer_question(pin_b, "trash.schedule", transport=fx)["membership_unknown"] is False
