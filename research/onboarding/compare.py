"""Compare an onboarding run with the endpoints listed in a plan markdown file."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SERVICE = re.compile(r"`([A-Za-z0-9_*]+(?:/[A-Za-z0-9_*]+)*/(?:MapServer|FeatureServer))`")
SERVICE_BARE = re.compile(r"`([A-Za-z0-9_]+/[A-Za-z0-9_*]+)`(?!\s*/)")
HOSTREF = re.compile(r"`((?:[a-z0-9-]+\.)+(?:gov|com|org|net|edu)(?:/[^`\s]*)?)`")
URL = re.compile(r"https?://[^\s`)>|\"']+")
LAYER_NUM = re.compile(r"(?<![\w.])(\d{1,2})\s+(?=[A-Za-z])")


@dataclass
class PlanItem:
    kind: str  # "service" | "url"
    ref: str
    context: str
    layers: list[int] = field(default_factory=list)


def _norm_url(u: str) -> str:
    u = re.sub(r"^https?://", "", u.strip().rstrip(".,;")).lower()
    u = u.split("#")[0]
    u = re.sub(r"\?f=p?json$", "", u)
    return u.rstrip("/")


def parse_plan(md: str) -> list[PlanItem]:
    items: list[PlanItem] = []
    seen: set[tuple[str, str]] = set()
    for line in md.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.strip().startswith("|") else [line]
        for m in SERVICE.finditer(line):
            ref = m.group(1)
            layers = []
            if len(cells) >= 3:
                layers = [int(x) for x in LAYER_NUM.findall(cells[-1])]
            if ("service", ref) not in seen:
                seen.add(("service", ref))
                items.append(PlanItem("service", ref, (cells[0] if len(cells) > 1 else line)[:80], layers))
        for m in SERVICE_BARE.finditer(line):
            ref = m.group(1)
            if "RealTime" in ref or ref.startswith("SolidWaste/") or ref.startswith("BusMetro"):
                if ("service", ref) not in seen:
                    seen.add(("service", ref))
                    items.append(PlanItem("service", ref, (cells[0] if len(cells) > 1 else line)[:80]))
        for m in HOSTREF.finditer(line):
            u = "https://" + m.group(1)
            if ("url", _norm_url(u)) not in seen and not any(_norm_url(u) in x[1] for x in seen if x[0] == "url"):
                seen.add(("url", _norm_url(u)))
                items.append(PlanItem("url", u, (cells[0] if len(cells) > 1 else line.strip())[:80]))
        for m in URL.finditer(line):
            u = m.group(0).rstrip(".,;")
            if ("url", _norm_url(u)) not in seen:
                seen.add(("url", _norm_url(u)))
                items.append(PlanItem("url", u, (cells[0] if len(cells) > 1 else line.strip())[:80]))
    return items


def compare(run_dir: Path, plan_md: Path) -> dict[str, Any]:
    run = json.loads((run_dir / "findings.json").read_text(encoding="utf-8"))
    findings = run["findings"]
    fetched = [e["url"] for e in json.loads((run_dir / "fetch-log.json").read_text()) if not e.get("error")]
    fetched_final = [e["final_url"] for e in json.loads((run_dir / "fetch-log.json").read_text()) if not e.get("error")]
    urls = [f["url"] for f in findings]
    layer_by_service: dict[str, set] = {}
    for f in findings:
        if f["kind"] == "arcgis_layer":
            layer_by_service.setdefault(f["url"].lower(), set()).add(f["data"].get("layer_id"))
    manifest_text = (run_dir / "manifest.proposed.yaml").read_text(encoding="utf-8").lower()
    results = []
    for it in parse_plan(plan_md.read_text(encoding="utf-8")):
        found, how, where, layers_seen = False, "", "", []
        if it.kind == "service":
            rx = re.compile("/" + re.escape(it.ref).replace(r"\*", "[^/]*") + r"$", re.I)
            svc_parts = it.ref.rsplit("/", 1)
            rx2 = re.compile("/" + re.escape(it.ref).replace(r"\*", "[^/]*") + r"/(MapServer|FeatureServer)$", re.I)
            hits = [u for u in urls if rx.search(u.rstrip("/")) or rx2.search(u.rstrip("/"))]
            if hits:
                found, where = True, hits[0]
                kinds = {f["kind"] for f in findings if f["url"] in hits}
                how = "service enumerated" + (" + layers read" if "arcgis_layer" in kinds else "")
                layers_seen = sorted(x for h in hits for x in layer_by_service.get(h.lower(), set()) if isinstance(x, int))
                del svc_parts
        else:
            n = _norm_url(it.ref)
            direct = [u for u in urls if _norm_url(u) == n or _norm_url(u).startswith(n + "/")]
            fetched_hit = [u for u in fetched + fetched_final if _norm_url(u) == n]
            if direct:
                found, how, where = True, "recorded as a finding", direct[0]
            elif fetched_hit:
                found, how, where = True, "fetched during the run", fetched_hit[0]
            else:
                host = n.split("/")[0]
                host_hits = [u for u in urls if _norm_url(u).split("/")[0] == host]
                if host_hits:
                    how, where = f"host found ({len(host_hits)} findings on {host}), exact page not", host_hits[0]
        in_manifest = any(str(where).lower().rstrip("/") in manifest_text for _ in [0]) if where else False
        results.append({"kind": it.kind, "ref": it.ref, "context": it.context, "plan_layers": it.layers, "found": found,
                        "how": how, "where": where, "layers_seen": layers_seen,
                        "plan_layers_missing": [x for x in it.layers if layers_seen and x not in layers_seen],
                        "adapter_in_manifest": in_manifest})
    n_found = sum(1 for r in results if r["found"])
    return {"plan": str(plan_md), "run": str(run_dir), "items": results, "found": n_found, "total": len(results)}


def render(cmp: dict[str, Any]) -> str:
    L = [f"Plan endpoints found by the pipeline on its own: **{cmp['found']} of {cmp['total']}**.", "",
         "| plan item | context | found? | how | where / notes |", "| --- | --- | --- | --- | --- |"]
    for r in cmp["items"]:
        note = r["where"] or ""
        if r["plan_layers_missing"]:
            note += f" (plan layers not read: {r['plan_layers_missing']})"
        L.append(f"| `{r['ref']}` | {r['context'].replace('|', '/')} | {'yes' if r['found'] else '**no**'} | {r['how']} | {note} |")
    return "\n".join(L)
