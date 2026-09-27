#!/usr/bin/env python3
"""Record the cached "Who handles my address" answers for both demo pins from the live county 311 layers.

MYAD_LIVE=1 only. Writes fixtures/checks/address-<pin>.json (export_fixtures.py copies it into ADCityPack's
Resources/Checks). Each layer keeps its exact request URL and retrieved_at and only the fields the phone reads.
The county locator is asked with the typed address, and only a PointAddress candidate scoring at least 95 counts.
The City trash code list comes from fixtures/_layers/trash-city.json (this box cannot reach gis.miami.gov).
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from myad_regions import address as AD  # noqa: E402
from myad_regions.geocode import MIN_POINT_ADDRESS_SCORE, county_locator_url  # noqa: E402
from myad_regions.pins import DEMO_PINS  # noqa: E402

OUT = HERE / "fixtures" / "checks"


def now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def get(url: str) -> tuple[dict, str]:
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read()), now()


def locate(address: str) -> dict:
    url = county_locator_url(address)
    body, at = get(url)
    best = max((c for c in body.get("candidates", []) if c["attributes"].get("Addr_type") == "PointAddress"),
               key=lambda c: c["score"], default=None)
    if not best or best["score"] < MIN_POINT_ADDRESS_SCORE:
        raise SystemExit(f"{address}: no PointAddress candidate at score >= {MIN_POINT_ADDRESS_SCORE}")
    return {"url": url, "retrieved_at": at, "matched": best["address"], "addr_type": "PointAddress",
            "score": best["score"], "lat": best["location"]["y"], "lon": best["location"]["x"]}


def record(pin_id: str) -> dict:
    pin = DEMO_PINS[pin_id]
    loc = locate(pin.address)

    def one(layer: AD.Layer):
        url = layer.query_url(loc["lat"], loc["lon"])
        body, at = get(url)
        return layer.key, {"url": url, "retrieved_at": at, "features": AD.minimize_features(layer, body)}

    with ThreadPoolExecutor(6) as pool:
        layers = dict(pool.map(one, AD.LAYERS))
    domains = {}
    for layer in AD.LAYERS:
        if layer.domain_field and layers[layer.key]["features"]:
            meta, at = get(f"{layer.url}?f=json")
            codes = AD.domain_codes(meta, layer.domain_field)
            used = {str(f[layer.domain_field]) for f in layers[layer.key]["features"] if layer.domain_field in f}
            domains[layer.key] = {"url": f"{layer.url}?f=json", "retrieved_at": at, "field": layer.domain_field,
                                  "codes": {c: n for c, n in codes.items() if c in used}}
    if layers["city-bulky"]["features"]:
        city = json.loads((HERE / "fixtures" / "_layers" / "trash-city.json").read_text(encoding="utf-8"))
        meta = json.loads((HERE / "fixtures" / "_layers" / "trash-city.meta.json").read_text(encoding="utf-8"))
        domains["city-bulky"] = {"url": meta["request_url"], "retrieved_at": meta["retrieved_at"], "field": "TRASHDAY",
                                 "codes": AD.domain_codes(city, "TRASHDAY")}
    return {"pin_id": pin_id, "address": pin.address, "kind": "cached-county-response",
            "note": "Recorded from the county's 311 layers by scripts/refresh_address_fixtures.py; replayed labeled with its date.",
            "locator": loc, "layers": layers, "domains": domains}


def main() -> int:
    if os.environ.get("MYAD_LIVE") != "1":
        print("refresh_address_fixtures.py talks to the county; set MYAD_LIVE=1", file=sys.stderr)
        return 2
    OUT.mkdir(parents=True, exist_ok=True)
    for pid in DEMO_PINS:
        doc = record(pid)
        (OUT / f"address-{pid}.json").write_text(json.dumps(doc, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        print("wrote", OUT / f"address-{pid}.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
