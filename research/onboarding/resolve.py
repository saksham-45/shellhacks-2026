"""Place string -> JurisdictionChain from official Census reference files (www2.census.gov).

The Census geocoder / TIGERweb / data API are the first choice for points and polygons, but a
place name only needs the code lists: state.txt, the state's county list, and the state's place
list (which names the counties each place lies in).
"""
from __future__ import annotations

import re

from research.freshness.net import Fetcher

from .model import Evidence, Jurisdiction, JurisdictionChain, base_name, norm_words, slug

STATE_URL = "https://www2.census.gov/geo/docs/reference/state.txt"
COUNTY_URL = "https://www2.census.gov/geo/docs/reference/codes2020/cou/st{fips}_{abbr}_cou2020.txt"
PLACE_URL = "https://www2.census.gov/geo/docs/reference/codes2020/place/st{fips}_{abbr}_place2020.txt"


class ResolveError(RuntimeError):
    pass


def _table(f: Fetcher, url: str) -> tuple[list[dict[str, str]], Evidence]:
    r = f.get(url)
    if not r.ok:
        raise ResolveError(f"could not fetch {url}: {r.error}")
    lines = [ln for ln in r.content.decode("utf-8-sig", errors="replace").splitlines() if ln.strip()]
    head = lines[0].split("|")
    rows = [dict(zip(head, ln.split("|"))) for ln in lines[1:]]
    return rows, Evidence(r.url, r.status, r.retrieved_at, "census-reference-files", True)


def _match(name: str, candidates: list[str]) -> list[int]:
    n = norm_words(name)
    exact = [i for i, c in enumerate(candidates) if norm_words(c) == n]
    if exact:
        return exact
    b = norm_words(base_name(name))
    return [i for i, c in enumerate(candidates) if norm_words(base_name(c)) == b]


def resolve(place: str, fetcher: Fetcher, city: str | None = None) -> JurisdictionChain:
    m = re.match(r"^\s*(.+?)\s*,\s*([A-Za-z]{2}|[A-Za-z .]+)\s*$", place)
    if not m:
        raise ResolveError(f"place must look like 'Name, ST' (got {place!r})")
    name, st = m.group(1), m.group(2).strip()
    states, sev = _table(fetcher, STATE_URL)
    srow = next((s for s in states if s["STUSAB"].upper() == st.upper() or s["STATE_NAME"].lower() == st.lower()), None)
    if not srow:
        raise ResolveError(f"unknown state {st!r}")
    abbr, sfips = srow["STUSAB"], srow["STATE"]
    us = Jurisdiction("country", "United States", "us", None, "US", evidence=[sev])
    state = Jurisdiction("state", srow["STATE_NAME"], f"us-{abbr.lower()}", "us", sfips, abbr, [sev])
    counties, cev = _table(fetcher, COUNTY_URL.format(fips=sfips, abbr=abbr.lower()))
    places, pev = _table(fetcher, PLACE_URL.format(fips=sfips, abbr=abbr.lower()))
    cnames = [c["COUNTYNAME"] for c in counties]

    county_row = None
    city_row = None
    is_county_query = re.search(r"\b(county|parish|borough)\b", name, re.I)
    idx = _match(name, cnames) if is_county_query else []
    if idx:
        county_row = counties[idx[0]]
    else:
        inc = [p for p in places if p.get("TYPE", "").upper().startswith("INCORPORATED")]
        pidx = _match(name, [p["PLACENAME"] for p in inc])
        if not pidx:
            idx = _match(name, cnames)
            if not idx:
                raise ResolveError(f"{name!r} is neither a county nor an incorporated place in {abbr}")
            county_row = counties[idx[0]]
        else:
            city_row = inc[pidx[0]]
            first_county = city_row.get("COUNTIES", "").split("~")[0].strip()
            ci = _match(first_county, cnames)
            if not ci:
                raise ResolveError(f"place {city_row['PLACENAME']} lists county {first_county!r} not in county file")
            county_row = counties[ci[0]]
    cname = county_row["COUNTYNAME"]
    county = Jurisdiction("county", cname, f"us-{abbr.lower()}-{slug(cname)}", state.pack_id,
                          sfips + county_row["COUNTYFP"], abbr, [cev])
    in_county = [p for p in places if cname in [c.strip() for c in p.get("COUNTIES", "").split("~")]]
    if city and not city_row:
        inc = [p for p in in_county if p.get("TYPE", "").upper().startswith("INCORPORATED")]
        pidx = _match(city, [p["PLACENAME"] for p in inc])
        if not pidx:
            raise ResolveError(f"no incorporated place {city!r} in {cname}")
        city_row = inc[pidx[0]]
    levels = [us, state, county]
    if city_row:
        levels.append(Jurisdiction("city", city_row["PLACENAME"], f"us-{abbr.lower()}-{slug(city_row['PLACENAME'])}",
                                   county.pack_id, sfips + city_row["PLACEFP"], abbr, [pev]))
    for j in levels[2:]:
        if pev not in j.evidence:
            j.evidence.append(pev)
    return JurisdictionChain(levels, in_county)
