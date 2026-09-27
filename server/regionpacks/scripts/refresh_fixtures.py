#!/usr/bin/env python3
"""Re-capture the ArcGIS fixtures for both demo pins from the live county services (MYAD_LIVE=1 only).

Writes fixtures/<pin>/<adapter>[.<n>].json + .meta.json (exact request_url, retrieved_at, sha256) using
each adapter's own plan(), so fixture URLs are exactly what the adapters request (explicit outFields).
Layer metadata (`?f=json`) is minimized to the coded-value fields the adapters decode.
Not captured here, saved by hand with their meta: the City of Miami trash layer (gis.miami.gov; this box cannot
complete TLS to it), the Census geocoder (rejects this box), and the county address locator
(fixtures/<pin>/county-locator.json, minimized). GTFS: see derive_gtfs_subset.py.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from myad_regions import adapters as A  # noqa: E402
from myad_regions.adapters import Ctx  # noqa: E402
from myad_regions.pins import DEMO_PINS  # noqa: E402
from myad_regions.transport import Deadline, LiveTransport  # noqa: E402
from myad_regions.types import Raw, ResolvedPin  # noqa: E402

FIX = HERE / "fixtures"
SKIP = {"us-fl-miami.trash-city", "us-fl-miamidade.transit", "us-fl-miamidade.rent-line"}
DOMAIN_FIELDS = {"us-fl-miamidade.trash-county-garbage": ("WEEKDAYS",),
                 "us-fl-miamidade.trash-county-recycling": ("WEEKDAY", "PICKUPWEEK")}


def short(adapter_id: str) -> str:
    return adapter_id.split(".", 1)[1]


def write(dirname: str, name: str, raw: Raw, body: bytes, note: str | None = None) -> None:
    d = FIX / dirname
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{name}.json").write_bytes(body)
    meta = {"request_url": raw.request.url, "method": "GET", "retrieved_at": raw.retrieved_at,
            "http_status": raw.status, "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest(),
            "capture_path": "scripts/refresh_fixtures.py (LiveTransport, box egress)"}
    if note:
        meta["minimized"] = note
    (d / f"{name}.meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")


class Recorder:
    live = True

    def __init__(self):
        self.inner, self.seen = LiveTransport(), []

    def fetch(self, req, deadline):
        raw = self.inner.fetch(req, deadline)
        if raw.error:
            raise SystemExit(f"live fetch failed: {raw.error}")
        self.seen.append(raw)
        return raw


def main() -> int:
    if os.environ.get("MYAD_LIVE") != "1":
        print("refusing: set MYAD_LIVE=1 to re-capture live fixtures", file=sys.stderr)
        return 2
    layers_done = set()
    for pin_id, p in DEMO_PINS.items():
        rp = ResolvedPin(p.lat, p.lon, p.address, "device_coords")
        for cls in A.ADAPTER_CLASSES:
            a = A.adapter(cls.adapter_id)
            if a.decl.id in SKIP:
                continue
            rec = Recorder()
            a.fetch_all(rp, rec, Deadline(20))
            queries = [r for r in rec.seen if "/query?" in r.request.url]
            for i, raw in enumerate(queries):
                write(pin_id, short(a.decl.id) + (f".{i + 1}" if len(queries) > 1 else ""), raw, raw.body)
            for raw in rec.seen:
                if raw.request.url.endswith("?f=json") and a.decl.id not in layers_done:
                    meta = json.loads(raw.body)
                    keep = DOMAIN_FIELDS[a.decl.id]
                    body = json.dumps({"name": meta.get("name"),
                                       "fields": [f for f in meta.get("fields", []) if f.get("name") in keep]},
                                      indent=1).encode() + b"\n"
                    write("_layers", short(a.decl.id), raw, body,
                          f"fields[] reduced to the coded-value fields decoded: {', '.join(keep)}")
                    layers_done.add(a.decl.id)
            print(pin_id, a.decl.id, len(rec.seen), "request(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
