#!/usr/bin/env python3
"""Refresh the cached Listing Check replay from the county parcel layer (live, opt-in, no key).

Queries MD_LandInformation layer 26 for folio 0141370230020 (111 NW 1 ST, the county's own building, so the demo
never involves a private owner) and writes fixtures/checks/listing-county-building.json through checks.minimize_parcel,
which keeps only folio, site address, condo flag, land use and owner KIND. Owner names never touch disk.
Then run export_fixtures.py to copy it into ADCityPack.
"""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
from myad_regions import checks  # noqa: E402

FOLIO = "0141370230020"


def main() -> int:
    q = {"where": f"FOLIO='{FOLIO}'", "outFields": ",".join(checks.PARCEL_FIELDS),
         "returnGeometry": "false", "f": "json"}
    url = f"{checks.PARCEL_LAYER}/query?" + urllib.parse.urlencode(q)
    with urllib.request.urlopen(url, timeout=20) as r:
        data = json.load(r)
    feats = data.get("features") or []
    if len(feats) != 1:
        print(f"expected one parcel for {FOLIO}, got {len(feats)}: {data.get('error')}", file=sys.stderr)
        return 1
    now = datetime.now().astimezone().isoformat(timespec="seconds")
    public_url = f"{checks.PARCEL_LAYER}/query?" + urllib.parse.urlencode({**q, "outFields": "FOLIO,TRUE_SITE_ADDR,CONDO_FLAG,DOR_DESC"})
    out = checks.minimize_parcel(feats[0]["attributes"], request_url=public_url, retrieved_at=now)
    path = HERE / "fixtures" / "checks" / "listing-county-building.json"
    path.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(HERE)}: owner_kind={out['owner_kind']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
