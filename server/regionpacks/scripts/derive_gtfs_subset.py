#!/usr/bin/env python3
"""Derive the small GTFS stop subset the transit adapter reads offline.

Usage: derive_gtfs_subset.py <google_transit.zip> <meta.json> [radius_m]
  zip:  the county feed, http://www.miamidade.gov/transit/googletransit/current/google_transit.zip (~8.4 MB;
        not kept in the tree). meta.json: {request_url, retrieved_at, sha256} saved when it was downloaded.
Keeps every stop within radius_m (default 600) of each demo pin, with the route_short_names serving it
(stop_times -> trips -> routes). Writes data/gtfs_stops_subset.json.
"""
from __future__ import annotations

import collections
import csv
import hashlib
import io
import json
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from myad_regions.arcgis import haversine_m  # noqa: E402
from myad_regions.pins import DEMO_PINS  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    zpath, meta = Path(argv[1]), json.loads(Path(argv[2]).read_text())
    radius = int(argv[3]) if len(argv) > 3 else 600
    sha = hashlib.sha256(zpath.read_bytes()).hexdigest()
    if sha != meta["sha256"]:
        print("zip sha256 does not match its meta", file=sys.stderr)
        return 1
    z = zipfile.ZipFile(zpath)

    def rows(name):
        return csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig"))

    stops = [s for s in rows("stops.txt") if s.get("stop_lat")]
    keep = {}
    for p in DEMO_PINS.values():
        for s in stops:
            if haversine_m(p.lat, p.lon, float(s["stop_lat"]), float(s["stop_lon"])) <= radius:
                keep[s["stop_id"]] = s
    routes = {r["route_id"]: r.get("route_short_name") or r["route_id"] for r in rows("routes.txt")}
    trips = {t["trip_id"]: t["route_id"] for t in rows("trips.txt")}
    served = collections.defaultdict(set)
    for st in rows("stop_times.txt"):
        if st["stop_id"] in keep:
            rid = trips.get(st["trip_id"])
            if rid in routes:
                served[st["stop_id"]].add(routes[rid])
    info = {i.filename: i.date_time for i in z.infolist()}
    out = {
        "source": {"request_url": meta["request_url"], "retrieved_at": meta["retrieved_at"], "sha256": sha,
                   "bytes": zpath.stat().st_size, "last_modified": meta.get("last_modified"),
                   "stops_txt_zip_time": "%04d-%02d-%02dT%02d:%02d:%02d" % info["stops.txt"],
                   "derived_by": "scripts/derive_gtfs_subset.py"},
        "coverage": [{"pin": pid, "lat": p.lat, "lon": p.lon, "radius_m": radius} for pid, p in DEMO_PINS.items()],
        "stops": [{"stop_id": s["stop_id"], "stop_name": s["stop_name"], "lat": float(s["stop_lat"]),
                   "lon": float(s["stop_lon"]), "routes": sorted(served[s["stop_id"]])}
                  for s in sorted(keep.values(), key=lambda s: s["stop_id"])],
    }
    (HERE / "data" / "gtfs_stops_subset.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(out['stops'])} stops kept")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
