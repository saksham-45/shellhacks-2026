"""Fee Check / Listing Check data (FM-MYAD-DEMO-FEE). Offline; owner strings below are synthetic."""
import json
from pathlib import Path

from myad_regions import checks

ROOT = Path(__file__).resolve().parents[1]


def test_owner_kind_rules():
    assert checks.owner_kind(["MIAMI-DADE COUNTY"], "COUNTY : OFFICE BUILDING") == "government"
    assert checks.owner_kind(["CITY OF MIAMI"], "MUNICIPAL") == "government"
    assert checks.owner_kind(["SUNSHINE HOLDINGS LLC"], "RESIDENTIAL") == "company"
    assert checks.owner_kind(["PEREZ CARLOS", "GARCIA ANA"], "RESIDENTIAL") == "person"
    assert checks.owner_kind(["", None], None) == "unknown"
    assert checks.fold("Pérez-García, José") == "PEREZ GARCIA JOSE"


def test_minimize_parcel_drops_every_owner_and_mailing_field():
    attrs = {"FOLIO": "0100000000001", "TRUE_SITE_ADDR": "1 TEST ST", "TRUE_SITE_ZIP_CODE": "33128-1234",
             "CONDO_FLAG": "N", "DOR_DESC": "RESIDENTIAL", "TRUE_OWNER1": "PEREZ CARLOS",
             "TRUE_MAILING_ADDR1": "PO BOX 1"}
    out = checks.minimize_parcel(attrs, request_url="https://example.gov/q", retrieved_at="2026-09-25T18:00:00-04:00")
    text = json.dumps(out)
    assert "PEREZ" not in text and "MAILING" not in text and "PO BOX" not in text
    assert out["owner_kind"] == "person" and out["site_zip"] == "33128" and out["condo"] is False
    assert set(out) == {"folio", "site_address", "site_zip", "condo", "land_use", "owner_kind",
                        "source_id", "url", "record_url", "retrieved_at"}


def test_check_ledger_shape_and_only_verified_values():
    doc = checks.check_ledger()
    from myad_regions.address import ADDRESS_DESKS
    assert [d["id"] for d in doc["desks"]] == list(dict.fromkeys([*checks.CHECK_DESKS, *ADDRESS_DESKS]))
    by_id = {f["id"]: f for f in doc["facts"]}
    for fid in checks.FEE_FACTS + checks.LISTING_FACTS:
        assert fid in by_id
    for f in doc["facts"]:
        if f["status"] == "verified":
            assert f["value"]["kind"] in {"money", "phone", "code", "text"}
            assert f["source"]["url"].startswith("https://") and f["source"]["publisher"]
            assert f["quote"] and f["retrieved_at"]
        else:
            assert set(f) == {"id", "status"}, f
    fee = by_id["us-fl.flhsmv.fee.class-e-original"]
    assert fee["status"] == "verified"
    assert fee["value"]["kind"] == "money" and fee["value"]["amount"] == 48 and fee["value"]["currency"] == "USD"


def test_shipped_check_fixtures_are_owner_free_and_labeled():
    listing = json.loads((ROOT / "fixtures/checks/listing-county-building.json").read_text())
    assert listing["folio"] == "0141370230020" and listing["owner_kind"] == "government"
    assert "OWNER" not in json.dumps(listing).upper().replace("OWNER_KIND", "")
    replay = json.loads((ROOT / "fixtures/checks/fee-replay.json").read_text())
    assert replay["kind"] == "demo-script" and replay["language"] == "es"
