"""Opt-in live checks (MYAD_LIVE=1). They assert structure, not frozen values. Skipped by default."""
import os

import pytest

pytestmark = pytest.mark.skipif(os.environ.get("MYAD_LIVE") != "1", reason="live tests need MYAD_LIVE=1")


def _reachable(url: str) -> str | None:
    import urllib.request
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "myAD-regions-test"}), timeout=10) as r:
            body = r.read(2000)
            if b"Request Rejected" in body or b"<html" in body.lower():
                return "the service answered with a reject page from this network"
            return None
    except Exception as e:  # noqa: BLE001
        return f"unreachable from this network ({type(e).__name__})"


def test_live_county_answers_have_shape():
    import runtime
    from myad_regions.pins import DEMO_PINS
    from myad_regions.transport import LiveTransport
    from myad_regions.types import validate_result
    why = _reachable("https://gisweb.miamidade.gov/arcgis/rest/services?f=json")
    if why:
        pytest.skip(f"gisweb.miamidade.gov: {why}")
    for p in DEMO_PINS.values():
        res = runtime.answer(p, topics=["municipality", "trash", "schools"], transport=LiveTransport())
        assert res
        for r in res:
            assert validate_result(r) == []
            assert r["is_demo"] is False and r["ledger_id"] == r["fact_id"]


def test_live_city_of_miami_trash():
    why = _reachable("https://gis.miami.gov/gis/rest/services/SolidWaste/TrashRoutes/MapServer/0?f=json")
    if why:
        pytest.skip(f"gis.miami.gov: {why}")
    import runtime
    from myad_regions.pins import DEMO_PINS
    from myad_regions.transport import LiveTransport
    r = runtime.answer(DEMO_PINS["pin-nw1st"], fact_ids=["us-fl-miami.trash.day"], transport=LiveTransport())
    assert r and r[0]["status"] in ("ok", "not_applicable", "error", "unavailable")


def test_live_census_geocoder():
    from myad_regions.geocode import geocode_url
    why = _reachable(geocode_url("111 NW 1st St, Miami, FL 33128"))
    if why:
        pytest.skip(f"geocoding.geo.census.gov: {why}")
    import runtime
    from myad_regions.transport import LiveTransport
    assert "us-fl-miamidade" in runtime.resolve({"address": "111 NW 1st St, Miami, FL 33128"}, transport=LiveTransport())
