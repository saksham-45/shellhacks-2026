"""Geocode demo pins with a provider chain; official (Census) first. Cached in state."""
from __future__ import annotations

import datetime as dt
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import yaml

from .net import Fetcher
from .schedule import parse_ts
from .state import State

CENSUS = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress"
ARCGIS_WORLD = "https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates"
PIN_TTL = dt.timedelta(days=30)


@dataclass
class Pin:
    id: str
    address: str
    x: float  # lon, WGS84
    y: float  # lat
    provider: str
    official: bool
    matched_address: str
    source_url: str
    retrieved_at: str


class GeocodeFailed(RuntimeError):
    pass


def load_pins(path: Path) -> list[dict[str, Any]]:
    return (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("pins", [])


def _census(f: Fetcher, address: str) -> tuple[float, float, str, str, str] | str:
    r = f.get(CENSUS, {"address": address, "benchmark": "Public_AR_Current", "format": "json"})
    if not r.ok:
        return f"census: {r.error}"
    try:
        m = r.json()["result"]["addressMatches"]
    except (ValueError, KeyError):
        return "census: unexpected response"
    if not m:
        return "census: no match"
    c = m[0]["coordinates"]
    return float(c["x"]), float(c["y"]), m[0].get("matchedAddress", ""), r.url, r.retrieved_at


def _arcgis(f: Fetcher, address: str) -> tuple[float, float, str, str, str] | str:
    r = f.get(ARCGIS_WORLD, {"SingleLine": address, "f": "json", "maxLocations": "1", "outSR": "4326"})
    if not r.ok:
        return f"arcgis-world: {r.error}"
    try:
        cands = r.json().get("candidates") or []
    except ValueError:
        return "arcgis-world: unexpected response"
    if not cands or cands[0].get("score", 0) < 90:
        return "arcgis-world: no confident match"
    c = cands[0]
    return float(c["location"]["x"]), float(c["location"]["y"]), c.get("address", ""), r.url, r.retrieved_at


PROVIDERS = [("census-geocoder", True, _census), ("arcgis-world-geocoder", False, _arcgis)]


def resolve_pin(pin: dict[str, Any], fetcher: Fetcher, state: State | None = None, *, now: dt.datetime | None = None) -> Pin:
    now = now or dt.datetime.now(dt.timezone.utc)
    cached = state.data["pins"].get(pin["id"]) if state else None
    if cached and cached.get("address") == pin["address"]:
        t = parse_ts(cached.get("retrieved_at"))
        if t and now - t < PIN_TTL and (cached.get("official") or not _official_retry_due(cached, now)):
            return Pin(**{k: cached[k] for k in Pin.__dataclass_fields__})
    errors = []
    for name, official, fn in PROVIDERS:
        res = fn(fetcher, pin["address"])
        if isinstance(res, str):
            errors.append(res)
            continue
        x, y, matched, url, ts = res
        p = Pin(pin["id"], pin["address"], x, y, name, official, matched, url, ts)
        if state is not None:
            state.data["pins"][pin["id"]] = {**asdict(p), "errors_before": errors}
        return p
    raise GeocodeFailed("; ".join(errors))


def _official_retry_due(cached: dict[str, Any], now: dt.datetime) -> bool:
    """A secondary-provider pin is re-tried against the official provider after a day."""
    t = parse_ts(cached.get("retrieved_at"))
    return t is None or now - t > dt.timedelta(days=1)
