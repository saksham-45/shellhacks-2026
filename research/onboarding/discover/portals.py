"""Open-data portal discovery: Socrata catalog search, CKAN check on linked portals."""
from __future__ import annotations

import re
from urllib.parse import urlsplit

from ..model import Finding, host_of
from ..taxonomy import SERVICE_HINT
from .base import Context

SOCRATA = "https://api.us.socrata.com/api/catalog/v1"


class SocrataDiscoverer:
    name = "socrata-catalog"

    def run(self, ctx: Context) -> None:
        for jur in [j for j in ctx.chain.levels if j.level in ("county", "city")]:
            r = ctx.fetcher.get(SOCRATA, {"q": jur.base, "only": "dataset", "limit": "100"})
            if not r.ok:
                ctx.gap("open-data-portal", jur.pack_id, f"Socrata catalog unreachable: {r.error}", [r.url])
                continue
            by_domain: dict[str, list[dict]] = {}
            for res in r.json().get("results") or []:
                by_domain.setdefault(res.get("metadata", {}).get("domain", ""), []).append(res)
            for dom, items in by_domain.items():
                if not dom or not ctx.owner_of_host(dom):
                    if dom:
                        ctx.notes.append(f"socrata domain {dom} matched '{jur.base}' but is not one of this chain's official domains; ignored")
                    continue
                owner = ctx.owner_of_host(dom) or jur.pack_id
                ctx.add(Finding("portal", owner, f"Socrata portal {dom}", f"https://{dom}/", True, self.name,
                                ctx.evidence(r, self.name, quote=f"catalog domain {dom}", official=True),
                                {"platform": "socrata", "verified": True, "matched_datasets": len(items)}))
                for res in items:
                    rs = res.get("resource", {})
                    name = rs.get("name", "")
                    if not SERVICE_HINT.search(name):
                        continue
                    link = res.get("permalink") or res.get("link") or f"https://{dom}/d/{rs.get('id')}"
                    ctx.add(Finding("dataset", owner, name, link, True, self.name,
                                    ctx.evidence(r, self.name, quote=name, official=True),
                                    {"platform": "socrata", "id": rs.get("id"), "api": f"https://{dom}/resource/{rs.get('id')}.json",
                                     "updated_at": rs.get("updatedAt"), "columns": (rs.get("columns_field_name") or [])[:40]}))
        # CKAN: only for portal links found on official pages
        for f in [p for p in ctx.of("portal") if p.data.get("platform") == "unknown"]:
            origin = "{0.scheme}://{0.netloc}".format(urlsplit(f.url))
            rr = ctx.fetcher.get(f"{origin}/api/3/action/status_show", retries=1)
            try:
                ok = rr.ok and rr.json().get("success") is True
            except ValueError:
                ok = False
            if ok:
                f.data["platform"] = "ckan"
                f.data["verified"] = True
                f.data["api"] = f"{origin}/api/3/action/package_search"
