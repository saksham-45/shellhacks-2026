"""Offline data for the Fee Check and Listing Check demo beats (FM-MYAD-DEMO-FEE).

check_ledger(): the slice of myAD Research's verified ledger (research/facts) that the two beats read on the phone
with no network: fee amounts, the FTC rental-scam signs, and the contact facts of the desks the answers name. Values
are copied from verified rows only; anything else ships as `unsourced` with no value, so the phone names the desk.

minimize_parcel(): turns one county parcel record (MD_LandInformation layer 26) into the cached Listing Check replay.
Owner names and mailing fields are read in memory to classify the owner kind, then dropped: the cached file keeps
folio, site address, condo flag, land use, owner kind, source and retrieved_at, never a name.
"""
from __future__ import annotations

import re
import unicodedata
from pathlib import Path

import yaml

from . import ledger as L

TREE = Path(__file__).resolve().parents[3]
DESKS_YAML = TREE / "content" / "desks.yaml"

FEE_FACTS = (
    "us-fl.flhsmv.fee.class-e-original",
    "us-fl.flhsmv.fee.class-e-renewal",
    "us-fl.flhsmv.fee.id-card-original",
    "us-fl.flhsmv.fee.tax-collector-service-fee",
)
LISTING_FACTS = ("us.ftc.rental-scam-signs", "us.ftc.rental-scam-signs.es")
CHECK_DESKS = ("us-fl.flhsmv", "us-fl-miamidade.tax-collector", "us.ftc", "us-fl-miamidade.311")
# Contact kinds the beats show or speak; places need ADCore's Place wire and are not used on these screens.
CONTACT_KINDS = ("name", "phone", "url")

PARCEL_LAYER = "https://gisweb.miamidade.gov/arcgis/rest/services/MD_LandInformation/MapServer/26"
PARCEL_SOURCE = "us-fl-miamidade.gis-parcels"
RECORD_PAGE = "https://apps.miamidadepa.gov/propertysearch/"
# Read live for the owner-kind decision, never written anywhere.
PARCEL_FIELDS = ("FOLIO", "TRUE_SITE_ADDR", "TRUE_SITE_ZIP_CODE", "CONDO_FLAG", "DOR_DESC",
                 "TRUE_OWNER1", "TRUE_OWNER2", "TRUE_OWNER3")

_COMPANY = {"LLC", "L L C", "INC", "CORP", "CORPORATION", "CO", "COMPANY", "LP", "LLP", "LTD", "PA", "PLLC",
            "TRUST", "TR", "TRS", "TRUSTEE", "HOLDINGS", "PROPERTIES", "PROPERTY", "INVESTMENTS", "INVESTMENT",
            "GROUP", "PARTNERS", "PARTNERSHIP", "ASSOCIATION", "ASSN", "BANK", "FUND", "REALTY", "VENTURES",
            "ENTERPRISES", "MANAGEMENT", "MGMT", "CAPITAL", "ASSOCIATES", "FOUNDATION", "CHURCH", "MINISTRIES"}
_GOVERNMENT = ("COUNTY", "CITY OF", "STATE OF", "UNITED STATES", "SCHOOL BOARD", "HOUSING AUTHORITY",
               "BOARD OF", "DEPARTMENT OF", "DEPT OF", "TOWN OF", "VILLAGE OF", "INTERNAL IMPROVEMENT")
_GOV_LAND_USE = ("COUNTY", "MUNICIPAL", "STATE", "FEDERAL")


def fold(s: str) -> str:
    """Uppercase ASCII letters, digits and single spaces (accents folded), the matching alphabet on both sides."""
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).upper()
    return " ".join(re.findall(r"[A-Z0-9]+", s))


def owner_kind(owner_lines: list[str], land_use: str | None) -> str:
    """government | company | person | unknown. Mirrors ListingCheck.OwnerKind in ADCityPack."""
    lines = [fold(x) for x in owner_lines if x and fold(x)]
    if not lines:
        return "unknown"
    lu = fold(land_use or "")
    if any(f" {g} " in f" {ln} " for ln in lines for g in _GOVERNMENT) or lu.split(" ")[0] in _GOV_LAND_USE:
        return "government"
    if any(set(ln.split()) & _COMPANY for ln in lines):
        return "company"
    return "person"


def minimize_parcel(attrs: dict, *, request_url: str, retrieved_at: str) -> dict:
    owners = [attrs.get(f"TRUE_OWNER{i}") or "" for i in (1, 2, 3)]
    return {
        "folio": str(attrs["FOLIO"]),
        "site_address": attrs.get("TRUE_SITE_ADDR"),
        "site_zip": (attrs.get("TRUE_SITE_ZIP_CODE") or "")[:5] or None,
        "condo": attrs.get("CONDO_FLAG") == "Y",
        "land_use": attrs.get("DOR_DESC"),
        "owner_kind": owner_kind(owners, attrs.get("DOR_DESC")),
        "source_id": PARCEL_SOURCE,
        "url": request_url,
        "record_url": RECORD_PAGE,
        "retrieved_at": retrieved_at,
    }


def _desks() -> dict[str, dict]:
    data = yaml.safe_load(DESKS_YAML.read_text(encoding="utf-8")) or []
    items = data.get("desks", data) if isinstance(data, dict) else data
    return {d["id"]: d for d in items if isinstance(d, dict) and "id" in d}


def _wire_value(v: dict) -> dict | None:
    """Server FactValue ("type") to ADCore's Codable FactValue ("kind")."""
    t = v.get("type")
    if t == "money":
        return {"kind": "money", "amount": v["amount"], "currency": v["currency"]}
    if t == "phone":
        return {"kind": "phone", "digits": v["digits"]}
    if t == "code":
        return {"kind": "code", "code": v["code"]}
    if t == "text":
        return {"kind": "text", "text": v["text"], "language": v["language"]}
    return None


def fact_row(fact_id: str) -> dict:
    hit = L.verified(fact_id)
    wire = _wire_value(hit[1]) if hit else None
    if not hit or wire is None:
        return {"id": fact_id, "status": "unsourced"}
    row = hit[0]
    src = L.ledger_sources().get(row["source_id"]) or {}
    publisher = src.get("publisher") or row.get("publisher")
    if not publisher or not row.get("quote"):
        return {"id": fact_id, "status": "unsourced"}
    every = row.get("check_every") or src.get("check_every")
    m = re.fullmatch(r"P(\d+)D", every or "")
    return {
        "id": fact_id, "status": "verified", "value": wire,
        "source": {"id": row["source_id"], "url": row["url"], "publisher": publisher},
        "quote": row["quote"], "quote_language": row.get("quote_language") or "en",
        "retrieved_at": row["retrieved_at"], "check_every_days": int(m.group(1)) if m else None,
    }


def _ledger_desk(did: str) -> dict:
    """A desk Content's desks.yaml does not list yet (Research's desk rows only): its contact facts are the
    <desk>.<kind> rows the ledger has, and its display name is the verified name fact (English only)."""
    refs = [f"{did}.{k}" for k in CONTACT_KINDS if f"{did}.{k}" in L.ledger()]
    name = fact_row(f"{did}.name")
    names = {"en": name["value"]["code"]} if name["status"] == "verified" and name["value"].get("kind") == "code" else {}
    return {"id": did, "pack": did.split(".")[0], "names": names, "desk_facts": refs}


def check_ledger() -> dict:
    from .address import ADDRESS_DESKS, ADDRESS_FACTS  # Who handles my address (FM-MYAD-ADDR)
    desks = _desks()
    out_desks, contact_ids = [], []
    for did in dict.fromkeys([*CHECK_DESKS, *ADDRESS_DESKS]):
        if did in desks:
            d = desks[did]
            refs = [f for f in d.get("fact_refs") or () if f.rsplit(".", 1)[-1] in CONTACT_KINDS]
            entry = {"id": did, "pack": did.split(".")[0], "names": d["name"], "desk_facts": refs}
        else:
            entry = _ledger_desk(did)
        contact_ids += entry["desk_facts"]
        out_desks.append(entry)
    ids = list(dict.fromkeys([*FEE_FACTS, *LISTING_FACTS, *ADDRESS_FACTS, *contact_ids]))
    return {"facts": [fact_row(f) for f in ids], "desks": out_desks}
