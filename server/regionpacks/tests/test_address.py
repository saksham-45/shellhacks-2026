"""Who handles my address (FM-MYAD-ADDR): the cached county answers and the ledger-gated police rules."""
import json
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

import pytest

from myad_regions import address as AD
from myad_regions import ledger as L

FIX = Path(__file__).resolve().parents[1] / "fixtures" / "checks"
PINS = {"pin-sw137": "UNINCORPORATED MIAMI-DADE", "pin-nw1st": "MIAMI"}
PERSONAL = ("OWNER", "MAILING", "CONTACT", "EMAIL", "GLOBALID", "CREATEDBY", "MODIFIEDBY")


def load(pin):
    return json.loads((FIX / f"address-{pin}.json").read_text(encoding="utf-8"))


def ts(s):
    d = datetime.fromisoformat(s)
    assert d.tzinfo is not None, s
    return d


@pytest.mark.parametrize("pin", PINS)
def test_cached_answer_is_labeled_timestamped_and_point_address(pin):
    d = load(pin)
    assert d["pin_id"] == pin and d["kind"] == "cached-county-response" and d["note"]
    loc = d["locator"]
    assert loc["addr_type"] == "PointAddress" and loc["score"] >= 95 and loc["url"].startswith("https://gisws.miamidade.gov/")
    ts(loc["retrieved_at"])
    assert set(d["layers"]) == {x.key for x in AD.LAYERS}
    assert d["layers"]["municipality"]["features"] == [{"NAME": PINS[pin]}]


@pytest.mark.parametrize("pin", PINS)
def test_every_layer_url_is_the_point_in_polygon_query_and_only_declared_fields(pin):
    d = load(pin)
    for key, ans in d["layers"].items():
        layer = AD.LAYER_BY_KEY[key]
        assert ans["url"] == layer.query_url(d["locator"]["lat"], d["locator"]["lon"]), key
        q = dict(parse_qsl(urlsplit(ans["url"]).query))
        assert q["spatialRel"] == "esriSpatialRelIntersects" and q["returnGeometry"] == "false"
        ts(ans["retrieved_at"])
        for f in ans["features"]:
            assert set(f) <= set(layer.fields), (key, f)
            assert not any(k.upper().startswith(PERSONAL) for k in f), (key, f)


@pytest.mark.parametrize("pin", PINS)
def test_code_lists_come_from_layer_metadata(pin):
    d = load(pin)
    for key, dom in d["domains"].items():
        assert dom["url"].endswith("?f=json") and dom["codes"] and dom["field"], key
        ts(dom["retrieved_at"])
    assert d["domains"]["water"]["codes"]["MDWS"] == "Miami Dade Water and Sewer"
    if d["layers"]["city-bulky"]["features"]:
        assert d["domains"]["city-bulky"]["url"] == AD.CITY_TRASH_LAYER + "?f=json"


def test_minimize_drops_undeclared_and_blank_fields_and_rejects_error_bodies():
    layer = AD.LAYER_BY_KEY["municipality"]
    body = {"features": [{"attributes": {"NAME": "MIAMI", "OBJECTID": 7, "MUNICUID": "x"}}, {"attributes": {"NAME": " "}}]}
    assert AD.minimize_features(layer, body) == [{"NAME": "MIAMI"}, {}]
    with pytest.raises(ValueError):
        AD.minimize_features(layer, {"error": {"code": 400}})


def test_domain_codes_reads_only_coded_values():
    meta = {"fields": [{"name": "UTILITYNAME", "domain": {"type": "codedValue", "codedValues": [{"code": "MDWS", "name": "Miami Dade Water and Sewer"}]}},
                       {"name": "X", "domain": {"type": "range"}}]}
    assert AD.domain_codes(meta, "UTILITYNAME") == {"MDWS": "Miami Dade Water and Sewer"}
    assert AD.domain_codes(meta, "X") == {}


@pytest.fixture
def ledger_dir(tmp_path, monkeypatch):
    monkeypatch.setenv(L.LEDGER_ENV, str(tmp_path))
    L.clear_cache()
    yield tmp_path
    L.clear_cache()


def row(fid, quote, **kw):
    # Test-only rows in pytest's temporary folder; the quote text is a test sentence, not the Sheriff's page.
    return {"id": fid, "claim": "test row", "jurisdiction": fid.split(".")[0], "source_id": "test.source",
            "url": "https://example.invalid/test", "quote": quote, "retrieved_at": "2026-09-25T18:00:00-04:00",
            "check_every": "P30D", "status": "verified", "kind": "static", **kw}


def rules_by_id():
    return {r["id"]: r for r in AD.address_rules()["rules"]}


def test_rules_are_unsourced_without_a_verified_row(ledger_dir):
    for r in rules_by_id().values():
        assert r["status"] == "unsourced" and r["why_unsourced"] and r["municipalities"] == [] and r["unconfirmed"]


def test_a_partial_quote_confirms_only_the_areas_it_names(ledger_dir):
    fid = "us-fl-miamidade.sheriff.online-report-area"
    (ledger_dir / "r.json").write_text(json.dumps([row(fid, "test: unincorporated areas and Cutler Bay")]))
    r = rules_by_id()["online-report"]
    assert r["status"] == "verified" and r["municipalities"] == ["UNINCORPORATED MIAMI-DADE", "CUTLER BAY"]
    assert r["unconfirmed"] == ["PALMETTO BAY", "MIAMI LAKES"] and "PALMETTO BAY" in r["why_partial"]
    (ledger_dir / "r.json").write_text(json.dumps([row(fid, "test: unincorporated areas, Cutler Bay, Palmetto Bay and Miami Lakes")]))
    L.clear_cache()
    r = rules_by_id()["online-report"]
    assert r["status"] == "verified" and r["unconfirmed"] == [] and len(r["municipalities"]) == 4


def test_a_quote_naming_no_area_is_not_a_rule(ledger_dir):
    fid = "us-fl-miami.police.service-area"
    (ledger_dir / "r.json").write_text(json.dumps([row(fid, "test: the citizens of Miami")]))
    r = rules_by_id()["police.city-of-miami"]
    assert r["status"] == "unsourced" and r["municipalities"] == [] and r["unconfirmed"] == ["MIAMI"]


def test_citizens_of_miami_counts_only_on_the_citys_own_site(ledger_dir):
    fid = "us-fl-miami.police.service-area"
    (ledger_dir / "r.json").write_text(json.dumps([row(fid, "test: the citizens of Miami",
                                                        url="https://www.miami.gov/test")]))
    r = rules_by_id()["police.city-of-miami"]
    assert r["status"] == "verified" and r["municipalities"] == ["MIAMI"] and r["unconfirmed"] == []


def test_a_second_gating_fact_confirms_the_areas_it_names(ledger_dir):
    (ledger_dir / "r.json").write_text(json.dumps([
        row("us-fl-miamidade.sheriff.service-area", "test: the Unincorporated area and contracted municipalities"),
        row("us-fl-miamidade.sheriff.contract-towns", "test: agreement with the Town of Cutler Bay"),
    ]))
    r = rules_by_id()["police.sheriff"]
    assert r["municipalities"] == ["UNINCORPORATED MIAMI-DADE", "CUTLER BAY"]
    assert r["unconfirmed"] == ["PALMETTO BAY", "MIAMI LAKES"]
    assert r["fact"] == "us-fl-miamidade.sheriff.service-area"
    assert r["also_facts"] == ["us-fl-miamidade.sheriff.contract-towns"]


def test_unverified_row_is_not_a_rule(ledger_dir):
    fid = "us-fl-miami.police.service-area"
    (ledger_dir / "r.json").write_text(json.dumps([row(fid, "test: City of Miami", status="draft")]))
    assert rules_by_id()["police.city-of-miami"]["status"] == "unsourced"


def test_exported_rules_match_the_python_table():
    ios = Path(__file__).resolve().parents[3] / "ios/Packages/ADCityPack/Sources/ADCityPack/Resources/Checks/address-rules.json"
    L.clear_cache()
    assert json.loads(ios.read_text(encoding="utf-8")) == AD.address_rules()
