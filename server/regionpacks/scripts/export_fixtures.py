#!/usr/bin/env python3
"""Regenerate the offline demo answers and ledger drafts from the fixtures (no network, fixture mode).

Writes:
  ios/Packages/ADCityPack/Sources/ADCityPack/Resources/Fixtures/<pin>.json   answers the phone ships offline
  ios/Packages/ADCityPack/Sources/ADCityPack/Resources/Manifests/<pack>.json byte copies of the manifests
  ledger-draft/lookups.json          one `kind: lookup` entry per declared fact id (for myAD Research)
  ledger-draft/demo-<pin>.json       `status: demo` entries, ledger id <fact_id>.demo.<pin>
  .../Resources/Checks/check-ledger.json   Fee Check / Listing Check offline ledger slice (verified rows only)
  .../Resources/Checks/address-rules.json  Who handles my address: 311 layers and the ledger-gated police rules
  .../Resources/Checks/<name>.json        byte copies of fixtures/checks (fee replay script; owner-free listing replay;
                                           cached county answers for the address beat)
Usage: export_fixtures.py [--check]   (--check: exit 1 if any output would change; used by the CI hooks)
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
TREE = HERE.parent.parent
IOS = TREE / "ios" / "Packages" / "ADCityPack" / "Sources" / "ADCityPack" / "Resources"
sys.path.insert(0, str(HERE))

import runtime  # noqa: E402
from myad_regions import adapters as A  # noqa: E402
from myad_regions import address, checks  # noqa: E402
from myad_regions.manifests import PACK_ORDER, all_adapters, manifest  # noqa: E402
from myad_regions.pins import DEMO_PINS  # noqa: E402
from myad_regions.transport import FixtureTransport  # noqa: E402


def dump(obj) -> bytes:
    return (json.dumps(obj, indent=1, ensure_ascii=False) + "\n").encode("utf-8")


def base_id(fid: str) -> str:
    parts = [p for p in fid.split(".") if not p.isdigit()]
    return ".".join(parts)


def lookup_entries() -> list[dict]:
    seed = json.loads((HERE / "ledger-draft" / "_seed.json").read_text(encoding="utf-8"))
    claims = seed["claims"]
    out = []
    for c in seed["census_lookups"]:
        e = dict(c)
        e["desk"] = manifest(c["id"].split(".")[0]).desks[0]
        out.append(e)
    for d in all_adapters():
        a = A.adapter(d.id)
        plan = a.plan(runtime.ResolvedPin(0.0, 0.0, None, "device_coords")) if d.sources else []
        endpoint = plan[0].url.split("?")[0] if plan else None
        for f in d.facts:
            rank = next((p for p in f.id.split(".") if p.isdigit()), None)
            claim = claims.get(f.id) or claims.get(base_id(f.id)) or claims.get(base_id(f.id).rsplit(".", 1)[0])
            if claim and rank:
                claim = f"{claim} (rank {rank} by straight-line distance)"
            out.append({
                "id": f.id, "kind": "lookup", "claim": claim, "value": None, "unit": "year" if f.id.endswith("year-built") else None,
                "jurisdiction": d.pack, "desk": d.desk, "topics": list(f.topics),
                "source_id": d.sources[0] if d.sources else None, "url": endpoint, "quote": None, "retrieved_at": None,
                "check_every": None, "status": "verified" if d.sources else "unsourced",
                "lookup": {"adapter": d.id, "endpoint": endpoint, "fields": list(getattr(a, "out_fields", ()) or ()),
                           "question": d.answers[0]},
            })
    from myad_regions.manifests import sources
    for e in out:
        if e["source_id"] and e["check_every"] is None:
            e["check_every"] = sources()[e["source_id"]].check_every
    return out


def demo_entries(pin_id: str, results: list[dict]) -> list[dict]:
    out = []
    for r in results:
        if (r.get("basis") or {}).get("lookup") == "ledger":
            continue  # Fee Check rows already live in Research's ledger under their own ids; never copy them as demo
        e = {"id": r["ledger_id"], "lookup_id": r["fact_id"], "value": r["value"], "outcome": r["status"],
             "jurisdiction": r["jurisdiction"], "desk": r["desk"], "source_id": r["source_id"], "url": r["url"],
             "quote": r["quote"], "retrieved_at": r["retrieved_at"], "check_every": r["check_every"],
             "status": "demo" if r["status"] == "ok" else "unsourced"}
        if r["not_applicable"]:
            e["not_applicable"] = r["not_applicable"]
        if r["error"]:
            e["error"] = r["error"]
        out.append(e)
    return out


def outputs() -> dict[Path, bytes]:
    files: dict[Path, bytes] = {}
    t = FixtureTransport()
    for pid, p in DEMO_PINS.items():
        results = runtime.answer(p, transport=t)
        packs = runtime.resolve(p, transport=t)
        files[IOS / "Fixtures" / f"{pid}.json"] = dump({
            "pin_id": pid, "pin": {"address": p.address, "lat": p.lat, "lon": p.lon},
            "pack_ids": packs, "results": results})
        files[HERE / "ledger-draft" / f"demo-{pid}.json"] = dump(demo_entries(pid, results))
    for pack in PACK_ORDER:
        files[IOS / "Manifests" / f"{pack}.json"] = (HERE / pack / "manifest.json").read_bytes()
    files[HERE / "ledger-draft" / "lookups.json"] = dump(lookup_entries())
    files[IOS / "Checks" / "check-ledger.json"] = dump(checks.check_ledger())
    files[IOS / "Checks" / "address-rules.json"] = dump(address.address_rules())
    for f in sorted((HERE / "fixtures" / "checks").glob("*.json")):
        files[IOS / "Checks" / f.name] = f.read_bytes()
    return files


def main(argv: list[str]) -> int:
    os.environ.pop("MYAD_LIVE", None)  # exports are fixture-mode only
    check = "--check" in argv
    stale = []
    for path, data in outputs().items():
        if check:
            if not path.exists() or path.read_bytes() != data:
                stale.append(str(path.relative_to(TREE)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if stale:
        print("out of sync with server/regionpacks (run server/regionpacks/scripts/export_fixtures.py):", file=sys.stderr)
        for s in stale:
            print("  " + s, file=sys.stderr)
        return 1
    print("export: " + ("in sync" if check else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
