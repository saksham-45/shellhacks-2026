"""Freshness check end to end over replayed HTTP fixtures (no network)."""
import json
import shutil
from pathlib import Path

import pytest
import yaml

from research.freshness.checks import Context, run_check
from research.freshness.cli import main
from research.freshness.ledger import Ledger
from research.freshness.net import Fetcher, NetworkDisabled
from research.freshness.pins import ARCGIS_WORLD, CENSUS
from research.freshness.report import render_markdown, write_proposals
from research.freshness.state import State

FIX = Path(__file__).parent / "fixtures"
LAYER = "https://gis.example.gov/arcgis/rest/services/Waste/Garbage/MapServer"
CENSUS_KEY = "GET " + CENSUS + "?address=11200+SW+137th+Ave%2C+Miami%2C+FL+33186&benchmark=Public_AR_Current&format=json"
ARCGIS_KEY = "GET " + ARCGIS_WORLD + "?SingleLine=11200+SW+137th+Ave%2C+Miami%2C+FL+33186&f=json&maxLocations=1&outSR=4326"
QUERY_KEY = ("GET " + LAYER + "/1/query?geometry=-80.416465634674%2C25.663195487886&geometryType=esriGeometryPoint&inSR=4326"
             "&spatialRel=esriSpatialRelIntersects&outFields=WEEKDAYS&returnGeometry=false&f=json")


def fact(fid, **kw):
    base = {"id": fid, "claim": "c", "value": None, "unit": None, "jurisdiction": "us-fl-miamidade", "source_id": None,
            "url": "", "quote": "", "retrieved_at": "2026-09-25T12:00:00-04:00", "check_every": "P7D", "status": "verified"}
    base.update(kw)
    return base


def src(sid, url, kind, **kw):
    return {"id": sid, "publisher": "Example", "title": sid, "url": url, "kind": kind, "jurisdiction": "us-fl-miamidade",
            "key_required": False, "check_every": "P7D", "notes": "", **kw}


@pytest.fixture
def ledger_dir(tmp_path):
    root = tmp_path / "research"
    (root / "facts").mkdir(parents=True)
    sources = [
        src("s.page-ok", "https://www.example.gov/rent", "html"),
        src("s.page-drift", "https://www.example.gov/limits", "html"),
        src("s.down", "https://down.example.gov/x", "html"),
        src("s.moved", "https://old.example.gov/page", "html"),
        src("s.api", "https://api.example.gov/v1/limits", "api"),
        src("s.pdf", "https://www.example.gov/tolls.pdf", "pdf"),
        src("s.gis", LAYER + "/1", "gis-layer"),
    ]
    (root / "sources.yaml").write_text(yaml.safe_dump({"sources": sources}))
    facts = [
        fact("us-fl-miamidade.rent.ok", source_id="s.page-ok", url="https://www.example.gov/rent", quote="A 2-bedroom at 60 percent is $1,839", value=1839),
        fact("us-fl-miamidade.rent.drift", source_id="s.page-drift", url="https://www.example.gov/limits", quote="One person at 50 percent is $47,700", value=47700),
        fact("us-fl-miamidade.down", source_id="s.down", url="https://down.example.gov/x", quote="anything"),
        fact("us-fl-miamidade.moved", source_id="s.moved", url="https://old.example.gov/page", quote="Trash day is Tuesday"),
        fact("us-fl-miamidade.api", source_id="s.api", url="https://api.example.gov/v1/limits", value=68100, quote="x",
             query={"url": "https://api.example.gov/v1/limits", "json_path": "data.il50.l4"}),
        fact("us-fl-miamidade.toll", source_id="s.pdf", url="https://www.example.gov/tolls.pdf", quote="SR 836 Dolphin 97th Ave $0.66"),
        fact("us-fl-miamidade.unsourced", status="unsourced"),
        fact("us-fl-miamidade.trash.lookup", source_id="s.gis", url=LAYER + "/1", kind="lookup", desk="311", status="unsourced",
             lookup={"endpoint": LAYER, "layer_id": 1, "fields": ["WEEKDAYS"], "method": "arcgis-query point-in-polygon", "question": "q"}),
        fact("us-fl-miamidade.recycle.lookup", source_id="s.gis", url=LAYER + "/2", kind="lookup", desk="311", status="verified", quote="layer 2",
             lookup={"endpoint": LAYER, "layer_id": 2, "fields": ["WEEKDAY", "PICKUPWEEK"], "method": "arcgis-query point-in-polygon", "question": "q"}),
    ]
    (root / "facts" / "miami.json").write_text(json.dumps(facts, indent=2))
    return root


@pytest.fixture
def responses():
    census_block = (FIX / "census_waf_block.html").read_text()
    return {
        "GET https://www.example.gov/rent": {"body": "<html><body><p>A 2-bedroom   at 60 percent is $1,839.</p><script>x=1</script></body></html>"},
        "GET https://www.example.gov/limits": {"body": "<html><body><td>One person at 50 percent is $49,100</td></body></html>"},
        "GET https://down.example.gov/x": {"status": None, "error": "ConnectError: boom"},
        "GET https://old.example.gov/page": {"body": "<p>Trash day is Tuesday.</p>", "final_url": "https://new.example.gov/trash",
                                             "redirects": ["https://old.example.gov/page"]},
        "GET https://api.example.gov/v1/limits": {"body": {"data": {"il50": {"l4": 68100}}}},
        "GET https://www.example.gov/tolls.pdf": {"body": (FIX / "tiny.pdf").read_bytes(), "content_type": "application/pdf"},
        "GET " + LAYER + "/1": {"body": {"layers": []}},  # source url fetch (hash only)
        "GET " + LAYER + "/1?f=json": {"body": {"name": "GarbagePickupRoute", "geometryType": "esriGeometryPolygon",
                                                 "fields": [{"name": "OBJECTID"}, {"name": "WEEKDAYS"}]}},
        "GET " + LAYER + "/2?f=json": {"body": {"name": "RecyclingRoute", "fields": [{"name": "WEEKDAY"}]}},
        CENSUS_KEY: {"body": census_block, "content_type": "text/html"},
        ARCGIS_KEY: {"body": json.loads((FIX / "arcgis_world_kendall.json").read_text())},
        QUERY_KEY: {"body": {"features": [{"attributes": {"WEEKDAYS": "Tuesday Friday"}}]}},
    }


def run(ledger_dir, replay, tmp_path, write=True):
    ledger = Ledger.load(ledger_dir)
    state = State.load(tmp_path / "cache" / "state.json")
    ctx = Context(Fetcher(replay_dir=replay, min_interval=0), state, tmp_path / "cache",
                  [{"id": "kendall", "address": "11200 SW 137th Ave, Miami, FL 33186", "default": True}])
    return run_check(ledger, ctx, write_ledger=write), state


def test_full_check_classifies_every_outcome(ledger_dir, responses, replay_builder, tmp_path):
    if not shutil.which("pdftotext"):
        pytest.skip("pdftotext not installed")
    r, state = run(ledger_dir, replay_builder(responses), tmp_path)
    out = {f.fact_id: f for f in r.fact_results()}
    assert out["us-fl-miamidade.rent.ok"].outcome == "unchanged"
    d = out["us-fl-miamidade.rent.drift"]
    assert d.outcome == "value-changed" and "$49,100" in d.snippet
    assert out["us-fl-miamidade.down"].outcome == "source-unreachable"
    assert out["us-fl-miamidade.down"].consecutive_unreachable == 1 and not out["us-fl-miamidade.down"].propose_stale
    assert out["us-fl-miamidade.moved"].outcome == "moved"
    assert out["us-fl-miamidade.api"].outcome == "unchanged"
    assert out["us-fl-miamidade.toll"].outcome == "unchanged"
    assert out["us-fl-miamidade.unsourced"].outcome == "skipped"
    lk = out["us-fl-miamidade.trash.lookup"]
    assert lk.outcome == "unchanged" and lk.observed["features"] == 1 and lk.observed["geocoder"] == "arcgis-world-geocoder"
    sd = out["us-fl-miamidade.recycle.lookup"]
    assert sd.outcome == "schema-drift" and "PICKUPWEEK" in sd.detail
    assert r.exit_code() == 1 | 2 | 4
    # ledger: only verified drift/schema-drift facts flip to stale; values untouched; still a JSON array
    facts = json.loads((ledger_dir / "facts" / "miami.json").read_text())
    by = {f["id"]: f for f in facts}
    assert isinstance(facts, list)
    assert by["us-fl-miamidade.rent.drift"]["status"] == "stale" and by["us-fl-miamidade.rent.drift"]["value"] == 47700
    assert by["us-fl-miamidade.recycle.lookup"]["status"] == "stale"
    assert by["us-fl-miamidade.rent.ok"]["status"] == "verified"
    assert set(r.marked_stale) == {"us-fl-miamidade.rent.drift", "us-fl-miamidade.recycle.lookup"}
    # state: hash + pin cached with provider
    assert state.data["sources"]["s.page-ok"]["content_sha256_text"]
    assert state.data["pins"]["kendall"]["provider"] == "arcgis-world-geocoder"
    assert "census: blocked" in state.data["pins"]["kendall"]["errors_before"][0]
    md = render_markdown(r)
    assert "Content drifted: value changed" in md and "Source unreachable this run" in md and "secondary" in md
    props = write_proposals(r, tmp_path / "proposals")
    names = {p.name for p in props}
    assert "us-fl-miamidade.rent.drift.json" in names and "us-fl-miamidade.moved.json" in names
    assert json.loads((tmp_path / "proposals").joinpath(r.started_at[:10], "us-fl-miamidade.rent.drift.json").read_text())["auto_applied"] is False


def test_no_write_ledger_leaves_facts_alone(ledger_dir, responses, replay_builder, tmp_path):
    before = (ledger_dir / "facts" / "miami.json").read_text()
    run(ledger_dir, replay_builder(responses), tmp_path, write=False)
    assert (ledger_dir / "facts" / "miami.json").read_text() == before


def test_second_run_detects_page_change_and_due_only(ledger_dir, responses, replay_builder, tmp_path):
    replay = replay_builder(responses)
    run(ledger_dir, replay, tmp_path, write=False)
    responses["GET https://www.example.gov/rent"]["body"] = "<p>A 2-bedroom at 60 percent is $1,839. New footer.</p>"
    replay = replay_builder(responses)
    ledger = Ledger.load(ledger_dir)
    state = State.load(tmp_path / "cache" / "state.json")
    ctx = Context(Fetcher(replay_dir=replay, min_interval=0), state, tmp_path / "cache", [{"id": "k", "address": "x", "default": True}])
    r = run_check(ledger, ctx, only=["s.page-ok"], write_ledger=False)
    assert r.results[0].content_changed is True
    assert r.results[0].facts[0].outcome == "unchanged"
    r2 = run_check(ledger, ctx, due_only=True, write_ledger=False)
    assert "s.page-ok" in r2.not_due and not r2.results


def test_cli_exit_codes_and_report(ledger_dir, responses, replay_builder, tmp_path):
    replay = replay_builder(responses)
    rep = tmp_path / "rep.md"
    code = main(["check", "--ledger", str(ledger_dir), "--cache", str(tmp_path / "c"), "--proposals", str(tmp_path / "p"),
                 "--replay", str(replay), "--report", str(rep), "--no-write-ledger", "--min-interval", "0", "--source", "s.page-ok"])
    assert code == 0
    assert rep.exists() and rep.with_suffix(".json").exists()
    assert json.loads(rep.with_suffix(".json").read_text())["counts"] == {"unchanged": 1, "skipped": 1}
    assert main(["check", "--ledger", str(tmp_path / "nope"), "--report", str(rep)]) == 64
    assert main(["bogus"]) == 64


def test_unrecorded_request_fails_loudly(tmp_path):
    f = Fetcher(replay_dir=tmp_path)
    with pytest.raises(NetworkDisabled):
        f.get("https://example.gov/")


def test_redaction_of_keys():
    from research.freshness.net import redact
    assert redact("https://api.census.gov/data?get=x&key=abc123&for=y") == "https://api.census.gov/data?get=x&key=REDACTED&for=y"


def test_unreachable_is_transient_until_threshold(ledger_dir, responses, replay_builder, tmp_path):
    replay = replay_builder(responses)
    for i in range(1, 4):
        ledger = Ledger.load(ledger_dir)
        state = State.load(tmp_path / "cache" / "state.json")
        ctx = Context(Fetcher(replay_dir=replay, min_interval=0), state, tmp_path / "cache", [], unreachable_threshold=3)
        r = run_check(ledger, ctx, only=["s.down"])
        fr = r.results[0].facts[0]
        assert fr.outcome == "source-unreachable" and fr.consecutive_unreachable == i
        assert fr.propose_stale is (i == 3)
        assert "us-fl-miamidade.down" not in r.marked_stale
    assert r.exit_code() == 2 | 8
    props = write_proposals(r, tmp_path / "p")
    assert [p.name for p in props] == ["us-fl-miamidade.down.json"]
    facts = {f["id"]: f for f in json.loads((ledger_dir / "facts" / "miami.json").read_text())}
    assert facts["us-fl-miamidade.down"]["status"] == "verified"


def test_quote_missing_vs_value_changed(ledger_dir, responses, replay_builder, tmp_path):
    responses["GET https://www.example.gov/limits"]["body"] = "<p>This page was reorganized. See the new program list.</p>"
    r, _ = run(ledger_dir, replay_builder(responses), tmp_path, write=False)
    out = {f.fact_id: f for f in r.fact_results()}
    assert out["us-fl-miamidade.rent.drift"].outcome == "quote-missing"


def test_typed_values():
    from research.freshness.values import values_equal
    assert values_equal("Tuesday Friday", "Tue, Fri", "weekdays")
    assert values_equal("martes y viernes", "Tuesday and Friday", "weekdays")
    assert not values_equal("Tuesday", "Tuesday Friday", "weekdays")
    assert values_equal("305-386-5244", "(305) 386-5244", "phone")
    assert values_equal("A,B", ["b", "a"], "codes")
    assert values_equal("yes", True, "flag")
    assert values_equal("2026-05-01", "May 1, 2026", "date")
    assert values_equal("$1,839", 1839, "money")
