"""End-to-end onboarding over a synthetic, non-Miami place (proves nothing is Miami-hardcoded). No network."""
import datetime as dt
import json

import pytest
import yaml

from research.freshness.net import request_key as K
from research.onboarding.cli import main
from research.onboarding.discover.arcgis import AGO_SEARCH
from research.onboarding.discover.dotgov import REGISTRY_URL
from research.onboarding.discover.federal import ACS_GROUPS, ACS_SF, HUD_API_DOC, NCES_DETAIL, NCES_DIR
from research.onboarding.discover.gtfs import MDB_CSV
from research.onboarding.discover.portals import SOCRATA
from research.onboarding.resolve import COUNTY_URL, PLACE_URL, STATE_URL

ROOT = "https://gis.examplecounty.gov/arcgis/rest/services"
Y = dt.date.today().year


def fixtures():
    r = {}
    r[K("GET", STATE_URL)] = {"body": "STATE|STUSAB|STATE_NAME|STATENS\n12|FL|Florida|00294478\n77|ZZ|Zedland|00000077\n", "content_type": "text/plain"}
    r[K("GET", COUNTY_URL.format(fips="77", abbr="zz"))] = {"body": "STATE|STATEFP|COUNTYFP|COUNTYNS|COUNTYNAME|CLASSFP|FUNCSTAT\nZZ|77|001|1|Example County|H1|A\nZZ|77|003|2|Other County|H1|A\n", "content_type": "text/plain"}
    r[K("GET", PLACE_URL.format(fips="77", abbr="zz"))] = {"body": "STATE|STATEFP|PLACEFP|PLACENS|PLACENAME|TYPE|CLASSFP|FUNCSTAT|COUNTIES\n"
        "ZZ|77|10000|1|Riverton city|INCORPORATED PLACE|C1|A|Example County\nZZ|77|20000|2|Lakeside CDP|CENSUS DESIGNATED PLACE|U1|S|Example County~~~Other County\n"
        "ZZ|77|30000|3|Farview town|INCORPORATED PLACE|C1|A|Other County\n", "content_type": "text/plain"}
    r[K("GET", REGISTRY_URL)] = {"content_type": "text/csv", "body":
        "Domain name,Domain type,Organization name,Suborganization name,City,State,Security contact email\n"
        "examplecounty.gov,County,Example County,,Riverton,ZZ,it@examplecounty.gov\n"
        "exampletaxcollector.gov,County,Example County Tax Collector,,Riverton,ZZ,(blank)\n"
        "riverton.gov,City,City of Riverton,,Riverton,ZZ,it@rivertoncity.org\n"
        "riverton-heights.gov,City,City of Riverton Heights,,Riverton Heights,ZZ,(blank)\n"
        "zzdmv.gov,State or territory,Zedland Department of Motor Vehicles,,Capital,ZZ,(blank)\n"
        "examplecounty.gov.fake,County,Example County,,Elsewhere,QQ,(blank)\n"}
    r[K("GET", "https://examplecounty.gov/")] = {"body": f"""<html><body><a href="/open-data">Open Data and GIS</a>
        <p>Questions? Call 311 or 555-201-3111 for county services.</p><a href="{ROOT}">Map services</a></body></html>""",
        "final_url": "https://www.examplecounty.gov/"}
    r[K("GET", "https://www.examplecounty.gov/open-data")] = {"body": "<html><body><a href='https://data.examplecounty.gov/gtfs/google_transit.zip'>GTFS feed</a></body></html>"}
    r[K("GET", "https://exampletaxcollector.gov/")] = {"body": "<html><body>Driver license and auto tag appointments: call 555-201-4000.</body></html>"}
    r[K("GET", "https://rivertoncity.org/")] = {"status": None, "error": "ConnectError: no address"}
    r[K("GET", "https://riverton.gov/")] = {"body": "<html><head><meta http-equiv='refresh' content='0; URL=https://www.riverton.gov/home'></head></html>"}
    r[K("GET", "https://www.riverton.gov/home")] = {"body": "<html><body>Missed trash pickup? Dial 311. Solid waste office phone 555-301-2000.</body></html>"}
    for base in ("Example", "Riverton"):
        r[K("GET", AGO_SEARCH, {"q": f'"{base}" (type:"Hub Site Application" OR type:"Site Application")', "num": "50", "f": "json"})] = {"body": {"results": []}}
        r[K("GET", SOCRATA, {"q": base, "only": "dataset", "limit": "100"})] = {"body": {"results": [
            {"metadata": {"domain": "data.elsewhere.gov"}, "resource": {"name": "Trash routes", "id": "abcd-1234"}}]}}
    r[K("GET", MDB_CSV)] = {"content_type": "text/csv", "body":
        "id,data_type,entity_type,location.country_code,location.subdivision_name,location.municipality,provider,is_official,urls.direct_download,urls.authentication_type,urls.authentication_info,urls.latest,status\n"
        "mdb-9001,gtfs,,US,Zedland,Riverton,Example County Transit,True,https://data.examplecounty.gov/gtfs/google_transit.zip,0,,https://files.example/latest.zip,active\n"
        "mdb-9002,gtfs,,US,Zedland,Farview,Farview Bus,True,https://farview.example/gtfs.zip,0,,,active\n"}
    r[K("HEAD", "https://data.examplecounty.gov/gtfs/google_transit.zip")] = {"body": b"", "content_type": "application/zip"}
    r[K("GET", ACS_GROUPS.format(year=Y - 1), None)] = {"status": 404, "body": "not found"}
    r[K("GET", ACS_GROUPS.format(year=Y - 2), None)] = {"body": {"variables": {
        "B16001_001E": {"label": "Estimate!!Total:"}, "B16001_002E": {"label": "Estimate!!Total:!!Speak only English"},
        "B16001_003E": {"label": "Estimate!!Total:!!Spanish:"},
        "B16001_005E": {"label": 'Estimate!!Total:!!Spanish:!!Speak English less than "very well"'},
        "B16001_009E": {"label": "Estimate!!Total:!!Haitian:"}}}}
    r[K("GET", ACS_SF.format(year=Y - 2))] = {"content_type": "text/plain", "body":
        "GEO_ID|B16001_E001|B16001_M001|B16001_E002|B16001_E003|B16001_E005|B16001_E009\n0500000US77001|1000|5|600|300|120|50\n"}
    r[K("GET", AGO_SEARCH, {"q": '"Public Housing Authorities" type:"Feature Service" owner:HUD*', "num": "20", "f": "json"})] = {"body": {"results": []}}
    r[K("GET", HUD_API_DOC)] = {"body": "<html>FMR API</html>"}
    r[K("GET", NCES_DIR, {"f": "json"})] = {"body": {"services": [{"name": "K12_School_Locations/EDGE_GEOCODE_PUBLICLEA_2425", "type": "MapServer"}]}}
    lea = "https://nces.ed.gov/opengis/rest/services/K12_School_Locations/EDGE_GEOCODE_PUBLICLEA_2425/MapServer/0"
    r[K("GET", lea + "/query", {"where": "STFIP='77' AND NMCNTY='Example County'", "outFields": "LEAID,NAME,STREET,CITY,STATE,ZIP,SCHOOLYEAR", "returnGeometry": "false", "f": "json"})] = {
        "body": {"features": [{"attributes": {"LEAID": "7700001", "NAME": "EXAMPLE COUNTY SCHOOLS", "STREET": "1 School Rd", "CITY": "Riverton", "ZIP": "77001"}}]}}
    r[K("GET", NCES_DETAIL, {"ID2": "7700001"})] = {"body": "<html>District Name: EXAMPLE Phone: (555)201-5000 Type: Regular local school district Status: Open Website: http://www.exampleschools.example</html>"}
    r[K("GET", AGO_SEARCH, {"q": 'LSC offices grantees type:"Feature Service"', "num": "20", "f": "json"})] = {"body": {"results": []}}
    r[K("GET", ROOT, {"f": "json"})] = {"body": {"folders": ["Community"], "services": [{"name": "Boundaries", "type": "MapServer"}]}}
    r[K("GET", ROOT + "/Community", {"f": "json"})] = {"body": {"services": [{"name": "Community/SolidWaste", "type": "MapServer"}, {"name": "Community/Geocoder", "type": "GeocodeServer"}]}}
    r[K("GET", ROOT + "/Boundaries/MapServer/layers", {"f": "json"})] = {"body": {"layers": [
        {"id": 0, "name": "Municipal Boundaries", "geometryType": "esriGeometryPolygon", "fields": [{"name": "OBJECTID", "type": "esriFieldTypeOID"}, {"name": "MUNI_NAME", "type": "esriFieldTypeString"}]}]}}
    r[K("GET", ROOT + "/Community/SolidWaste/MapServer/layers", {"f": "json"})] = {"body": {"layers": [
        {"id": 3, "name": "Garbage Collection Day", "geometryType": "esriGeometryPolygon", "fields": [{"name": "COLLECT_DAY", "type": "esriFieldTypeString"}, {"name": "HAULER", "type": "esriFieldTypeString"}]},
        {"id": 4, "name": "Recycling Week", "geometryType": "esriGeometryPolygon", "fields": [{"name": "WEEK", "type": "esriFieldTypeString"}]}]}}
    return r


@pytest.fixture
def run_dir(tmp_path, replay_builder, monkeypatch):
    monkeypatch.delenv("CENSUS_API_KEY", raising=False)
    replay = replay_builder(fixtures())
    out = tmp_path / "out"
    code = main(["propose", "--place", "Example County, ZZ", "--city", "Riverton", "--out", str(out), "--replay", str(replay),
                 "--no-probe", "--min-interval", "0"])
    assert code == 0
    return out


def test_chain_and_outputs(run_dir):
    for name in ("manifest.proposed.yaml", "sources.fragment.yaml", "facts.skeleton.json", "gaps.md", "findings.json", "fetch-log.json"):
        assert (run_dir / name).exists(), name
    man = yaml.safe_load((run_dir / "manifest.proposed.yaml").read_text())
    assert [p["id"] for p in man["packs"]] == ["us", "us-zz", "us-zz-example", "us-zz-riverton"]
    assert [p["parent"] for p in man["packs"]] == [None, "us", "us-zz", "us-zz-example"]
    county = man["packs"][2]
    topics = {a["topic"]: a for a in county["adapters"]}
    assert topics["trash"]["layer_id"] == 3 and topics["trash"]["fields"] == ["COLLECT_DAY", "HAULER"]
    assert topics["municipal-boundary"]["endpoint"] == ROOT + "/Boundaries/MapServer"
    assert county["languages"]["observed"][0]["name"] == "English only"
    assert any(l["name"] == "Haitian" and l["share_of_pop_5plus"] == 0.05 for l in county["languages"]["observed"])
    assert county["transit"][0]["url"] == "https://data.examplecounty.gov/gtfs/google_transit.zip"
    assert all(t["url"] != "https://farview.example/gtfs.zip" for t in county["transit"])  # other county's feed excluded


def test_phones_only_with_quotes_and_official_flags(run_dir):
    man = yaml.safe_load((run_dir / "manifest.proposed.yaml").read_text())
    desks = [d for p in man["packs"] for d in p.get("desks", [])]
    phones = {d["phone"] for d in desks if d.get("phone")}
    assert {"311", "555-201-3111", "555-201-4000", "555-201-5000"} <= phones
    for d in desks:
        if d.get("phone") and d["found_by"] == "official-website":
            assert d["phone"].replace("-", "")[-4:] in d["quote"].replace("-", "").replace(" ", "")
    doms = json.loads((run_dir / "findings.json").read_text())["official_domains"]
    assert "riverton-heights.gov" not in doms  # a different city with a similar name
    assert "examplecounty.gov.fake" not in doms  # different state
    assert doms["rivertoncity.org"] == "us-zz-riverton"  # registry security-contact domain
    portals = [p for pk in man["packs"] for p in pk.get("portals", [])]
    assert not any("elsewhere" in p["url"] for p in portals)  # .gov but not this chain's


def test_fact_skeleton_is_unsourced_with_lookups(run_dir):
    facts = json.loads((run_dir / "facts.skeleton.json").read_text())
    assert isinstance(facts, list) and facts
    assert all(f["status"] == "unsourced" and f["value"] is None for f in facts)
    lk = {f["id"]: f for f in facts if f.get("kind") == "lookup"}
    t = lk["us-zz-example.trash.lookup"]
    assert t["desk"] == "us-zz-example.solid-waste" and t["value_type"] == "weekdays"  # pack-scoped desk id
    assert t["lookup"]["endpoint"] == ROOT + "/Community/SolidWaste/MapServer" and t["lookup"]["layer_id"] == 3
    assert set(t["lookup"]) <= {"endpoint", "layer_id", "fields", "method", "question", "params", "notes"}
    assert all(k.startswith("x-") or k in {"id", "claim", "value", "unit", "jurisdiction", "source_id", "url", "quote", "retrieved_at",
               "check_every", "status", "notes", "kind", "desk", "lookup", "value_type"} for f in facts for k in f)
    assert all(f["check_every"].startswith("P") for f in facts)
    src = yaml.safe_load((run_dir / "sources.fragment.yaml").read_text())["sources"]
    ids = {s["id"] for s in src}
    assert all(f["source_id"] in ids for f in facts)
    for s in src:
        assert set(s) >= {"id", "publisher", "title", "url", "kind", "jurisdiction", "key_required", "check_every", "notes"}
        assert s["kind"] in {"api", "gis-layer", "gtfs", "pdf", "html", "dataset"}


def test_gaps_report_names_missing_things(run_dir):
    gaps = (run_dir / "gaps.md").read_text()
    assert "| parcel | **missing** |" in gaps
    assert "desk: housing-authority | **missing**" in gaps
    assert "CENSUS_API_KEY" in gaps


def test_reemit_rebuilds_without_network(run_dir):
    before = json.loads((run_dir / "facts.skeleton.json").read_text())
    (run_dir / "facts.skeleton.json").unlink()
    assert main(["reemit", "--run", str(run_dir)]) == 0
    assert json.loads((run_dir / "facts.skeleton.json").read_text()) == before


def test_skeleton_matches_ledger_schema_except_pack_ids(run_dir):
    """Against the ledger's own fact schema (if present), with only its Miami-only pack enum widened."""
    import re
    from pathlib import Path
    import jsonschema
    sp = Path(__file__).resolve().parents[1] / "schema" / "fact.schema.json"
    if not sp.exists():
        pytest.skip("ledger schema not present")
    txt = sp.read_text()
    txt = txt.replace("(us|us-fl|us-fl-miamidade|us-fl-miami)", "(us(-[a-z0-9]+)*)")
    schema = json.loads(txt)

    def widen(o):
        if isinstance(o, dict):
            if o.get("enum") == ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"]:
                o.pop("enum"); o["pattern"] = "^us(-[a-z0-9]+)*$"
            for v in o.values():
                widen(v)
        elif isinstance(o, list):
            for v in o:
                widen(v)
    widen(schema)
    facts = json.loads((run_dir / "facts.skeleton.json").read_text())
    v = jsonschema.Draft202012Validator(schema) if "2020-12" in schema.get("$schema", "") else jsonschema.Draft7Validator(schema)
    errs = [f"{f['id']}: {e.message}" for f in facts for e in v.iter_errors(f)]
    assert not errs, errs[:5]
