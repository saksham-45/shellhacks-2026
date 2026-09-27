"""Every adapter's parse over the saved fixtures for both pins (expected values from the live captures)."""
import pytest

MD = "us-fl-miamidade"


def val(ans, pin, fid):
    r = ans[pin][fid]
    assert r["status"] == "ok", (fid, r["status"], r["error"], r["not_applicable"])
    return r["value"]


def test_municipality(answers):
    assert val(answers, "pin-sw137", f"{MD}.government.municipality") == {"type": "code", "code": "UNINCORPORATED MIAMI-DADE"}
    assert val(answers, "pin-sw137", f"{MD}.government.municipality-id")["code"] == "30"
    assert val(answers, "pin-nw1st", f"{MD}.government.municipality")["code"] == "MIAMI"
    assert val(answers, "pin-nw1st", f"{MD}.government.municipality-id")["code"] == "01"


def test_county_trash_pin_a(answers):
    assert val(answers, "pin-sw137", f"{MD}.trash.garbage-days") == {"type": "weekdays", "days": ["tuesday", "friday"]}
    assert val(answers, "pin-sw137", f"{MD}.trash.recycling-day")["days"] == ["friday"]
    assert val(answers, "pin-sw137", f"{MD}.trash.recycling-week") == {"type": "code", "code": "A"}


def test_county_trash_pin_b_defers_to_city(answers):
    for fid in (f"{MD}.trash.garbage-days", f"{MD}.trash.recycling-day", f"{MD}.trash.recycling-week"):
        r = answers["pin-nw1st"][fid]
        assert r["status"] == "not_applicable"
        assert r["value"] is None
        assert r["not_applicable"] == {"reason": "regions.na.county-trash-not-serviced",
                                       "defer_to": {"pack_id": "us-fl-miami", "fact_id": "us-fl-miami.trash.day"}}
        assert r["desk"] == f"{MD}.dswm"


def test_city_trash_decodes_T_from_layer_domain(answers):
    r = answers["pin-nw1st"]["us-fl-miami.trash.day"]
    assert r["value"] == {"type": "weekdays", "days": ["tuesday"]}
    assert "TRASHDAY: T" in r["quote"] and '"Tue"' in r["quote"]


@pytest.mark.parametrize("pin,level,name,grades,phone", [
    ("pin-sw137", "elementary", "Claude Pepper Elementary", "PK-5", "3053865244"),
    ("pin-sw137", "middle", "Arvida Middle", "6-8", None),
    ("pin-sw137", "high", "Miami Sunset Senior High", "9-12", None),
    ("pin-nw1st", "elementary", "Frederick Douglass Elementary", "K-5", "3053714687"),
    ("pin-nw1st", "middle", "Jose De Diego Middle", "6-8", "3055737229"),
    ("pin-nw1st", "high", "Booker T. Washington Senior High", "9-12", "3053248900"),
])
def test_schools(answers, pin, level, name, grades, phone):
    place = val(answers, pin, f"{MD}.school.{level}")
    assert place["type"] == "place" and place["place"]["name"] == name
    c = place["place"]["coordinate"]
    assert isinstance(c["latitude"], float) and isinstance(c["longitude"], float) and place["place"]["address"]
    assert val(answers, pin, f"{MD}.school.{level}.grades") == {"type": "code", "code": grades}
    if phone:
        assert val(answers, pin, f"{MD}.school.{level}.phone") == {"type": "phone", "digits": phone}
    for suffix in ("", ".phone", ".grades"):
        r = answers[pin][f"{MD}.school.{level}{suffix}"]
        assert r["desk"] == f"{MD}.m-dcps-transportation"
    assert answers[pin][f"{MD}.school.{level}"]["basis"]["distance_m"] > 0  # straight-line only


@pytest.mark.parametrize("pin,folio,year", [("pin-sw137", "3059100230010", 1990), ("pin-nw1st", "0141370230020", 1984)])
def test_parcel(answers, pin, folio, year):
    assert val(answers, pin, f"{MD}.parcel.folio") == {"type": "code", "code": folio}
    assert val(answers, pin, f"{MD}.parcel.year-built") == {"type": "quantity", "amount": year, "unit": "year"}
    assert val(answers, pin, f"{MD}.parcel.condo") == {"type": "flag", "value": False}
    assert "CONDO_FLAG: N" in answers[pin][f"{MD}.parcel.condo"]["quote"]
    assert answers[pin][f"{MD}.parcel.folio"]["basis"]["lookup"] == "address_match"


def test_utilities(answers):
    for pin in ("pin-sw137", "pin-nw1st"):
        assert val(answers, pin, f"{MD}.utility.water") == {"type": "code", "code": "MDWS"}
        assert val(answers, pin, f"{MD}.utility.sewer") == {"type": "code", "code": "MDWS"}



@pytest.mark.parametrize("pin,flood,evac", [("pin-sw137", "X", "D"), ("pin-nw1st", "X", "B")])
def test_flood_and_evacuation_zones_at_the_county_point(answers, pin, flood, evac):
    """Values match myAD Research's verified ledger (us.fema.flood-zone, us-fl-miamidade.storm.evacuation-zone)."""
    r = answers[pin]["us.fema.flood-zone"]
    assert val(answers, pin, "us.fema.flood-zone") == {"type": "code", "code": flood}
    assert r["pack"] == "us" and r["desk"] == "us.fema-nfip" and r["source_id"] == "us.fema.nfhl"
    assert r["url"].startswith("https://hazards.fema.gov/") and r["retrieved_at"] and "SFHA_TF: F" in r["quote"]
    e = answers[pin][f"{MD}.storm.evacuation-zone"]
    assert val(answers, pin, f"{MD}.storm.evacuation-zone") == {"type": "code", "code": evac}
    assert e["desk"] == f"{MD}.311" and e["url"].startswith("https://gisweb.miamidade.gov/") and e["retrieved_at"]

def test_nearest_places(answers):
    assert val(answers, "pin-sw137", f"{MD}.parks.nearest-county.1")["place"]["name"] == "CAMP MATECUMBE"
    assert val(answers, "pin-sw137", f"{MD}.library.nearest.1")["place"]["name"] == "West Kendall Regional"
    assert val(answers, "pin-nw1st", f"{MD}.parks.nearest-municipal.1")["place"]["name"] == "Paul S Walker Park"
    assert val(answers, "pin-nw1st", f"{MD}.library.nearest.1")["place"]["name"] == "Main Library"
    # nearest park overall at pin B is the municipal one
    pb = answers["pin-nw1st"]
    assert pb[f"{MD}.parks.nearest-municipal.1"]["basis"]["distance_m"] < pb[f"{MD}.parks.nearest-county.1"]["basis"]["distance_m"]
    for n in (1, 2, 3):  # no municipal park within 3 km of pin A: an outcome, not a guess
        r = answers["pin-sw137"][f"{MD}.parks.nearest-municipal.{n}"]
        assert r["status"] == "not_applicable" and r["not_applicable"]["reason"] == "regions.na.none-within-radius"
    d = [answers["pin-nw1st"][f"{MD}.library.nearest.{n}"]["basis"]["distance_m"] for n in (1, 2, 3)]
    assert d == sorted(d)


@pytest.mark.parametrize("pin,expected", [
    ("pin-sw137", {"county-commission": "11", "congress": "28", "state-senate": "40", "state-house": "119", "school-board": "7"}),
    ("pin-nw1st", {"county-commission": "5", "congress": "27", "state-senate": "36", "state-house": "109", "school-board": "2"}),
])
def test_districts(answers, pin, expected):
    for slug, district in expected.items():
        assert val(answers, pin, f"{MD}.rep.{slug}.district") == {"type": "code", "code": district}
        assert val(answers, pin, f"{MD}.rep.{slug}.member")["type"] == "code"


def test_vote(answers):
    assert val(answers, "pin-sw137", f"{MD}.vote.precinct")["code"] == "792"
    pp = answers["pin-sw137"][f"{MD}.vote.polling-place"]
    assert pp["value"]["type"] == "place" and "where=PRECINCT%3D792" in pp["url"]


def test_transit(answers):
    assert val(answers, "pin-sw137", f"{MD}.transit.nearest-stop.1")["place"]["name"] == "SW 137 AV @ SW 112 ST"
    assert "stop_id 3296" in answers["pin-sw137"][f"{MD}.transit.nearest-stop.1"]["quote"]
    assert val(answers, "pin-sw137", f"{MD}.transit.nearest-stop.1.routes") == {"type": "codes", "codes": ["137"]}
    r = answers["pin-sw137"][f"{MD}.transit.nearest-stop.1"]
    assert r["url"] == "http://www.miamidade.gov/transit/googletransit/current/google_transit.zip"


def test_rent_pin_a_is_county_unsourced_and_no_city_facts(answers):
    ra = answers["pin-sw137"]
    r = ra[f"{MD}.rent.line"]
    assert r["status"] == "unsourced" and r["desk"] == f"{MD}.housing" and r["jurisdiction"] == MD
    assert not [fid for fid in ra if fid.startswith("us-fl-miami.")]  # jurisdiction beats plan text
