"""Fee Check: fees and payment rules come only from myAD Research's verified ledger rows, never from code."""
import json

import pytest

from myad_regions import adapters as A
from myad_regions import ledger as L
from myad_regions.adapters import Ctx
from myad_regions.manifests import all_adapters
from myad_regions.transport import Deadline
from myad_regions.types import ResolvedPin, validate_result

FEE_ADAPTERS = {"us.fee-check-uscis": ("us", "us.uscis"), "us.fee-check-ftc": ("us", "us.ftc"),
                "us-fl.fee-check-flhsmv": ("us-fl", "us-fl.flhsmv"), "us-fl.fee-check-deposit": ("us-fl", "us-fl.bar-lawyer-referral"),
                "us-fl-miamidade.fee-check-mia-taxi": ("us-fl-miamidade", "us-fl-miamidade.mia-information")}
CTX = Ctx(ResolvedPin(25.7756, -80.1967, None, "device_coords"), ("us", "us-fl", "us-fl-miamidade", "us-fl-miami"))


class NoNetwork:
    live = False

    def fetch(self, req, deadline):  # pragma: no cover - a ledger adapter must never fetch
        raise AssertionError(f"Fee Check fetched {req.url}")


@pytest.fixture
def ledger_dir(tmp_path, monkeypatch):
    monkeypatch.setenv(L.LEDGER_ENV, str(tmp_path))
    L.clear_cache()
    yield tmp_path
    L.clear_cache()


def run(adapter_id):
    return {r.fact_id: r for r in A.adapter(adapter_id).run(CTX, NoNetwork(), Deadline(5))}


def row(fid, **kw):
    # Test-only rows built in memory. The amount is a sentinel, not a real fee, and is never saved to disk
    # outside pytest's temporary folder.
    base = {"id": fid, "claim": "test row", "jurisdiction": fid.split(".")[0], "source_id": "us.fema.nfhl",
            "url": "https://example.invalid/test", "quote": "test quote", "retrieved_at": "2026-09-25T18:00:00-04:00",
            "check_every": "P30D", "status": "verified", "kind": "static"}
    return {**base, **kw}


def test_fee_check_adapters_are_declared_where_their_government_is():
    decls = {a.id: a for a in all_adapters()}
    for aid, (pack, desk) in FEE_ADAPTERS.items():
        assert decls[aid].pack == pack and decls[aid].desk == desk and decls[aid].sources == ()
        assert A.adapter(aid).plan(CTX.pin) == []


def test_empty_ledger_answers_every_fee_fact_unsourced_with_desk(ledger_dir):
    for aid, (pack, desk) in FEE_ADAPTERS.items():
        for fid, r in run(aid).items():
            j = r.to_json()
            assert j["status"] == "unsourced" and j["value"] is None and j["desk"] == desk, fid
            assert j["url"] is None and j["retrieved_at"] is None and j["basis"]["lookup"] == "ledger"


def test_verified_ledger_row_becomes_the_answer_with_its_evidence(ledger_dir):
    fid = "us-fl.flhsmv.fee.class-e-original"
    (ledger_dir / "license.json").write_text(json.dumps([row(fid, value=0.01, value_type="money", unit="USD")]))
    r = run("us-fl.fee-check-flhsmv")[fid].to_json()
    assert r["status"] == "ok" and r["value"] == {"type": "money", "amount": 0.01, "currency": "USD"}
    assert r["url"] == "https://example.invalid/test" and r["retrieved_at"] == "2026-09-25T18:00:00-04:00"
    assert r["source_id"] == "us.fema.nfhl" and r["publisher"] and r["quote"] == "test quote"


@pytest.mark.parametrize("bad", [
    {"status": "unsourced", "value": 0.01, "value_type": "money", "unit": "USD"},
    {"status": "demo", "value": 0.01, "value_type": "money", "unit": "USD"},
    {"value": 0.01, "value_type": "money"},                 # money without a currency: never guessed
    {"value": "Pay by card", "value_type": "text"},        # text without value_language
    {"value": 0.01, "value_type": "money", "unit": "USD", "url": None},
    {"value": None, "value_type": "money", "unit": "USD"},
])
def test_rows_that_are_not_verified_and_typeable_stay_unsourced(ledger_dir, bad):
    fid = "us.uscis.fee-payment-methods"
    (ledger_dir / "immigration.json").write_text(json.dumps([row(fid, **bad)]))
    assert run("us.fee-check-uscis")[fid].status == "unsourced"


def test_text_rule_needs_its_language_and_a_known_publisher(ledger_dir):
    fid, other = "us.ftc.gift-card-payment-scam", "us.uscis.forms-free"
    (ledger_dir / "scams.json").write_text(json.dumps([
        row(fid, value="test rule text", value_type="text", value_language="en"),
        row(other, value=True, value_type="flag", source_id="not.in.any.registry")]))
    r = run("us.fee-check-ftc")[fid].to_json()
    assert r["status"] == "ok" and r["value"] == {"type": "text", "text": "test rule text", "language": "en"}
    assert validate_result({**r, "ledger_id": fid, "is_demo": False}) == []
    u = run("us.fee-check-uscis")[other]
    assert u.status == "error" and u.value is None  # a sourced answer must name its publisher


def test_publisher_comes_from_research_sources_registry(ledger_dir):
    facts = ledger_dir / "facts"
    facts.mkdir()
    (ledger_dir / "sources.yaml").write_text("sources:\n- id: test.only-source\n  publisher: Test Publisher\n  check_every: P90D\n")
    fid = "us.ftc.gift-card-payment-scam"
    (facts / "scams.json").write_text(json.dumps([row(fid, value="test rule text", value_type="text", value_language="en",
                                                      source_id="test.only-source", check_every=None)]))
    import os
    os.environ[L.LEDGER_ENV] = str(facts)
    L.clear_cache()
    r = run("us.fee-check-ftc")[fid].to_json()
    assert r["status"] == "ok" and r["publisher"] == "Test Publisher" and r["check_every"] == "P90D"


def test_broken_ledger_file_is_ignored(ledger_dir):
    (ledger_dir / "license.json").write_text("{not json")
    assert {r.status for r in run("us-fl.fee-check-flhsmv").values()} == {"unsourced"}
