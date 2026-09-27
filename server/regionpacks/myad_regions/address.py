"""Who handles my address (FM-MYAD-ADDR, Discovery Batch 10 #1): the county's no-key 311 map layers, one address in.

This module is the server-side half of the phone's AddressCheck (ADCityPack/Checks/AddressCheck.swift):
  - LAYERS: the 311CRM point layers the phone queries, with the only fields it reads. The Swift side builds the same
    URLs (tests compare them against the recorded fixtures).
  - cached_response(): one recorded county answer for a demo pin, minimized to those fields, with each layer's own
    request URL and retrieved_at. The phone replays it after 4 s or when the presenter taps the replay chip.
  - address_rules(): the rules that turn a municipality name into "which police" and "does the Sheriff's online
    report cover it". A rule ships as `verified` only when Research's ledger row is verified AND its quote names
    every area the rule lists; otherwise it ships `unsourced` and the phone says "ask 311" instead.

Nothing here decides a school placement or whether a crime qualifies for online reporting; the card names the office.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from urllib.parse import urlencode, urlparse

from . import ledger as L

DISPLAY = "https://giswspro.miamidade.gov/ArcGIS/rest/services/311/311CRM_Display/MapServer"
CRM = "https://giswspro.miamidade.gov/ArcGIS/rest/services/311/311CRM/MapServer"
SRC_DISPLAY = "us-fl-miamidade.gis-311crm-display"
SRC_CRM = "us-fl-miamidade.gis-311crm"
# layer 21 (COM Bulky Trash Route) publishes TRASHDAY letters with no code list; the City's own trash layer publishes
# the list for the same field (SW_Service_Days). The box cannot complete TLS to gis.miami.gov, so its recorded copy is
# fixtures/_layers/trash-city.json (captured by hand, see its .meta.json); the phone fetches it live.
CITY_TRASH_LAYER = "https://gis.miami.gov/gis/rest/services/SolidWaste/TrashRoutes/MapServer/0"
SRC_CITY_TRASH = "us-fl-miami.gis-trash-routes"


@dataclass(frozen=True)
class Layer:
    key: str
    service: str
    number: int
    fields: tuple[str, ...]
    source_id: str
    # Coded-value field whose names the phone shows instead of the code (decoded from the layer's own metadata).
    domain_field: str | None = None

    @property
    def url(self) -> str:
        return f"{self.service}/{self.number}"

    def query_url(self, lat: float, lon: float) -> str:
        """Point-in-polygon, never identify. Parameter order is part of the contract with AddressCheck.swift."""
        return f"{self.url}/query?" + urlencode([
            ("geometry", f"{lon},{lat}"), ("geometryType", "esriGeometryPoint"), ("inSR", "4326"),
            ("spatialRel", "esriSpatialRelIntersects"), ("outFields", ",".join(self.fields)),
            ("returnGeometry", "false"), ("f", "json")])


LAYERS: tuple[Layer, ...] = (
    Layer("municipality", DISPLAY, 1, ("NAME",), SRC_DISPLAY),
    Layer("county-garbage", DISPLAY, 3, ("WEEKDAYS",), SRC_DISPLAY),
    Layer("county-recycling", DISPLAY, 4, ("WEEKDAY", "PICKUPWEEK"), SRC_DISPLAY),
    Layer("county-bulky-book", DISPLAY, 7, ("LABEL",), SRC_DISPLAY),
    Layer("water", DISPLAY, 14, ("UTILITYNAME",), SRC_DISPLAY, domain_field="UTILITYNAME"),
    Layer("sewer", DISPLAY, 15, ("UTILITYNAME",), SRC_DISPLAY, domain_field="UTILITYNAME"),
    Layer("city-garbage", DISPLAY, 19, ("GRAPCKDAYS",), SRC_DISPLAY),
    Layer("city-recycling", DISPLAY, 20, ("RECYROUTE",), SRC_DISPLAY),
    Layer("city-bulky", DISPLAY, 21, ("TRASHDAY",), SRC_DISPLAY),
    Layer("elementary", CRM, 18, ("DISPLAYNAME", "ADDRESS", "CITY", "ZIPCODE", "PHONE", "GRADES"), SRC_CRM),
    Layer("police-grid", CRM, 38, ("DISTNAME",), SRC_CRM),
)
LAYER_BY_KEY = {x.key: x for x in LAYERS}


def fold(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).upper()
    return " ".join(re.findall(r"[A-Z0-9]+", s))


def minimize_features(layer: Layer, body: dict) -> list[dict]:
    """Only the layer's declared fields, in order; blank values dropped. Raises on an ArcGIS error body."""
    if body.get("error"):
        raise ValueError(f"{layer.key}: layer error {body['error']}")
    out = []
    for f in body.get("features") or []:
        a = f.get("attributes") or {}
        kept = {k: a[k] for k in layer.fields if a.get(k) not in (None, "") and str(a[k]).strip()}
        out.append(kept)
    return out


def domain_codes(meta: dict, field: str) -> dict[str, str]:
    for f in meta.get("fields") or []:
        if f.get("name") == field and (f.get("domain") or {}).get("type") == "codedValue":
            return {str(c["code"]): str(c["name"]) for c in f["domain"]["codedValues"]}
    return {}


# ---------------------------------------------------------------------------------------------------------------
# Rules (municipality name -> police agency / online-report coverage), each gated on a verified ledger quote.

@dataclass(frozen=True)
class Area:
    municipality: str               # the Municipality Name layer's NAME value
    quote_words: tuple[str, ...]    # phrases (folded); the verified quote must contain one of them for this area
    host: str | None = None         # when set, the gating row's url must be on this host (the city's own site)


SHERIFF_AREAS = (
    Area("UNINCORPORATED MIAMI-DADE", ("UNINCORPORATED",)),
    Area("CUTLER BAY", ("CUTLER BAY",)),
    Area("PALMETTO BAY", ("PALMETTO BAY",)),
    Area("MIAMI LAKES", ("MIAMI LAKES",)),
)
# "citizens of Miami" names the city only on the City of Miami's own site.
CITY_OF_MIAMI = (Area("MIAMI", ("CITY OF MIAMI", "CITIZENS OF MIAMI"), host="www.miami.gov"),)

RULES = (
    # (rule id, gating facts (first is the rule's fact; any one naming an area confirms it), desk, areas)
    ("online-report", ("us-fl-miamidade.sheriff.online-report-area",), "us-fl-miamidade.sheriff", SHERIFF_AREAS),
    ("police.sheriff", ("us-fl-miamidade.sheriff.service-area", "us-fl-miamidade.sheriff.contract-towns"),
     "us-fl-miamidade.sheriff", SHERIFF_AREAS),
    ("police.city-of-miami", ("us-fl-miami.police.service-area",), "us-fl-miami.police", CITY_OF_MIAMI),
)
ONLINE_REPORT_URL = "us-fl-miamidade.sheriff.online-report-url"
MDWS_MEANING = "us-fl-miamidade.utility.mdws-meaning"
ADDRESS_DESKS = ("us-fl-miamidade.sheriff", "us-fl-miami.police", "us-fl-miamidade.wasd",
                 "us-fl-miamidade.m-dcps", "us-fl-miamidade.311")
ADDRESS_FACTS = (ONLINE_REPORT_URL, MDWS_MEANING, *(f for r in RULES for f in r[1]))


def _names(row: dict, area: Area) -> bool:
    if area.host and urlparse(row.get("url") or "").hostname != area.host:
        return False
    q = f" {fold(row.get('quote') or '')} "
    return any(f" {w} " in q for w in area.quote_words)


def rule_status(fact_ids: tuple[str, ...], areas: tuple[Area, ...]) -> tuple[list[Area], list[Area], str | None]:
    """(named, unconfirmed, why). An area counts only when a verified quote names it; the rest stay unconfirmed,
    so a partial quote confirms only the areas it names (never the whole list)."""
    rows = [r for r in (L.ledger().get(f) for f in fact_ids)
            if r and r.get("status") == "verified" and r.get("url") and r.get("source_id")]
    if not rows:
        return [], list(areas), "no verified ledger row"
    named = [a for a in areas if any(_names(r, a) for r in rows)]
    missing = [a for a in areas if a not in named]
    return named, missing, ("quote does not name " + ", ".join(a.municipality for a in missing)) if missing else None


def address_rules() -> dict:
    rules = []
    for rid, fids, desk, areas in RULES:
        named, missing, why = rule_status(fids, areas)
        e = {"id": rid, "fact": fids[0], **({"also_facts": list(fids[1:])} if fids[1:] else {}), "status": "verified" if named else "unsourced", "desk": desk,
             "municipalities": [a.municipality for a in named], "unconfirmed": [a.municipality for a in missing]}
        if why:
            e["why_unsourced" if not named else "why_partial"] = why
        rules.append(e)
    return {
        "layers": [{"key": x.key, "url": x.url, "fields": list(x.fields), "source_id": x.source_id,
                    **({"domain_field": x.domain_field} if x.domain_field else {})} for x in LAYERS],
        "city_trash_domain": {"url": CITY_TRASH_LAYER, "field": "TRASHDAY", "source_id": SRC_CITY_TRASH},
        "rules": rules,
        "online_report_url_fact": ONLINE_REPORT_URL,
        "water_meaning_fact": MDWS_MEANING,
        "fallback_desk": "us-fl-miamidade.311",
        "school_desk": "us-fl-miamidade.m-dcps",
    }
