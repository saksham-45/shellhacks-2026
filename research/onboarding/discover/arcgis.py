"""ArcGIS discovery: probe official hosts, search ArcGIS Online orgs, enumerate REST directories."""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from ..model import Finding, host_of
from ..taxonomy import SERVICE_HINT, TOPICS
from .base import Context

PROBE_HOSTS = ("gis", "gisweb", "maps", "gis2", "mapservices")
PROBE_PATHS = ("/arcgis/rest/services", "/server/rest/services", "/gis/rest/services")
AGO_SEARCH = "https://www.arcgis.com/sharing/rest/search"
TOPIC_WORDS = ["311", "garbage", "trash", "recycling", "school", "parcel", "municipal", "park", "library",
               "transit", "water", "zoning", "broadband", "polling", "flood", "boundary"]
MAX_FOLDERS = 40
MAX_LAYER_FETCH_PER_ROOT = 300
MAX_HOSTED_LAYER_FETCH = 40


def _is_directory(data: Any) -> bool:
    return isinstance(data, dict) and ("services" in data or "folders" in data) and "error" not in data


class ArcGISProbeDiscoverer:
    """Try common ArcGIS REST paths on the jurisdiction's own official hosts. Recorded only if it answers."""
    name = "arcgis-probe"

    def run(self, ctx: Context) -> None:
        if ctx.options.get("no_probe"):
            return
        for jur in [j for j in ctx.chain.levels if j.level in ("county", "city")]:
            bases: list[str] = []
            for f in ctx.of("page", jur.pack_id) + ctx.of("domain", jur.pack_id):
                h = host_of(f.url)
                root = ".".join(h.split(".")[-2:])
                if root not in bases and not f.data.get("desk_topic"):
                    bases.append(root)
            for dom in bases[:3]:
                for pre in PROBE_HOSTS:
                    for path in PROBE_PATHS:
                        url = f"https://{pre}.{dom}{path}"
                        if any(x.url.rstrip("/").lower() == url.lower() for x in ctx.of("arcgis_root")):
                            continue
                        r = ctx.fetcher.get(url, {"f": "json"}, retries=1)
                        if not r.ok:
                            continue
                        try:
                            data = r.json()
                        except ValueError:
                            continue
                        if _is_directory(data):
                            ctx.add(Finding("arcgis_root", jur.pack_id, f"ArcGIS REST root on {pre}.{dom}", url,
                                            ctx.is_official_host(host_of(url)), self.name, ctx.evidence(r, self.name),
                                            {"found_by": "probe of a common ArcGIS path on an official domain", "verified": True}))
                            break


class ArcGISOnlineDiscoverer:
    """ArcGIS Online search: hub sites owned by official domains -> org ids -> services per topic."""
    name = "arcgis-online"

    def run(self, ctx: Context) -> None:
        orgs: dict[str, str] = {}
        for jur in [j for j in ctx.chain.levels if j.level in ("county", "city")]:
            q = f'"{jur.base}" (type:"Hub Site Application" OR type:"Site Application")'
            r = ctx.fetcher.get(AGO_SEARCH, {"q": q, "num": "50", "f": "json"})
            if not r.ok:
                ctx.gap("arcgis-online", jur.pack_id, f"ArcGIS Online search failed: {r.error}", [r.url])
                continue
            for item in (r.json().get("results") or []):
                url = item.get("url") or ""
                owner = item.get("owner") or ""
                odom = owner.split("@", 1)[1].split("_")[0].lower() if "@" in owner else ""
                official_by = None
                if url and ctx.owner_of_host(host_of(url)):
                    official_by = f"site host {host_of(url)} is an official domain"
                elif odom and ctx.owner_of_host(odom):
                    official_by = f"owner account is on official domain {odom}"
                if not official_by:
                    continue
                owner_jur = ctx.owner_of_host(host_of(url)) or ctx.owner_of_host(odom) or jur.pack_id
                ctx.add(Finding("portal", owner_jur, item.get("title", ""), url or f"https://www.arcgis.com/home/item.html?id={item['id']}",
                                True, self.name, ctx.evidence(r, self.name, quote=f"{item.get('title')} | owner {owner}", official=True),
                                {"platform": "arcgis-hub", "org_id": item.get("orgId"), "owner": owner, "official_by": official_by, "verified": True}))
                if item.get("orgId"):
                    orgs.setdefault(item["orgId"], owner_jur)
        for org, jur in orgs.items():
            for word in TOPIC_WORDS:
                q = f'orgid:{org} (type:"Feature Service" OR type:"Map Service") {word}'
                r = ctx.fetcher.get(AGO_SEARCH, {"q": q, "num": "25", "f": "json"})
                if not r.ok:
                    continue
                for item in r.json().get("results") or []:
                    if not item.get("url"):
                        continue
                    ctx.add(Finding("arcgis_service", jur, item.get("title", ""), item["url"], True, self.name,
                                    ctx.evidence(r, self.name, quote=f"{item.get('title')} | {item.get('type')} | owner {item.get('owner')}", official=True),
                                    {"org_id": org, "item_id": item.get("id"), "type": item.get("type"), "search_word": word,
                                     "hosted": True, "modified": item.get("modified")}))


class ArcGISRestDiscoverer:
    """Enumerate every verified ArcGIS REST root: folders, services, then layers+fields for topical services."""
    name = "arcgis-rest"

    def run(self, ctx: Context) -> None:
        roots = []
        for f in ctx.of("arcgis_root"):
            u = f.url.rstrip("/")
            if u.lower() not in [x.lower() for x, _ in roots]:
                roots.append((u, f))
        if not roots:
            ctx.gap("gis-rest-directory", ctx.chain.region_id, "no ArcGIS REST directory found on official hosts")
        self._seen_dirs: dict[str, str] = {}
        for root, f in roots:
            self._enumerate(ctx, root, f)
        hosted = [f for f in ctx.of("arcgis_service") if f.data.get("hosted")]
        hosted.sort(key=lambda f: 0 if SERVICE_HINT.search(f.title) else 1)
        for f in hosted[:MAX_HOSTED_LAYER_FETCH]:
            self._layers(ctx, f.url.rstrip("/"), f.jurisdiction, f.official, f.title)

    def _enumerate(self, ctx: Context, root: str, rf: Finding) -> None:
        r = ctx.fetcher.get(root, {"f": "json"})
        try:
            data = r.json() if r.ok else None
        except ValueError:
            data = None
        if not _is_directory(data):
            rf.data["verified"] = False
            ctx.notes.append(f"arcgis root did not answer as a directory: {root} ({r.error})")
            return
        rf.data["verified"] = True
        sig = hashlib.sha256(json.dumps({"f": data.get("folders"), "s": data.get("services")}, sort_keys=True).encode()).hexdigest()
        if sig in self._seen_dirs:
            rf.data["alias_of"] = self._seen_dirs[sig]
            ctx.notes.append(f"{root} serves the same directory as {self._seen_dirs[sig]}; not enumerated twice")
            return
        self._seen_dirs[sig] = root
        services: list[dict[str, str]] = list(data.get("services") or [])
        for folder in (data.get("folders") or [])[:MAX_FOLDERS]:
            fr = ctx.fetcher.get(f"{root}/{folder}", {"f": "json"})
            try:
                fd = fr.json() if fr.ok else {}
            except ValueError:
                fd = {}
            services += fd.get("services") or []
        rf.data["service_count"] = len(services)
        jur = ctx.owner_of_host(host_of(root)) or rf.jurisdiction
        # official if the host is, or if the root was linked from an official page (hosted ArcGIS Online orgs)
        official = ctx.is_official_host(host_of(root)) or bool(rf.evidence.official)
        if official and not ctx.is_official_host(host_of(root)):
            rf.official = True
            rf.data["official_by"] = f"linked from official page {rf.data.get('linked_from')}"
        topical = []
        for s in services:
            if s.get("type") not in ("MapServer", "FeatureServer"):
                continue
            surl = f"{root}/{s['name']}/{s['type']}"
            ctx.add(Finding("arcgis_service", jur, s["name"], surl, official, self.name, ctx.evidence(r, self.name, quote=s["name"]),
                            {"type": s["type"], "root": root}))
            topical.append((s["name"], surl))
        # prefer MapServer over a FeatureServer twin of the same name
        seen, ordered = set(), []
        # every service's layers are read (up to the cap); topical names first so a cap cuts the least likely ones
        for name, surl in sorted(topical, key=lambda t: (not SERVICE_HINT.search(t[0].replace("_", " ")), t[0], "FeatureServer" in t[1])):
            if name in seen:
                continue
            seen.add(name)
            ordered.append((name, surl))
        if len(ordered) > MAX_LAYER_FETCH_PER_ROOT:
            ctx.notes.append(f"{root}: {len(ordered)} services, fetched layers for the first {MAX_LAYER_FETCH_PER_ROOT} (topical names first)")
        for name, surl in ordered[:MAX_LAYER_FETCH_PER_ROOT]:
            self._layers(ctx, surl, jur, official, name)

    def _layers(self, ctx: Context, surl: str, jur: str, official: bool, service_name: str) -> None:
        r = ctx.fetcher.get(f"{surl}/layers", {"f": "json"})
        try:
            data = r.json() if r.ok else None
        except ValueError:
            data = None
        if not isinstance(data, dict) or "error" in data or "layers" not in data:
            ctx.notes.append(f"layers not readable: {surl} ({r.error or (data or {}).get('error')})")
            return
        for lyr in (data.get("layers") or []) + (data.get("tables") or []):
            fields = [{"name": x.get("name"), "type": x.get("type"), "alias": x.get("alias")} for x in (lyr.get("fields") or [])]
            ctx.add(Finding("arcgis_layer", jur, f"{service_name} / {lyr.get('name')}", surl, official, self.name,
                            ctx.evidence(r, self.name, quote=f"layer {lyr.get('id')}: {lyr.get('name')}"),
                            {"layer_id": lyr.get("id"), "layer_name": lyr.get("name"), "service": service_name,
                             "geometry": lyr.get("geometryType"), "fields": fields,
                             "sublayer": bool(lyr.get("subLayers")), "edited": (lyr.get("editingInfo") or {}).get("lastEditDate")}))
