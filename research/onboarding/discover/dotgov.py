"""CISA .gov registry: official domains per jurisdiction, and desk candidates by keyword."""
from __future__ import annotations

import csv
import io

from ..model import Finding, norm_words
from .base import Context

REGISTRY_URL = "https://raw.githubusercontent.com/cisagov/dotgov-data/main/current-full.csv"

# Generic desk keywords (organization-name based). Topic -> words that must appear.
DESK_KEYWORDS = {
    "dmv": ["motor vehicle", "highway safety", "dmv", "driver"],
    "license-and-tag-agent": ["tax collector"],
    "housing-authority": ["housing authority", "housing agency", "public housing"],
    "school-district": ["school district", "public schools", "school board"],
    "clerk-of-court": ["clerk of court", "clerk of the court"],
    "sheriff": ["sheriff"],
    "elections": ["elections", "supervisor of elections", "board of elections"],
    "property-appraiser": ["property appraiser", "assessor"],
    "transit": ["transit", "transportation authority"],
    "water-utility": ["water and sewer", "water & sewer", "water authority", "utilities"],
    "legal-aid": ["legal aid", "legal services", "public defender"],
}
CITY_PREFIXES = ("city of ", "town of ", "village of ", "borough of ", "township of ", "municipality of ")


class DotGovDiscoverer:
    name = "dotgov-registry"

    def run(self, ctx: Context) -> None:
        r = ctx.fetcher.get(REGISTRY_URL)
        if not r.ok:
            ctx.gap("official-domains", ctx.chain.region_id, f"CISA .gov registry unreachable: {r.error}", [REGISTRY_URL])
            return
        rows = list(csv.DictReader(io.StringIO(r.content.decode("utf-8-sig", errors="replace"))))
        state = ctx.chain.by_level("state")
        county = ctx.chain.by_level("county")
        city = ctx.chain.by_level("city")
        st = state.state_abbr if state else None
        state_name = norm_words(state.name) if state else ""
        cbase = norm_words(county.base) if county else None
        tbase = norm_words(city.base) if city else None

        def emit(row: dict, jur: str, via: str, desk: str | None = None) -> None:
            dom = row["Domain name"].lower()
            ev = ctx.evidence(r, self.name, quote=",".join(row.get(k, "") for k in ("Domain name", "Domain type", "Organization name", "City", "State")), official=True)
            ctx.official_domains.setdefault(dom, jur)
            ctx.add(Finding("domain", jur, row["Organization name"], f"https://{dom}/", True, self.name, ev,
                            {"domain": dom, "domain_type": row["Domain type"], "organization": row["Organization name"],
                             "via": via, "desk_topic": desk}))
            email = (row.get("Security contact email") or "").strip()
            if "@" in email and email.lower() != "(blank)":
                edom = email.split("@", 1)[1].lower().strip()
                if edom and edom not in ctx.official_domains and not edom.endswith(("gmail.com", "outlook.com", "yahoo.com")):
                    ctx.official_domains[edom] = jur
                    ctx.add(Finding("domain", jur, f"{row['Organization name']} (security contact domain)", f"https://{edom}/",
                                    True, self.name, ev, {"domain": edom, "via": "registry security-contact email domain",
                                                          "organization": row["Organization name"]}))

        for row in rows:
            if st and row.get("State", "").upper() != st:
                continue
            dtype = row.get("Domain type", "")
            org = norm_words(row.get("Organization name", ""))
            if county and dtype.startswith("County") and cbase and cbase in org:
                emit(row, county.pack_id, "registry: county domain", self._desk(org))
            elif city and dtype.startswith("City") and tbase and any(org == norm_words(p + city.base) for p in CITY_PREFIXES):
                emit(row, city.pack_id, "registry: city domain", self._desk(org))
            elif dtype in ("School district", "Special district") and cbase and cbase in org:
                emit(row, county.pack_id, f"registry: {dtype.lower()}", self._desk(org) or ("school-district" if dtype == "School district" else None))
            elif state and dtype.startswith("State") and self._desk(org) in ("dmv", "elections", "legal-aid", "housing-authority"):
                emit(row, state.pack_id, "registry: state agency", self._desk(org))
            elif state and dtype.startswith("State") and org in (f"state of {state_name}", state_name):
                emit(row, state.pack_id, "registry: state government", None)
        if county and not ctx.of("domain", county.pack_id):
            ctx.gap("official-domains", county.pack_id, "no county .gov domain in the CISA registry", [REGISTRY_URL])
        if city and not ctx.of("domain", city.pack_id):
            ctx.gap("official-domains", city.pack_id, "no city .gov domain in the CISA registry", [REGISTRY_URL])

    @staticmethod
    def _desk(org: str) -> str | None:
        for topic, words in DESK_KEYWORDS.items():
            if any(w in org for w in words):
                return topic
        return None
