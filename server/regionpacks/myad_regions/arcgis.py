"""ArcGIS REST helpers. Always `/query` with point geometry and esriSpatialRelIntersects, explicit outFields,
never `/identify` (it returns neighbouring routes). An error body inside HTTP 200 is an error, not empty.
Coded values are decoded only from the layer's own domain (`<layer>?f=json`)."""
from __future__ import annotations

import json
import math
import re
from urllib.parse import urlencode

from .types import Raw

MD = "https://gisweb.miamidade.gov/arcgis/rest/services"
MIAMI = "https://gis.miami.gov/gis/rest/services"


class BadResponse(Exception):
    """The source answered, but not with something we can use (error-in-200, non-JSON, unmapped code)."""


def point_query_url(layer: str, lat: float, lon: float, out_fields: list[str] | tuple[str, ...], *,
                    buffer_m: int | None = None, return_geometry: bool = False) -> str:
    if "/identify" in layer or "*" in out_fields or not out_fields:
        raise ValueError("point queries use /query with explicit outFields")
    geometry = json.dumps({"x": lon, "y": lat, "spatialReference": {"wkid": 4326}}, separators=(",", ":"))
    params: list[tuple[str, str]] = [("geometry", geometry), ("geometryType", "esriGeometryPoint"),
                                     ("inSR", "4326"), ("spatialRel", "esriSpatialRelIntersects")]
    if buffer_m is not None:
        params += [("distance", str(buffer_m)), ("units", "esriSRUnit_Meter")]
    params += [("outFields", ",".join(out_fields)), ("returnGeometry", "true" if return_geometry else "false")]
    if return_geometry:
        params.append(("outSR", "4326"))
    params.append(("f", "json"))
    return f"{layer}/query?{urlencode(params)}"


def where_query_url(layer: str, where: str, out_fields: list[str] | tuple[str, ...]) -> str:
    if "*" in out_fields or not out_fields:
        raise ValueError("explicit outFields")
    return f"{layer}/query?" + urlencode([("where", where), ("outFields", ",".join(out_fields)),
                                          ("returnGeometry", "false"), ("f", "json")])


def layer_meta_url(layer: str) -> str:
    return f"{layer}?f=json"


def parse_json(raw: Raw) -> dict:
    """The JSON body, or BadResponse (HTML reject page, ArcGIS error inside a 200, not an object)."""
    try:
        data = json.loads(raw.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BadResponse("response is not JSON") from None
    if not isinstance(data, dict):
        raise BadResponse("response is not a JSON object")
    if "error" in data:
        err = data["error"] if isinstance(data["error"], dict) else {}
        raise BadResponse(f"ArcGIS error in HTTP {raw.status}: code {err.get('code')}")
    return data


def features(raw: Raw) -> list[dict]:
    data = parse_json(raw)
    if "features" not in data:
        raise BadResponse("query response has no features array")
    return data["features"]


def domain(meta: dict, field: str) -> dict:
    """code -> name from the layer's own codedValue domain for `field`."""
    for f in meta.get("fields") or []:
        if f.get("name") == field:
            d = f.get("domain") or {}
            if d.get("type") != "codedValue":
                raise BadResponse(f"field {field} has no coded-value domain")
            return {str(c["code"]): str(c["name"]) for c in d.get("codedValues") or []}
    raise BadResponse(f"layer has no field {field}")


_DAY = {"sun": "sunday", "sunday": "sunday", "mon": "monday", "monday": "monday", "tue": "tuesday",
        "tues": "tuesday", "tuesday": "tuesday", "wed": "wednesday", "wednesday": "wednesday",
        "thu": "thursday", "thur": "thursday", "thurs": "thursday", "thursday": "thursday",
        "fri": "friday", "friday": "friday", "sat": "saturday", "saturday": "saturday"}


def days_from_domain_name(name: str) -> list[str]:
    """Weekdays from a domain *name* ("Tue", "Tue and Fri", "Tuesday Friday", "FRIDAY"). Any word that is not
    a weekday (for example "Every Day") raises BadResponse: unmapped until handled on purpose."""
    words = [w.lower() for w in re.findall(r"[A-Za-z]+", name) if w.lower() != "and"]
    if not words or any(w not in _DAY for w in words):
        raise BadResponse(f"domain name {name!r} does not map to weekdays")
    return [_DAY[w] for w in words]


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    return 2 * r * math.asin(math.sqrt(math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2))


def _seg_dist(px, py, ax, ay, bx, by) -> float:  # local equirectangular metres (x=lon, y=lat)
    k = math.cos(math.radians(py)) * 111320.0
    m = 110540.0
    ax, ay, bx, by = (ax - px) * k, (ay - py) * m, (bx - px) * k, (by - py) * m
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0 if length == 0 else max(0.0, min(1.0, (-ax * dx - ay * dy) / length))
    return math.hypot(ax + t * dx, ay + t * dy)


def _inside(px, py, ring) -> bool:
    c = False
    for i in range(len(ring)):
        (x1, y1), (x2, y2) = ring[i][:2], ring[i - 1][:2]
        if (y1 > py) != (y2 > py) and px < (x2 - x1) * (py - y1) / (y2 - y1) + x1:
            c = not c
    return c


def polygon_distance_m(lat: float, lon: float, rings: list) -> float:
    """0 inside the polygon, else metres to the nearest edge."""
    if sum(_inside(lon, lat, r) for r in rings) % 2:
        return 0.0
    return min(_seg_dist(lon, lat, *r[i - 1][:2], *r[i][:2]) for r in rings for i in range(1, len(r)))


_SUFFIX = {"AVENUE": "AVE", "AV": "AVE", "STREET": "ST", "ROAD": "RD", "COURT": "CT", "LANE": "LN",
           "PLACE": "PL", "TERRACE": "TER", "DRIVE": "DR", "BOULEVARD": "BLVD", "HIGHWAY": "HWY",
           "CIRCLE": "CIR", "WAY": "WAY", "PARKWAY": "PKWY"}


def street_key(address: str | None) -> str | None:
    """House number + street, normalized for matching the county's TRUE_SITE_ADDR ("11200 SW 137 AVE")."""
    if not address:
        return None
    first = address.split(",")[0].upper()
    words = re.findall(r"[A-Z0-9]+", first)
    out = []
    for w in words:
        w = re.sub(r"^(\d+)(ST|ND|RD|TH)$", r"\1", w)
        out.append(_SUFFIX.get(w, w))
    return " ".join(out) if out and out[0].isdigit() else None
