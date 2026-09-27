"""Deterministic adapters for us-fl-miamidade and us-fl-miami. One class per manifest adapter id.

Every adapter emits exactly the fact ids its manifest declares, on every run, so fact ids are stable
across requests and pins. Adapters hold no mutable state; instances are shared read-only.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

from . import arcgis as ag
from . import ledger as L
from .arcgis import MD, MIAMI, BadResponse
from .manifests import AdapterDecl, adapter_decl, defer_target, sources
from .transport import Deadline, Transport
from .types import (FactResult, Raw, Request, ResolvedPin, now_iso, v_code, v_codes, v_flag, v_phone, v_place,
                    v_quantity, v_text, v_weekdays)

DATA = Path(__file__).resolve().parent.parent / "data"

# not_applicable reasons are StringKeys in ADCityPack.xcstrings (table "ADCityPack").
NA_OUTSIDE_LAYER = "regions.na.outside-layer"            # the layer has no feature at this pin
NA_COUNTY_TRASH = "regions.na.county-trash-not-serviced"  # county garbage/recycling routes do not cover the pin
NA_CITY_TRASH = "regions.na.city-trash-not-serviced"
NA_NONE_NEARBY = "regions.na.none-within-radius"
NA_YEAR_NOT_RECORDED = "regions.na.parcel-year-not-recorded"
NA_NO_PARCEL = "regions.na.no-parcel-nearby"
NA_REASONS = (NA_OUTSIDE_LAYER, NA_COUNTY_TRASH, NA_CITY_TRASH, NA_NONE_NEARBY, NA_YEAR_NOT_RECORDED, NA_NO_PARCEL)


@dataclass(frozen=True)
class Ctx:
    pin: ResolvedPin
    chain: tuple[str, ...]  # resolved pack ids, country first


@dataclass(frozen=True)
class Out:
    """One parsed fact before it becomes a FactResult. `raw` is the response it came from."""
    fact_id: str
    raw: Raw
    value: dict | None = None
    quote: str | None = None
    lookup: str | None = None
    distance_m: float | None = None
    na_reason: str | None = None
    defer_to: dict | None = None
    error: str | None = None


def ok(fid, raw, value, quote, lookup="point_in_polygon", distance_m=None) -> Out:
    return Out(fid, raw, value=value, quote=quote, lookup=lookup, distance_m=distance_m)


def na(fid, raw, reason, defer_to=None, lookup="point_in_polygon") -> Out:
    return Out(fid, raw, na_reason=reason, defer_to=defer_to, lookup=lookup)


def digits(phone: str | None) -> str | None:
    d = "".join(ch for ch in phone or "" if ch.isdigit())
    return d or None


def _str(v) -> str | None:
    if v is None:
        return None
    s = str(v).strip()
    return s or None


class Adapter:
    adapter_id: str = ""

    @property
    def decl(self) -> AdapterDecl:
        return adapter_decl(self.adapter_id)

    @property
    def question(self) -> str:
        return self.decl.answers[0]

    # -- to override --
    def plan(self, pin: ResolvedPin) -> list[Request]:
        raise NotImplementedError

    def parse(self, pin: ResolvedPin, raws: list[Raw], ctx: Ctx) -> list[Out]:
        raise NotImplementedError

    def fetch_all(self, pin: ResolvedPin, transport: Transport, deadline: Deadline) -> list[Raw]:
        return [transport.fetch(r, deadline) for r in self.plan(pin)]

    # -- shared --
    def run(self, ctx: Ctx, transport: Transport, deadline: Deadline) -> list[FactResult]:
        """Never raises for source problems: unreachable/timeout -> unavailable, bad response -> error."""
        pin = ctx.pin
        try:
            raws = self.fetch_all(pin, transport, deadline)
        except BadResponse as e:  # a follow-up request could not be planned from a bad first response
            return self._all(ctx, "error", None, str(e))
        failed = next((r for r in raws if r.unreachable or r.error), None)
        if failed is not None:
            return self._all(ctx, "unavailable" if failed.unreachable else "error", failed, failed.error)
        try:
            outs = self.parse(pin, raws, ctx)
        except BadResponse as e:
            return self._all(ctx, "error", raws[-1], str(e))
        got = {o.fact_id: o for o in outs}
        extra = set(got) - set(self.decl.fact_ids)
        if extra:
            raise AssertionError(f"{self.adapter_id} emitted undeclared fact ids {sorted(extra)}")
        results = []
        for fid in self.decl.fact_ids:
            o = got.get(fid)
            results.append(self._result(ctx, o) if o else self._one(ctx, fid, "error", raws[-1] if raws else None,
                                                                    "adapter produced no answer for this fact"))
        return results

    def _base(self, ctx: Ctx, fid: str, raw: Raw | None) -> FactResult:
        src = sources()[self.decl.sources[0]] if self.decl.sources else None
        return FactResult(fact_id=fid, pack=self.decl.pack, status="error", jurisdiction=self.decl.pack,
                          desk=self.decl.desk, source_id=src.id if src else None,
                          publisher=src.publisher if src else None,
                          url=raw.request.url if raw else None,
                          retrieved_at=raw.retrieved_at if raw else (now_iso() if src else None),
                          check_every=src.check_every if src else None)

    def _one(self, ctx, fid, status, raw, error) -> FactResult:
        r = self._base(ctx, fid, raw)
        r.status, r.error = status, error
        r.basis = {"method": ctx.pin.method}
        return r

    def _all(self, ctx, status, raw, error) -> list[FactResult]:
        if raw is None:
            reqs = self.plan(ctx.pin)
            raw = Raw(reqs[0], None, b"", now_iso(), error=error) if reqs else None
        return [self._one(ctx, fid, status, raw, error) for fid in self.decl.fact_ids]

    def _result(self, ctx: Ctx, o: Out) -> FactResult:
        r = self._base(ctx, o.fact_id, o.raw)
        r.basis = {"method": ctx.pin.method, "lookup": o.lookup}
        if o.distance_m is not None:
            r.basis["distance_m"] = round(o.distance_m, 1)
        if o.error:
            r.status, r.error = "error", o.error
        elif o.na_reason:
            r.status = "not_applicable"
            r.not_applicable = {"reason": o.na_reason, "defer_to": o.defer_to}
        else:
            r.status, r.value, r.quote = "ok", o.value, o.quote
        return r


# ---------------------------------------------------------------- point-in-polygon layers

class PointLayer(Adapter):
    layer: str = ""
    out_fields: tuple[str, ...] = ()
    na_reason: str = NA_OUTSIDE_LAYER
    domain_layer: bool = False  # also fetch `<layer>?f=json` to decode coded values

    def plan(self, pin):
        reqs = [Request(ag.point_query_url(self.layer, pin.lat, pin.lon, self.out_fields))]
        if self.domain_layer:
            reqs.append(Request(ag.layer_meta_url(self.layer)))
        return reqs

    def parse(self, pin, raws, ctx):
        feats = ag.features(raws[0])
        meta = ag.parse_json(raws[1]) if self.domain_layer else {}
        if not feats:
            defer = self.defer(ctx)
            return [na(fid, raws[0], self.na_reason, defer) for fid in self.decl.fact_ids]
        return self.facts(feats[0]["attributes"], raws[0], meta, ctx)

    def defer(self, ctx: Ctx) -> dict | None:
        return None

    def facts(self, a: dict, raw: Raw, meta: dict, ctx: Ctx) -> list[Out]:
        raise NotImplementedError


class Municipality(PointLayer):
    adapter_id = "us-fl-miamidade.municipality"
    layer = f"{MD}/MD_MDPDViewer/MapServer/8"
    out_fields = ("NAME", "MUNICID")

    def facts(self, a, raw, meta, ctx):
        name, mid = _str(a.get("NAME")), _str(a.get("MUNICID"))
        if not name or not mid:
            raise BadResponse("municipality feature without NAME/MUNICID")
        q = f"NAME: {name}; MUNICID: {mid}"
        return [ok("us-fl-miamidade.government.municipality", raw, v_code(name), q),
                ok("us-fl-miamidade.government.municipality-id", raw, v_code(mid), q)]


class _Trash(PointLayer):
    domain_layer = True

    def defer(self, ctx):
        # Only a MORE local pack can take over (county trash inside the City of Miami -> the city's fact).
        return defer_target(self.question, ctx.chain, exclude_pack=self.decl.pack)


class CountyGarbage(_Trash):
    adapter_id = "us-fl-miamidade.trash-county-garbage"
    layer = f"{MD}/CommunityServices/MD_GarbageRecycle/MapServer/1"
    out_fields = ("WEEKDAYS", "ROUTE")
    na_reason = NA_COUNTY_TRASH

    def facts(self, a, raw, meta, ctx):
        code = _str(a.get("WEEKDAYS"))
        names = ag.domain(meta, "WEEKDAYS")
        if code not in names:
            raise BadResponse("WEEKDAYS value is not in the layer's domain")
        days = ag.days_from_domain_name(names[code])
        return [ok("us-fl-miamidade.trash.garbage-days", raw, v_weekdays(days),
                   f"WEEKDAYS: {code} (ROUTE {a.get('ROUTE')})")]


class CountyRecycling(_Trash):
    adapter_id = "us-fl-miamidade.trash-county-recycling"
    layer = f"{MD}/CommunityServices/MD_GarbageRecycle/MapServer/2"
    out_fields = ("WEEKDAY", "PICKUPWEEK", "DESCRIPTION")
    na_reason = NA_COUNTY_TRASH

    def facts(self, a, raw, meta, ctx):
        day, week = _str(a.get("WEEKDAY")), _str(a.get("PICKUPWEEK"))
        day_names, week_names = ag.domain(meta, "WEEKDAY"), ag.domain(meta, "PICKUPWEEK")
        if day not in day_names or week not in week_names:
            raise BadResponse("WEEKDAY/PICKUPWEEK value is not in the layer's domain")
        q = f"WEEKDAY: {day}; PICKUPWEEK: {week}; DESCRIPTION: {a.get('DESCRIPTION')}"
        return [ok("us-fl-miamidade.trash.recycling-day", raw, v_weekdays(ag.days_from_domain_name(day_names[day])), q),
                ok("us-fl-miamidade.trash.recycling-week", raw, v_code(week_names[week]), q)]


class CityTrash(_Trash):
    adapter_id = "us-fl-miami.trash-city"
    layer = f"{MIAMI}/SolidWaste/TrashRoutes/MapServer/0"
    out_fields = ("OBJECTID", "TRASHDAY")
    na_reason = NA_CITY_TRASH

    def facts(self, a, raw, meta, ctx):
        code = _str(a.get("TRASHDAY"))
        names = ag.domain(meta, "TRASHDAY")  # SW_Service_Days: never guess what a letter means
        if code not in names:
            raise BadResponse("TRASHDAY value is not in the layer's domain")
        days = ag.days_from_domain_name(names[code])
        return [ok("us-fl-miami.trash.day", raw, v_weekdays(days), f'TRASHDAY: {code} (layer domain: "{names[code]}")')]


class School(PointLayer):
    level = ""
    boundary_table = ""

    @property
    def out_fields(self):  # type: ignore[override]
        s, b = "psde2.MDC.SchoolSite", f"psde2.MDC.{self.boundary_table}"
        return (f"{s}.NAME", f"{s}.ADDRESS", f"{s}.LAT", f"{s}.LON", f"{b}.PHONE", f"{b}.GRADES")

    def facts(self, a, raw, meta, ctx):
        s, b = "psde2.MDC.SchoolSite", f"psde2.MDC.{self.boundary_table}"
        name, lat, lon = _str(a.get(f"{s}.NAME")), a.get(f"{s}.LAT"), a.get(f"{s}.LON")
        if not name or lat is None or lon is None:
            raise BadResponse("school feature without site name/point")
        base = f"us-fl-miamidade.school.{self.level}"
        dist = ag.haversine_m(ctx.pin.lat, ctx.pin.lon, lat, lon)  # straight-line only
        out = [ok(base, raw, v_place(name, lat, lon, _str(a.get(f"{s}.ADDRESS"))),
                  f"{s}.NAME: {name}; ADDRESS: {a.get(f'{s}.ADDRESS')}", distance_m=dist)]
        phone, grades = _str(a.get(f"{b}.PHONE")), _str(a.get(f"{b}.GRADES"))
        out.append(ok(f"{base}.phone", raw, v_phone(digits(phone)), f"PHONE: {phone}") if digits(phone)
                   else na(f"{base}.phone", raw, NA_OUTSIDE_LAYER))
        out.append(ok(f"{base}.grades", raw, v_code(grades), f"GRADES: {grades}") if grades
                   else na(f"{base}.grades", raw, NA_OUTSIDE_LAYER))
        return out


class SchoolElementary(School):
    adapter_id, level, boundary_table = "us-fl-miamidade.school-elementary", "elementary", "ElementaryAttendanceBoundary"
    layer = f"{MD}/CommunityServices/MD_Educational/MapServer/9"


class SchoolMiddle(School):
    adapter_id, level, boundary_table = "us-fl-miamidade.school-middle", "middle", "MiddleAttendanceBoundary"
    layer = f"{MD}/CommunityServices/MD_Educational/MapServer/11"


class SchoolHigh(School):
    adapter_id, level, boundary_table = "us-fl-miamidade.school-high", "high", "HighAttendanceBoundary"
    layer = f"{MD}/CommunityServices/MD_Educational/MapServer/10"


class _Utility(PointLayer):
    out_fields = ("UTILITYNAME",)
    fact = ""

    def facts(self, a, raw, meta, ctx):
        name = _str(a.get("UTILITYNAME"))
        if not name:
            return [na(self.fact, raw, NA_OUTSIDE_LAYER)]
        return [ok(self.fact, raw, v_code(name), f"UTILITYNAME: {name}")]


class Water(_Utility):
    adapter_id, fact = "us-fl-miamidade.water", "us-fl-miamidade.utility.water"
    layer = f"{MD}/CommunityServices/MD_WaterSewer/MapServer/1"


class Sewer(_Utility):
    adapter_id, fact = "us-fl-miamidade.sewer", "us-fl-miamidade.utility.sewer"
    layer = f"{MD}/CommunityServices/MD_WaterSewer/MapServer/0"


class _Rep(PointLayer):
    slug = ""
    member_field = ""

    @property
    def out_fields(self):  # type: ignore[override]
        return ("ID", self.member_field)

    def facts(self, a, raw, meta, ctx):
        district, member = _str(a.get("ID")), _str(a.get(self.member_field))
        base = f"us-fl-miamidade.rep.{self.slug}"
        q = f"ID: {district}; {self.member_field}: {member}"
        return [ok(f"{base}.district", raw, v_code(district), q) if district else na(f"{base}.district", raw, NA_OUTSIDE_LAYER),
                ok(f"{base}.member", raw, v_code(member), q) if member else na(f"{base}.member", raw, NA_OUTSIDE_LAYER)]


def _rep(adapter: str, slug: str, layer_no: int, member_field: str) -> type:
    return type(f"Rep_{slug}", (_Rep,), {"adapter_id": adapter, "slug": slug, "member_field": member_field,
                                        "layer": f"{MD}/MD_KnowWhereToVote/MapServer/{layer_no}"})


RepCommission = _rep("us-fl-miamidade.rep-county-commission", "county-commission", 4, "COMMNAME")
RepCongress = _rep("us-fl-miamidade.rep-congress", "congress", 5, "REPNAME")
RepSenate = _rep("us-fl-miamidade.rep-state-senate", "state-senate", 6, "SENNAME")
RepHouse = _rep("us-fl-miamidade.rep-state-house", "state-house", 7, "REPNAME")
RepSchoolBoard = _rep("us-fl-miamidade.rep-school-board", "school-board", 8, "BRDMBR")


# ---------------------------------------------------------------- parcel (buffer, address match, nearest)

class Parcel(Adapter):
    adapter_id = "us-fl-miamidade.parcel"
    layer = f"{MD}/MD_LandInformation/MapServer/26"
    # Explicit fields only: the layer also has owner names and mailing addresses, which never leave the county.
    out_fields = ("FOLIO", "TRUE_SITE_ADDR", "CONDO_FLAG", "YEAR_BUILT", "DOR_DESC")
    buffer_m = 80

    def plan(self, pin):
        return [Request(ag.point_query_url(self.layer, pin.lat, pin.lon, self.out_fields, buffer_m=self.buffer_m,
                                           return_geometry=True))]

    def choose(self, pin: ResolvedPin, feats: list[dict]) -> tuple[dict, str, float] | None:
        """Site-address match first, else the nearest polygon. Returns (attributes, lookup, distance_m)."""
        ranked = sorted(((ag.polygon_distance_m(pin.lat, pin.lon, f["geometry"]["rings"]), i, f["attributes"])
                         for i, f in enumerate(feats) if (f.get("geometry") or {}).get("rings")),
                        key=lambda t: (t[0], t[1]))
        want = ag.street_key(pin.address)
        if want:
            for d, _, a in ranked:
                if ag.street_key(a.get("TRUE_SITE_ADDR")) == want:
                    return a, "address_match", d
        if ranked:
            d, _, a = ranked[0]
            return a, "nearest_polygon", d
        return None

    def parse(self, pin, raws, ctx):
        raw = raws[0]
        pick = self.choose(pin, ag.features(raw))
        ids = self.decl.fact_ids
        if pick is None:
            return [na(fid, raw, NA_NO_PARCEL, lookup="buffer") for fid in ids]
        a, lookup, d = pick
        folio, site = _str(a.get("FOLIO")), _str(a.get("TRUE_SITE_ADDR"))
        where = f"FOLIO: {folio}; TRUE_SITE_ADDR: {site}"
        out = [ok("us-fl-miamidade.parcel.folio", raw, v_code(folio), where, lookup, d) if folio
               else na("us-fl-miamidade.parcel.folio", raw, NA_NO_PARCEL, lookup=lookup)]
        year = a.get("YEAR_BUILT")
        if isinstance(year, (int, float)) and int(year) > 0:
            out.append(ok("us-fl-miamidade.parcel.year-built", raw, v_quantity(int(year), "year"),
                          f"{where}; YEAR_BUILT: {int(year)}", lookup, d))
        else:  # 0 or null means none recorded: an outcome, never a value
            out.append(na("us-fl-miamidade.parcel.year-built", raw, NA_YEAR_NOT_RECORDED, lookup=lookup))
        condo = _str(a.get("CONDO_FLAG"))
        if condo not in ("Y", "N"):
            out.append(Out("us-fl-miamidade.parcel.condo", raw, error="CONDO_FLAG is neither Y nor N", lookup=lookup))
        else:
            out.append(ok("us-fl-miamidade.parcel.condo", raw, v_flag(condo == "Y"), f"{where}; CONDO_FLAG: {condo}",
                          lookup, d))
        use = _str(a.get("DOR_DESC"))
        out.append(ok("us-fl-miamidade.parcel.use", raw, v_text(use, "en"), f"{where}; DOR_DESC: {use}", lookup, d)
                   if use else na("us-fl-miamidade.parcel.use", raw, NA_OUTSIDE_LAYER, lookup=lookup))
        return out


# ---------------------------------------------------------------- nearest points (buffer, distance sort, top 3)

class Nearest(Adapter):
    layer = ""
    radius_m = 0
    name_field = "NAME"
    base = ""

    @property
    def out_fields(self):
        return (self.name_field, "ADDRESS")

    def plan(self, pin):
        return [Request(ag.point_query_url(self.layer, pin.lat, pin.lon, self.out_fields, buffer_m=self.radius_m,
                                           return_geometry=True))]

    def parse(self, pin, raws, ctx):
        raw = raws[0]
        pts = []
        for f in ag.features(raw):
            g, a = f.get("geometry") or {}, f.get("attributes") or {}
            name = _str(a.get(self.name_field))
            if name and g.get("x") is not None and g.get("y") is not None:
                pts.append((ag.haversine_m(pin.lat, pin.lon, g["y"], g["x"]), name, g, a))
        pts.sort(key=lambda t: (t[0], t[1]))
        out = []
        for n in (1, 2, 3):
            fid = f"{self.base}.{n}"
            if n <= len(pts):
                d, name, g, a = pts[n - 1]
                addr = _str(a.get("ADDRESS"))
                out.append(ok(fid, raw, v_place(name, round(g["y"], 6), round(g["x"], 6), addr),
                              f"{self.name_field}: {name}; ADDRESS: {addr}", "buffer_then_haversine", d))
            else:
                out.append(na(fid, raw, NA_NONE_NEARBY, lookup="buffer_then_haversine"))
        return out


class ParksCounty(Nearest):
    adapter_id, base, radius_m = "us-fl-miamidade.parks-county", "us-fl-miamidade.parks.nearest-county", 3000
    layer = f"{MD}/CommunityServices/MD_RecreationCulture/MapServer/1"


class ParksMunicipal(Nearest):
    adapter_id, base, radius_m = "us-fl-miamidade.parks-municipal", "us-fl-miamidade.parks.nearest-municipal", 3000
    layer = f"{MD}/CommunityServices/MD_RecreationCulture/MapServer/0"


class Libraries(Nearest):
    adapter_id, base, radius_m = "us-fl-miamidade.libraries", "us-fl-miamidade.library.nearest", 5000
    layer = f"{MD}/MD_Libraries/MapServer/1"
    name_field = "BRANCH"


# ---------------------------------------------------------------- vote: precinct point query, then polling place

class Vote(Adapter):
    adapter_id = "us-fl-miamidade.vote"
    precinct_layer = f"{MD}/MD_KnowWhereToVote/MapServer/3"
    polling_layer = f"{MD}/MD_KnowWhereToVote/MapServer/0"
    polling_fields = ("NAME", "ADDRESS", "LAT", "LON", "PRECINCT")

    def plan(self, pin):
        return [Request(ag.point_query_url(self.precinct_layer, pin.lat, pin.lon, ("ID",)))]

    def followup(self, precinct: str) -> Request:
        if not precinct.isdigit():
            raise BadResponse("precinct id is not numeric")
        return Request(ag.where_query_url(self.polling_layer, f"PRECINCT={precinct}", self.polling_fields))

    def fetch_all(self, pin, transport, deadline):
        first = transport.fetch(self.plan(pin)[0], deadline)
        if first.error:
            return [first]
        feats = ag.features(first)
        if not feats:
            return [first]
        return [first, transport.fetch(self.followup(str(feats[0]["attributes"].get("ID"))), deadline)]

    def parse(self, pin, raws, ctx):
        first = raws[0]
        feats = ag.features(first)
        if not feats:
            return [na(fid, first, NA_OUTSIDE_LAYER) for fid in self.decl.fact_ids]
        precinct = str(feats[0]["attributes"]["ID"])
        out = [ok("us-fl-miamidade.vote.precinct", first, v_code(precinct), f"Precinct ID: {precinct}")]
        polls = ag.features(raws[1])
        if not polls:
            out.append(na("us-fl-miamidade.vote.polling-place", raws[1], NA_OUTSIDE_LAYER, lookup="attribute_query"))
        else:
            a = polls[0]["attributes"]
            name, lat, lon = _str(a.get("NAME")), a.get("LAT"), a.get("LON")
            if not name or lat is None or lon is None:
                raise BadResponse("polling place without name/point")
            out.append(ok("us-fl-miamidade.vote.polling-place", raws[1],
                          v_place(name, lat, lon, _str(a.get("ADDRESS"))),
                          f"PRECINCT: {a.get('PRECINCT')}; NAME: {name}; ADDRESS: {a.get('ADDRESS')}",
                          "attribute_query", ag.haversine_m(pin.lat, pin.lon, lat, lon)))
        return out


# ---------------------------------------------------------------- transit (county GTFS, derived offline subset)

@lru_cache(maxsize=1)
def gtfs_subset() -> dict:
    return json.loads((DATA / "gtfs_stops_subset.json").read_text(encoding="utf-8"))


class Transit(Adapter):
    adapter_id = "us-fl-miamidade.transit"
    base = "us-fl-miamidade.transit.nearest-stop"

    def plan(self, pin):
        return [Request(gtfs_subset()["source"]["request_url"])]

    def fetch_all(self, pin, transport, deadline):
        s = gtfs_subset()["source"]  # read offline; the zip is never fetched at answer time
        return [Raw(Request(s["request_url"]), 200, b"", s["retrieved_at"])]

    def parse(self, pin, raws, ctx):
        raw, sub = raws[0], gtfs_subset()
        ranked = sorted(((ag.haversine_m(pin.lat, pin.lon, st["lat"], st["lon"]), st["stop_id"], st)
                         for st in sub["stops"]), key=lambda t: (t[0], t[1]))[:3]
        # The subset holds every stop within radius_m of each covered centre. Top 3 are exact only if the third
        # stop plus the pin's offset from a centre stays inside that radius; otherwise say so, never guess.
        covered = any(ag.haversine_m(pin.lat, pin.lon, c["lat"], c["lon"]) + (ranked[-1][0] if ranked else 0)
                      <= c["radius_m"] for c in sub["coverage"])
        if len(ranked) < 3 or not covered:
            return [Out(fid, raw, error="pin is outside the derived GTFS stop subset", lookup="gtfs_haversine")
                    for fid in self.decl.fact_ids]
        out = []
        for n, (d, _, st) in enumerate(ranked, start=1):
            q = f"stops.txt stop_id {st['stop_id']}: {st['stop_name']}; routes.txt route_short_name: {', '.join(st['routes'])}"
            out.append(ok(f"{self.base}.{n}", raw, v_place(st["stop_name"], st["lat"], st["lon"], None), q,
                          "gtfs_haversine", d))
            out.append(ok(f"{self.base}.{n}.routes", raw, v_codes(sorted(st["routes"])), q, "gtfs_haversine", d)
                       if st["routes"] else na(f"{self.base}.{n}.routes", raw, NA_OUTSIDE_LAYER, lookup="gtfs_haversine"))
        return out


# ---------------------------------------------------------------- hazards: flood zone (federal) and evacuation zone (county)

FEMA_NFHL = "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer"


class FloodZone(PointLayer):
    """FEMA National Flood Hazard Layer, flood hazard zones (layer 28). Federal data, so it lives in the `us` pack.
    No feature at the pin means the area is not mapped in the NFHL, which is not the same as "zone X"."""
    adapter_id = "us.flood-zone"
    layer = f"{FEMA_NFHL}/28"
    out_fields = ("FLD_ZONE", "ZONE_SUBTY", "SFHA_TF")

    def facts(self, a, raw, meta, ctx):
        zone = _str(a.get("FLD_ZONE"))
        if not zone:
            raise BadResponse("flood hazard feature without FLD_ZONE")
        q = f"FLD_ZONE: {zone}; ZONE_SUBTY: {a.get('ZONE_SUBTY')}; SFHA_TF: {a.get('SFHA_TF')}"
        return [ok("us.fema.flood-zone", raw, v_code(zone), q)]


class EvacuationZone(PointLayer):
    """Miami-Dade storm surge planning (hurricane evacuation) zones A-E. No feature means the pin is in no zone."""
    adapter_id = "us-fl-miamidade.evacuation-zone"
    layer = f"{MD}/CommunityServices/MD_CommunityServices/MapServer/7"
    out_fields = ("ZONEID", "CATEGORY")

    def facts(self, a, raw, meta, ctx):
        zone = _str(a.get("ZONEID"))
        if not zone:
            raise BadResponse("evacuation zone feature without ZONEID")
        return [ok("us-fl-miamidade.storm.evacuation-zone", raw, v_code(zone),
                   f"ZONEID: {zone}; CATEGORY: {a.get('CATEGORY')}")]


# ---------------------------------------------------------------- rent line: no county source yet

class RentLine(Adapter):
    """The county's own rent table is being sourced by myAD Research. Until it lands the answer is unsourced
    with the county housing desk. A City of Miami table never answers for a pin outside the city."""
    adapter_id = "us-fl-miamidade.rent-line"

    def plan(self, pin):
        return []

    def run(self, ctx, transport, deadline):
        r = self._base(ctx, "us-fl-miamidade.rent.line", None)
        r.status, r.retrieved_at, r.basis = "unsourced", None, {"method": ctx.pin.method}
        return [r]


# ---------------------------------------------------------------- Fee Check: static facts from Research's ledger

class LedgerFacts(Adapter):
    """Official fees and payment rules (Fee Check). No request, no fixture, no value in code: each declared fact
    is answered from myAD Research's verified ledger row, else it is unsourced with this adapter's desk. The
    pack that declares the adapter owns the question (a state fee lives in us-fl, a federal rule in us)."""

    def plan(self, pin):
        return []

    def run(self, ctx, transport, deadline):
        out = []
        for fid in self.decl.fact_ids:
            r = self._base(ctx, fid, None)
            r.basis = {"method": ctx.pin.method, "lookup": "ledger"}
            hit = L.verified(fid)
            if hit is None:
                r.status, r.retrieved_at = "unsourced", None
            else:
                row, value = hit
                src = sources().get(row["source_id"])
                r.status, r.value, r.quote = "ok", value, row.get("quote")
                r.source_id, r.url, r.retrieved_at = row["source_id"], row["url"], row["retrieved_at"]
                rsrc = L.ledger_sources().get(row["source_id"]) or {}
                r.publisher = (src.publisher if src else None) or rsrc.get("publisher") or row.get("publisher")
                r.check_every = row.get("check_every") or (src.check_every if src else rsrc.get("check_every"))
                if not r.publisher:  # every sourced answer names who published it
                    r.status, r.value, r.quote, r.error = "error", None, None, "ledger source has no publisher"
            out.append(r)
        return out


class FeeUscis(LedgerFacts):
    adapter_id = "us.fee-check-uscis"


class FeeFtcGiftCard(LedgerFacts):
    adapter_id = "us.fee-check-ftc"


class FeeFlhsmv(LedgerFacts):
    adapter_id = "us-fl.fee-check-flhsmv"


class FeeDeposit(LedgerFacts):
    adapter_id = "us-fl.fee-check-deposit"


class FeeMiaTaxi(LedgerFacts):
    adapter_id = "us-fl-miamidade.fee-check-mia-taxi"


ADAPTER_CLASSES: tuple[type[Adapter], ...] = (
    Municipality, CountyGarbage, CountyRecycling, CityTrash, SchoolElementary, SchoolMiddle, SchoolHigh, Parcel,
    Water, Sewer, ParksCounty, ParksMunicipal, Libraries, Vote, RepCommission, RepCongress, RepSenate, RepHouse,
    RepSchoolBoard, Transit, RentLine, FloodZone, EvacuationZone,
    FeeUscis, FeeFtcGiftCard, FeeFlhsmv, FeeDeposit, FeeMiaTaxi)


@lru_cache(maxsize=1)
def registry() -> Mapping[str, Adapter]:
    return MappingProxyType({cls.adapter_id: cls() for cls in ADAPTER_CLASSES})


def adapter(adapter_id: str) -> Adapter:
    return registry()[adapter_id]
