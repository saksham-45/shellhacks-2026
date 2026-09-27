"""Optional first step: typed address -> point. Skipped when the phone sends lat/lon
(basis.method = "device_coords").

1. Miami-Dade County address locator (MD_Locator findAddressCandidates). Only a `PointAddress` candidate
   counts: it is the county's point for that address, and it sits on the parcel. Street-interpolated
   candidates are not used, because they can land off the parcel (for 111 NW 1st St the interpolated point
   falls in a different FEMA flood zone). The typed address should carry its ZIP: without it the same street
   address also matches Homestead. basis.method = "county_locator".
2. Fallback, for addresses the county locator doesn't know or when it is down: the U.S. Census geocoder
   (street-interpolated). basis.method = "census_geocoder". Census rejects this box's egress.
"""
from __future__ import annotations

import json
from urllib.parse import urlencode

from .transport import Deadline, Transport
from .types import PinInput, Raw, Request, ResolvedPin

COUNTY_LOCATOR = ("https://gisws.miamidade.gov/arcgis/rest/services/MDC_LocatorsPro/MD_Locator/GeocodeServer/"
                  "findAddressCandidates")
CENSUS = "https://geocoding.geo.census.gov/geocoder/geographies/onelineaddress"
MIN_POINT_ADDRESS_SCORE = 95.0  # below this the county's best PointAddress is a different address


def county_locator_url(address: str) -> str:
    return COUNTY_LOCATOR + "?" + urlencode([("SingleLine", address), ("outFields", "Addr_type,Score"),
                                             ("maxLocations", "5"), ("outSR", "4326"), ("f", "json")])


def geocode_url(address: str) -> str:
    return CENSUS + "?" + urlencode([("address", address), ("benchmark", "Public_AR_Current"),
                                     ("vintage", "Current_Current"), ("layers", "all"), ("format", "json")])


class GeocodeFailed(Exception):
    def __init__(self, message: str, unreachable: bool):
        super().__init__(message)
        self.unreachable = unreachable


def _json(raw: Raw):
    try:
        return json.loads(raw.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def _county_point(raw: Raw) -> tuple[float, float] | None:
    """(lat, lon) of the best PointAddress candidate at or above the score floor, else None."""
    data = _json(raw)
    if not isinstance(data, dict):
        return None
    best = None
    for c in data.get("candidates") or []:
        try:
            if (c.get("attributes") or {}).get("Addr_type") != "PointAddress":
                continue
            score, x, y = float(c["score"]), float(c["location"]["x"]), float(c["location"]["y"])
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        if score >= MIN_POINT_ADDRESS_SCORE and (best is None or score > best[0]):
            best = (score, y, x)
    return (best[1], best[2]) if best else None


def resolve_point(pin: PinInput, transport: Transport, deadline: Deadline) -> ResolvedPin:
    """Device coordinates win; otherwise geocode the address. Raises GeocodeFailed (message has no address)."""
    if pin.has_coords:
        return ResolvedPin(float(pin.lat), float(pin.lon), pin.address, "device_coords")
    if not pin.address:
        raise GeocodeFailed("pin has neither coordinates nor an address", unreachable=False)

    county = transport.fetch(Request(county_locator_url(pin.address)), deadline)
    if not county.error:
        point = _county_point(county)
        if point:
            return ResolvedPin(point[0], point[1], pin.address, "county_locator",
                               evidence={"url": county.request.url, "retrieved_at": county.retrieved_at})

    raw = transport.fetch(Request(geocode_url(pin.address)), deadline)
    if raw.error:
        raise GeocodeFailed(f"geocoder: {raw.error}", unreachable=raw.unreachable or bool(county.error))
    data = _json(raw)
    if data is None:
        raise GeocodeFailed("geocoder answered with a non-JSON page (request rejected)", unreachable=True)
    try:
        match = data["result"]["addressMatches"][0]
        x, y = float(match["coordinates"]["x"]), float(match["coordinates"]["y"])
    except (KeyError, IndexError, TypeError, ValueError):
        raise GeocodeFailed("geocoder found no match for the address", unreachable=bool(county.error)) from None
    return ResolvedPin(y, x, pin.address, "census_geocoder",
                       evidence={"url": raw.request.url, "retrieved_at": raw.retrieved_at})
