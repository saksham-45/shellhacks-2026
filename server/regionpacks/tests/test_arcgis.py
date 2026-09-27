"""plan() URLs, domain decoding, parcel choice, and error-in-200 handling."""
import json

import pytest

from myad_regions import adapters as A
from myad_regions import arcgis as ag
from myad_regions.adapters import Ctx
from myad_regions.transport import Deadline
from myad_regions.types import Raw, Request, ResolvedPin

PIN = ResolvedPin(25.663194000003116, -80.41646700000167, "11200 SW 137th Ave, Miami, FL 33186", "device_coords")


def test_every_plan_uses_query_intersects_explicit_fields_never_identify():
    for a in A.registry().values():
        for req in a.plan(PIN):
            assert "/identify" not in req.url
            if "/query?" in req.url:
                assert "outFields=" in req.url and "outFields=%2A" not in req.url and "outFields=*" not in req.url
                if "geometry=" in req.url:
                    assert "spatialRel=esriSpatialRelIntersects" in req.url
                    assert "geometryType=esriGeometryPoint" in req.url


def test_point_query_url_rejects_star_and_identify():
    with pytest.raises(ValueError):
        ag.point_query_url("https://x/MapServer/0", 1, 2, ("*",))
    with pytest.raises(ValueError):
        ag.point_query_url("https://x/MapServer/identify", 1, 2, ("A",))


def test_parcel_never_requests_owner_or_mailing_fields():
    url = A.adapter("us-fl-miamidade.parcel").plan(PIN)[0].url
    assert "OWNER" not in url and "MAILING" not in url
    assert "distance=80" in url and "returnGeometry=true" in url


def test_domain_decoding_city_trashday():
    meta = {"fields": [{"name": "TRASHDAY", "domain": {"type": "codedValue", "codedValues": [
        {"name": "Tue", "code": "T"}, {"name": "Thu", "code": "R"}, {"name": "Tue and Fri", "code": "TF"},
        {"name": "Every Day", "code": "D"}]}}]}
    names = ag.domain(meta, "TRASHDAY")
    assert ag.days_from_domain_name(names["T"]) == ["tuesday"]
    assert ag.days_from_domain_name(names["R"]) == ["thursday"]
    assert ag.days_from_domain_name(names["TF"]) == ["tuesday", "friday"]
    with pytest.raises(ag.BadResponse):
        ag.days_from_domain_name(names["D"])  # unmapped on purpose, never guessed


def _raw(obj, url="https://gisweb.miamidade.gov/x/query?f=json", status=200):
    return Raw(Request(url), status, json.dumps(obj).encode(), "2026-09-25T17:19:00-04:00")


def test_error_inside_http_200_is_error():
    with pytest.raises(ag.BadResponse):
        ag.features(_raw({"error": {"code": 503, "message": "User couldn't access this resource"}}))
    with pytest.raises(ag.BadResponse):
        ag.parse_json(Raw(Request("https://x"), 200, b"<html>Request Rejected</html>", "2026-09-25T17:15:43-04:00"))


class Canned:
    live = False

    def __init__(self, bodies):
        self.bodies = bodies

    def fetch(self, req, deadline):
        for key, body in self.bodies.items():
            if key in req.url:
                return _raw(body, req.url)
        raise AssertionError("unexpected request")


def test_error_in_200_becomes_error_results_with_desk():
    a = A.adapter("us-fl-miami.trash-city")
    t = Canned({"/query?": {"error": {"code": 503}}, "?f=json": {"fields": []}})
    rs = a.run(Ctx(PIN, ("us", "us-fl", "us-fl-miamidade", "us-fl-miami")), t, Deadline(5))
    assert [(r.status, r.desk) for r in rs] == [("error", "us-fl-miami.solid-waste")]


def test_unmapped_trashday_code_is_error():
    a = A.adapter("us-fl-miami.trash-city")
    meta = {"fields": [{"name": "TRASHDAY", "domain": {"type": "codedValue", "codedValues": [{"name": "Every Day", "code": "D"}]}}]}
    t = Canned({"/query?": {"features": [{"attributes": {"OBJECTID": 1, "TRASHDAY": "D"}}]}, "?f=json": meta})
    rs = a.run(Ctx(PIN, ("us", "us-fl", "us-fl-miamidade", "us-fl-miami")), t, Deadline(5))
    assert rs[0].status == "error" and rs[0].value is None


def _square(lat, lon, half):
    return {"rings": [[[lon - half, lat - half], [lon + half, lat - half], [lon + half, lat + half],
                       [lon - half, lat + half], [lon - half, lat - half]]]}


# The street-interpolated U.S. Census point for 11200 SW 137th Ave (the demo pin before the switch to the
# county PointAddress). It falls ~20 m off the address's parcel, so plain "nearest" picks a neighbour there.
CENSUS_POINT = (25.663473322904, -80.416060788844)


def test_parcel_county_point_is_inside_its_own_parcel(fx):
    p = A.adapter("us-fl-miamidade.parcel")
    feats = ag.features(fx.fetch(p.plan(PIN)[0], Deadline(5)))
    a, lookup, d = p.choose(ResolvedPin(PIN.lat, PIN.lon, None, "device_coords"), feats)
    assert (a["FOLIO"], lookup, d) == ("3059100230010", "nearest_polygon", 0.0)
    a, lookup, _ = p.choose(PIN, feats)
    assert (a["FOLIO"], lookup) == ("3059100230010", "address_match")


def test_parcel_address_match_beats_nearest_off_parcel(fx):
    p = A.adapter("us-fl-miamidade.parcel")
    feats = ag.features(fx.fetch(p.plan(PIN)[0], Deadline(5)))
    a, lookup, d = p.choose(ResolvedPin(*CENSUS_POINT, PIN.address, "census_geocoder"), feats)
    assert (a["FOLIO"], lookup) == ("3059100230010", "address_match")
    nearest, lookup2, d2 = p.choose(ResolvedPin(*CENSUS_POINT, None, "census_geocoder"), feats)
    assert lookup2 == "nearest_polygon" and nearest["FOLIO"] != "3059100230010" and d2 < d


def test_year_built_zero_is_an_outcome_not_a_value():
    p = A.adapter("us-fl-miamidade.parcel")
    body = {"features": [{"attributes": {"FOLIO": "1", "TRUE_SITE_ADDR": "11200 SW 137 AVE", "CONDO_FLAG": "N",
                                         "YEAR_BUILT": 0, "DOR_DESC": "X"}, "geometry": _square(PIN.lat, PIN.lon, 0.0001)}]}
    rs = {r.fact_id: r for r in p.run(Ctx(PIN, ()), Canned({"/query?": body}), Deadline(5))}
    r = rs["us-fl-miamidade.parcel.year-built"]
    assert r.status == "not_applicable" and r.value is None
    assert r.not_applicable["reason"] == "regions.na.parcel-year-not-recorded"


def test_street_key():
    assert ag.street_key("11200 SW 137th Ave, Miami, FL 33186") == ag.street_key("11200 SW 137 AVE") == "11200 SW 137 AVE"
    assert ag.street_key("111 NW 1st St") == "111 NW 1 ST"
    assert ag.street_key(None) is None
