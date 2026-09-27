"""Core value types and the wire shape of one fact result (see ../CONTRACT.md)."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Literal

Status = Literal["ok", "not_applicable", "unavailable", "error", "unsourced"]
STATUSES = ("ok", "not_applicable", "unavailable", "error", "unsourced")
FACT_ID = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$")

# The ten wire value types: exactly ADCore's FactValue cases (ARCHITECTURE.md §13.z). Nothing else.
VALUE_TYPES = frozenset({"text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag"})
WEEKDAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")


@dataclass(frozen=True)
class PinInput:
    """What the phone sends: the address, plus lat/lon when the device already has them."""
    address: str | None = None
    lat: float | None = None
    lon: float | None = None

    @property
    def has_coords(self) -> bool:
        return self.lat is not None and self.lon is not None

    @classmethod
    def of(cls, pin: "PinInput | dict") -> "PinInput":
        if isinstance(pin, PinInput):
            return pin
        return cls(address=pin.get("address"), lat=pin.get("lat"), lon=pin.get("lon"))


@dataclass(frozen=True)
class ResolvedPin:
    """A point every adapter takes. `method` is "device_coords", "county_locator" or "census_geocoder"."""
    lat: float
    lon: float
    address: str | None
    method: str
    evidence: dict[str, Any] | None = None  # geocoder url + retrieved_at when geocoded


@dataclass(frozen=True)
class Request:
    url: str  # exact GET URL; never carries a key
    method: Literal["GET"] = "GET"


@dataclass(frozen=True)
class Raw:
    request: Request
    status: int | None
    body: bytes
    retrieved_at: str  # ISO 8601 with offset, from the response time, never the parse clock
    error: str | None = None
    unreachable: bool = False  # True: the source exists but could not be reached or timed out -> "unavailable"


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


# ---- typed values ----

def v_text(text: str, language: str = "en") -> dict:
    """The source's own wording in a natural language (BCP-47 tag), e.g. the county's land-use text."""
    return {"type": "text", "text": text, "language": language}


def v_code(code: str) -> dict:
    """Never translated: folio, district id, grade span, member and route names, utility code."""
    return {"type": "code", "code": code}


def v_codes(codes: list[str]) -> dict:
    return {"type": "codes", "codes": list(codes)}


def v_phone(digits: str) -> dict:
    return {"type": "phone", "digits": digits}


def v_quantity(amount: int | float, unit: str) -> dict:
    """A JSON number, as /v1 QuantityValue and ADCore expect. Year built is quantity(1984, "year")."""
    return {"type": "quantity", "amount": amount, "unit": unit}


def v_weekdays(days: list[str]) -> dict:
    return {"type": "weekdays", "days": sorted(set(days), key=WEEKDAYS.index)}


def v_flag(value: bool) -> dict:
    return {"type": "flag", "value": bool(value)}


def v_place(name: str, lat: float, lon: float, address: str | None) -> dict:
    """ADCore Place, nested as /v1 PlaceValue: {place: {name, coordinate: {latitude, longitude}, address}}."""
    return {"type": "place", "place": {"name": name, "coordinate": {"latitude": lat, "longitude": lon},
                                       "address": address}}


@dataclass
class FactResult:
    fact_id: str
    pack: str
    status: Status
    jurisdiction: str
    desk: str                          # manifest desk id; never null, on every status
    source_id: str | None = None       # None only for "unsourced" (no source exists)
    publisher: str | None = None
    url: str | None = None             # exact request URL (no secrets); None only for "unsourced"
    retrieved_at: str | None = None
    value: dict | None = None
    quote: str | None = None
    basis: dict | None = None
    not_applicable: dict | None = None
    error: str | None = None
    check_every: str | None = None
    ledger_id: str | None = None      # set by the runtime: fixture mode <fact_id>.demo.<pin>, live == fact_id
    is_demo: bool = False             # fixture mode: the ledger status of this answer is "demo"
    extra: dict = field(default_factory=dict)  # internal only (e.g. MUNICID for boundaries); not serialized

    def to_json(self) -> dict:
        return {
            "fact_id": self.fact_id, "ledger_id": self.ledger_id or self.fact_id, "pack": self.pack,
            "status": self.status, "is_demo": self.is_demo, "value": self.value,
            "source_id": self.source_id, "publisher": self.publisher, "url": self.url,
            "retrieved_at": self.retrieved_at, "quote": self.quote, "jurisdiction": self.jurisdiction,
            "desk": self.desk, "basis": self.basis, "not_applicable": self.not_applicable,
            "error": self.error, "check_every": self.check_every,
        }


VALUE_FIELDS = {"text": ("text", "language"), "code": ("code",), "codes": ("codes",), "phone": ("digits",),
                "date": ("date",), "money": ("amount", "currency"), "quantity": ("amount", "unit"),
                "weekdays": ("days",), "place": ("place",), "flag": ("value",)}
# Keys allowed per type beyond "type" (the /v1 models forbid extra keys).
VALUE_KEYS = {**{t: set(k) for t, k in VALUE_FIELDS.items()}, "place": {"place"}}


def validate_value(v: Any) -> list[str]:
    if not isinstance(v, dict) or v.get("type") not in VALUE_TYPES:
        got = v.get("type") if isinstance(v, dict) else v
        return [f"value type {got!r} is not one of the ten ADCore cases {sorted(VALUE_TYPES)}"]
    t = v["type"]
    errs = [f"{t} value missing {k}" for k in VALUE_FIELDS[t] if v.get(k) in (None, "", [])]
    if t == "weekdays" and any(d not in WEEKDAYS for d in v.get("days") or []):
        errs.append(f"bad weekday in {v.get('days')}")
    if t == "flag" and not isinstance(v.get("value"), bool):
        errs.append("flag value is not a bool")
    extra = set(v) - {"type"} - VALUE_KEYS[t]
    if extra:
        errs.append(f"{t} value has unexpected keys {sorted(extra)}")
    if t == "quantity":
        a = v.get("amount")
        if isinstance(a, bool) or not isinstance(a, (int, float)):
            errs.append("quantity amount must be a JSON number")
        elif a == 0:
            errs.append("quantity 0 used as a value (none recorded must be an outcome, not a sentinel)")
    if t == "place":
        pl = v.get("place") if isinstance(v.get("place"), dict) else {}
        c = pl.get("coordinate") if isinstance(pl.get("coordinate"), dict) else {}
        if not pl.get("name"):
            errs.append("place missing name")
        if not all(isinstance(c.get(k), float) for k in ("latitude", "longitude")):
            errs.append("place coordinate needs float latitude and longitude")
        if set(pl) - {"name", "coordinate", "address"} or set(c) - {"latitude", "longitude"}:
            errs.append("place has unexpected keys")
    if t == "codes" and not all(isinstance(c, str) and c for c in v.get("codes") or []):
        errs.append("codes must be non-empty strings")
    return errs


def validate_result(r: dict) -> list[str]:
    """Shape rules every result obeys. Returns problems (empty means valid)."""
    errs: list[str] = []
    fid = r.get("fact_id") or ""
    if not FACT_ID.match(fid):
        errs.append(f"bad fact_id {fid!r}")
    elif not fid.startswith(str(r.get("pack")) + "."):
        errs.append(f"{fid}: not prefixed with pack {r.get('pack')!r}")
    lid = r.get("ledger_id") or ""
    if r.get("is_demo") is True:
        if not re.fullmatch(re.escape(fid) + r"\.demo\.pin-[a-z0-9-]+", lid):
            errs.append(f"{fid}: demo ledger_id {lid!r} is not <fact_id>.demo.<pin>")
    elif r.get("is_demo") is False:
        if lid != fid:
            errs.append(f"{fid}: live ledger_id {lid!r} must equal fact_id")
    else:
        errs.append(f"{fid}: is_demo must be a bool")
    status = r.get("status")
    if status not in STATUSES:
        errs.append(f"{fid}: bad status {status!r}")
    if not r.get("desk"):
        errs.append(f"{fid}: missing desk")
    if not r.get("jurisdiction"):
        errs.append(f"{fid}: missing jurisdiction")
    if status != "unsourced":
        for k in ("source_id", "publisher", "url", "retrieved_at"):
            if not r.get(k):
                errs.append(f"{fid}: missing {k}")
        url = r.get("url") or ""
        if url and not url.startswith(("https://", "http://")):
            errs.append(f"{fid}: url is not http(s)")
        if "/identify" in url:
            errs.append(f"{fid}: uses /identify")
        try:
            if datetime.fromisoformat(r.get("retrieved_at") or "").utcoffset() is None:
                errs.append(f"{fid}: retrieved_at has no offset")
        except ValueError:
            errs.append(f"{fid}: retrieved_at not ISO 8601")
    value = r.get("value")
    if status == "ok":
        errs += [f"{fid}: {e}" for e in validate_value(value)]
        if not r.get("quote"):
            errs.append(f"{fid}: ok without quote")
    elif value is not None:
        errs.append(f"{fid}: value on a {status} result")
    if status == "not_applicable":
        na = r.get("not_applicable") or {}
        if not na.get("reason"):
            errs.append(f"{fid}: not_applicable without reason")
        d = na.get("defer_to")
        if d is not None and (set(d) != {"pack_id", "fact_id"} or not str(d["fact_id"]).startswith(str(d["pack_id"]) + ".")):
            errs.append(f"{fid}: bad defer_to {d!r} (FactRef JSON is {{pack_id, fact_id}})")
    if status in ("error", "unavailable") and not r.get("error"):
        errs.append(f"{fid}: {status} without message")
    return errs
