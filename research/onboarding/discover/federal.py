"""National spine discoverers: ACS languages, HUD housing authorities, NCES districts, LSC legal aid."""
from __future__ import annotations

import datetime as dt
import os
import re

from research.freshness.text import normalize

from ..model import Finding, base_name, host_of
from .base import Context

AGO_SEARCH = "https://www.arcgis.com/sharing/rest/search"
ACS_GROUPS = "https://api.census.gov/data/{year}/acs/acs1/groups/B16001.json"
ACS_SF = "https://www2.census.gov/programs-surveys/acs/summary_file/{year}/table-based-SF/data/1YRData/acsdt1y{year}-b16001.dat"
ACS_API = "https://api.census.gov/data/{year}/acs/acs5"
NCES_DIR = "https://nces.ed.gov/opengis/rest/services/K12_School_Locations"
NCES_DETAIL = "https://nces.ed.gov/ccd/districtsearch/district_detail.asp"
HUD_API_DOC = "https://www.huduser.gov/portal/dataset/fmr-api.html"


def _fmt_phone(raw: str | None) -> str | None:
    d = re.sub(r"\D", "", raw or "")
    if len(d) == 11 and d.startswith("1"):
        d = d[1:]
    return f"{d[:3]}-{d[3:6]}-{d[6:]}" if len(d) == 10 else None


def _sql(s: str) -> str:
    return s.replace("'", "''")


class AcsLanguageDiscoverer:
    """Language spoken at home (ACS B16001). Summary file on www2 (no key) for the county; the API (needs
    CENSUS_API_KEY from the environment) for the city if a key is set."""
    name = "acs-language"

    def run(self, ctx: Context) -> None:
        county = ctx.chain.by_level("county")
        if not county:
            return
        this_year = dt.date.today().year
        for year in (this_year - 1, this_year - 2, this_year - 3):
            lab = ctx.fetcher.get(ACS_GROUPS.format(year=year), retries=1)
            if not lab.ok:
                continue
            data = ctx.fetcher.get(ACS_SF.format(year=year), retries=1)
            if not data.ok:
                continue
            labels = {k: v["label"] for k, v in (lab.json().get("variables") or {}).items()}
            geo = f"0500000US{county.fips}"
            lines = data.content.decode("utf-8", errors="replace").splitlines()
            head = lines[0].split("|")
            row = next((ln.split("|") for ln in lines[1:] if ln.startswith(geo + "|")), None)
            if row is None:
                ctx.gap("languages", county.pack_id, f"county not in ACS {year} 1-year B16001 (population under 65,000?)", [data.url])
                return
            vals = dict(zip(head, row))
            self._emit(ctx, county.pack_id, year, "acs1", labels, vals, lambda v: v.replace("B16001_E", "B16001_") + "E" if "_E" in v else None,
                       data, lab)
            break
        else:
            ctx.gap("languages", county.pack_id, "ACS B16001 summary file / labels not reachable", [ACS_SF.format(year=this_year - 1)])
        city = ctx.chain.by_level("city")
        if city:
            key = os.environ.get("CENSUS_API_KEY")
            if not key:
                ctx.gap("languages", city.pack_id, "city-level ACS languages need the Census API, which now requires a key "
                        "(set CENSUS_API_KEY in the environment); county figures used instead", [ACS_API.format(year=this_year - 2)])
                return
            for year in (this_year - 2, this_year - 3):
                st, pl = city.fips[:2], city.fips[2:]
                r = ctx.fetcher.get(ACS_API.format(year=year), {"get": "group(C16001)", "for": f"place:{pl}", "in": f"state:{st}", "key": key}, retries=1)
                lab = ctx.fetcher.get(f"https://api.census.gov/data/{year}/acs/acs5/groups/C16001.json", retries=1)
                if r.ok and lab.ok:
                    try:
                        arr = r.json()
                    except ValueError:
                        continue
                    labels = {k: v["label"] for k, v in (lab.json().get("variables") or {}).items()}
                    self._emit(ctx, city.pack_id, year, "acs5", labels, dict(zip(arr[0], arr[1])), lambda v: v if v.endswith("E") else None, r, lab)
                    break

    def _emit(self, ctx, jur, year, product, labels, vals, to_var, data, lab) -> None:
        total = None
        langs = []
        for col, v in vals.items():
            var = to_var(col)
            if not var or var not in labels:
                continue
            parts = labels[var].split("!!")
            try:
                n = int(float(v))
            except (TypeError, ValueError):
                continue
            if parts[-1].rstrip(":") == "Total":
                total = n
            elif len(parts) == 3:
                limited = next((int(float(vals[c])) for c in vals if to_var(c) and labels.get(to_var(c), "").startswith(labels[var] + "!!Speak English less")), None)
                langs.append((parts[2].rstrip(":"), n, limited, var))
        if not total:
            return
        for name, n, limited, var in sorted(langs, key=lambda t: -t[1])[:8]:
            quote = f"{labels[var]} = {n} of {total} (population 5 years and over), ACS {year} {product}"
            name = "English only" if name.lower() == "speak only english" else name
            ctx.add(Finding("language", jur, name, data.url, True, self.name, ctx.evidence(data, self.name, quote=quote, official=True),
                            {"speakers": n, "share": round(n / total, 4), "limited_english": limited, "variable": var,
                             "year": year, "product": product, "labels_url": lab.url, "layer_id": f"{year}:{var}"}))


class HudDiscoverer:
    name = "hud"

    def run(self, ctx: Context) -> None:
        county, state = ctx.chain.by_level("county"), ctx.chain.by_level("state")
        if not county:
            return
        r = ctx.fetcher.get(AGO_SEARCH, {"q": '"Public Housing Authorities" type:"Feature Service" owner:HUD*', "num": "20", "f": "json"})
        svc = None
        if r.ok:
            for it in r.json().get("results") or []:
                if it.get("owner", "").startswith("HUD.") and it.get("title", "").strip().lower() == "public housing authorities" and it.get("url"):
                    svc = it
                    break
        if svc is None:
            ctx.gap("housing-authority", county.pack_id, "HUD Public Housing Authorities layer not found via ArcGIS Online search", [r.url])
        else:
            layer = svc["url"].rstrip("/") + "/0"
            q = ctx.fetcher.get(layer + "/query", {
                "where": f"STD_ST='{state.state_abbr}' AND CURCNTY_NM LIKE '{_sql(county.base)}%'",
                "outFields": "FORMAL_PARTICIPANT_NAME,HA_PHN_NUM,HA_EMAIL_ADDR_TEXT,STD_ADDR,STD_CITY,STD_ZIP5,PARTICIPANT_CODE,HA_PROGRAM_TYPE,TOTAL_UNITS",
                "returnGeometry": "false", "f": "json"})
            feats = (q.json().get("features") or []) if q.ok else []
            for ft in feats:
                a = {k: (v.strip() if isinstance(v, str) else v) for k, v in ft.get("attributes", {}).items()}
                phone = _fmt_phone(a.get("HA_PHN_NUM"))
                ctx.add(Finding("desk", county.pack_id, a.get("FORMAL_PARTICIPANT_NAME") or "housing authority", layer, True, self.name,
                                ctx.evidence(q, self.name, quote=str(a), official=True),
                                {"topic": "housing-authority", "phone": phone, "raw_phone": a.get("HA_PHN_NUM"),
                                 "address": f"{a.get('STD_ADDR')}, {a.get('STD_CITY')} {a.get('STD_ZIP5')}", "code": a.get("PARTICIPANT_CODE"),
                                 "program": a.get("HA_PROGRAM_TYPE"), "official_by": f"ArcGIS owner {svc.get('owner')}",
                                 "layer_id": a.get("PARTICIPANT_CODE")}))
            if not feats:
                ctx.gap("housing-authority", county.pack_id, "HUD layer answered with no authority for this county", [q.url])
        doc = ctx.fetcher.get(HUD_API_DOC, retries=1)
        if doc.ok:
            ctx.add(Finding("page", "us", "HUD User Fair Market Rent / Income Limits API documentation", doc.final_url, True, self.name,
                            ctx.evidence(doc, self.name, official=True), {"key_required": True, "key_env": "HUD_API_TOKEN"}))
        ctx.gap("income-limits", county.pack_id, "HUD income limits / FMR API needs a free token (HUD_API_TOKEN); not called by onboarding. "
                "Local program tables (city/state housing pages) must be read by a human or html-quote.", [HUD_API_DOC])


class NcesDistrictDiscoverer:
    name = "nces-district"

    def run(self, ctx: Context) -> None:
        county = ctx.chain.by_level("county")
        if not county:
            return
        d = ctx.fetcher.get(NCES_DIR, {"f": "json"})
        svcs = sorted(s["name"] for s in (d.json().get("services") or []) if "PUBLICLEA" in s["name"]) if d.ok else []
        if not svcs:
            ctx.gap("school-district", county.pack_id, "NCES EDGE district layer directory unreachable", [NCES_DIR])
            return
        layer = f"https://nces.ed.gov/opengis/rest/services/{svcs[-1]}/MapServer/0"
        q = ctx.fetcher.get(layer + "/query", {"where": f"STFIP='{county.fips[:2]}' AND NMCNTY='{_sql(county.name)}'",
                                               "outFields": "LEAID,NAME,STREET,CITY,STATE,ZIP,SCHOOLYEAR", "returnGeometry": "false", "f": "json"})
        feats = (q.json().get("features") or []) if q.ok else []
        if not feats:
            ctx.gap("school-district", county.pack_id, "no NCES district office in this county", [q.url])
        found = []
        for ft in feats[:6]:
            a = ft.get("attributes", {})
            data = {"topic": "school-district", "leaid": a.get("LEAID"), "address": f"{a.get('STREET')}, {a.get('CITY')} {a.get('ZIP')}",
                    "school_year": a.get("SCHOOLYEAR"), "phone": None, "website": None, "layer_id": a.get("LEAID")}
            quote = str(a)
            det = ctx.fetcher.get(NCES_DETAIL, {"ID2": a.get("LEAID")}, retries=1)
            if det.ok:
                from bs4 import BeautifulSoup
                txt = normalize(BeautifulSoup(det.content, "html.parser").get_text(" "))
                pm = re.search(r"Phone:\s*(\(?\d{3}\)?\s*\d{3}-\d{4})", txt)
                wm = re.search(r"Website:\s*(https?://\S+)", txt)
                tm = re.search(r"Type:\s*(.+?)\s+Status:", txt)
                data["district_type"] = tm.group(1) if tm else None
                if pm:
                    data["phone"] = _fmt_phone(pm.group(1))
                    i = pm.start()
                    quote = txt[max(0, i - 200): pm.end() + 20]
                if wm:
                    data["website"] = wm.group(1)
                data["detail_url"] = det.url
            ev = ctx.evidence(det if det.ok else q, self.name, quote=quote, official=True)
            found.append(Finding("desk", county.pack_id, a.get("NAME") or "school district", det.url if det.ok else layer, True, self.name, ev, data))
        # the regular local district is the desk; charter/virtual LEAs follow
        found.sort(key=lambda f: 0 if "regular" in (f.data.get("district_type") or "").lower() else 1)
        for f in found:
            ctx.add(f)


class LegalAidDiscoverer:
    name = "lsc-legal-aid"

    def run(self, ctx: Context) -> None:
        county, state = ctx.chain.by_level("county"), ctx.chain.by_level("state")
        if not county:
            return
        r = ctx.fetcher.get(AGO_SEARCH, {"q": 'LSC offices grantees type:"Feature Service"', "num": "20", "f": "json"})
        svc = None
        if r.ok:
            for it in r.json().get("results") or []:
                if it.get("owner", "").upper().endswith("_LSCGOV") and "offices" in it.get("title", "").lower() and it.get("url"):
                    svc = it
                    break
        if not svc:
            ctx.gap("legal-aid", county.pack_id, "Legal Services Corporation office layer not found", [r.url])
            return
        towns = sorted({base_name(p["PLACENAME"]) for p in ctx.chain.county_places})[:150]
        where = f"State='{state.state_abbr}' AND City IN ({','.join("'" + _sql(t) + "'" for t in towns)})"
        layer = svc["url"].rstrip("/") + "/0"
        q = ctx.fetcher.get(layer + "/query", {"where": where, "outFields": "orgName,officenam,officetype,address,bldgSuite,City,State,ZIP",
                                               "returnGeometry": "false", "f": "json"})
        feats = (q.json().get("features") or []) if q.ok else []
        if not feats:
            ctx.gap("legal-aid", county.pack_id, "no LSC-funded office listed in this county's places", [q.url])
        for ft in feats[:6]:
            a = ft.get("attributes", {})
            ctx.add(Finding("desk", county.pack_id, f"{a.get('orgName')} — {a.get('officenam')}", layer, True, self.name,
                            ctx.evidence(q, self.name, quote=str(a), official=True),
                            {"topic": "legal-aid", "phone": None, "address": f"{a.get('address')} {a.get('bldgSuite') or ''}, {a.get('City')} {a.get('ZIP')}".replace("  ", " "),
                             "official_by": f"ArcGIS owner {svc.get('owner')} (Legal Services Corporation)", "layer_id": f"{a.get('orgName')}|{a.get('officenam')}"}))
