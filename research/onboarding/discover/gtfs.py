"""Transit feeds from the Mobility Database catalog, filtered by state and the county's places."""
from __future__ import annotations

import csv
import io

from ..model import Finding, base_name, host_of, norm_words
from .base import Context

MDB_CSV = "https://files.mobilitydatabase.org/feeds_v2.csv"


class MobilityDatabaseDiscoverer:
    name = "mobility-database"

    def run(self, ctx: Context) -> None:
        state = ctx.chain.by_level("state")
        county = ctx.chain.by_level("county")
        if not state or not county:
            return
        r = ctx.fetcher.get(MDB_CSV)
        if not r.ok:
            ctx.gap("transit-gtfs", county.pack_id, f"Mobility Database catalog unreachable: {r.error}", [MDB_CSV])
            return
        names = {norm_words(county.name), norm_words(county.base)}
        names |= {norm_words(base_name(p["PLACENAME"])) for p in ctx.chain.county_places}
        rows = list(csv.DictReader(io.StringIO(r.content.decode("utf-8-sig", errors="replace"))))
        hits = []
        for row in rows:
            if row.get("location.country_code") != "US" or norm_words(row.get("location.subdivision_name", "")) != norm_words(state.name):
                continue
            muni = norm_words(row.get("location.municipality", ""))
            prov = norm_words(row.get("provider", ""))
            if muni in names or norm_words(county.base) in prov:
                hits.append(row)
        if not hits:
            ctx.gap("transit-gtfs", county.pack_id, "no GTFS feed in the Mobility Database for this county's places", [MDB_CSV])
        for row in hits:
            url = row.get("urls.direct_download") or row.get("urls.latest") or ""
            rt = row.get("data_type") == "gtfs_rt"
            auth = row.get("urls.authentication_type") not in ("", "0", None)
            data = {"mdb_id": row["id"], "data_type": row.get("data_type"), "entity_type": row.get("entity_type"),
                    "provider": row.get("provider"), "status": row.get("status"), "mirror": row.get("urls.latest"),
                    "key_required": auth, "auth_info": row.get("urls.authentication_info"), "municipality": row.get("location.municipality"),
                    "realtime": rt, "catalog_official_flag": row.get("is_official")}
            probe = None
            if url and not auth and row.get("status") != "inactive":
                probe = ctx.fetcher.head(url)
                if not probe.ok:
                    probe = ctx.fetcher.get(url, max_bytes=2048, retries=1)
                data["probe"] = {"status": probe.status, "final_url": probe.final_url, "error": probe.error,
                                 "content_length": probe.headers.get("content-length"), "content_type": probe.content_type}
            ev = ctx.evidence(r, self.name, quote=",".join(row.get(k, "") for k in ("id", "data_type", "provider", "urls.direct_download")), official=False)
            official = bool(url) and ctx.is_official_host(host_of(url))
            ctx.add(Finding("gtfs_feed", county.pack_id, f"{row.get('provider')} ({row.get('data_type')}{'/' + row['entity_type'] if row.get('entity_type') else ''})",
                            url, official, self.name, ev, data))
