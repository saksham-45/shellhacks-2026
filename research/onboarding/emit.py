"""Write the proposal: manifest, sources fragment, fact skeleton, gaps report, findings, fetch log.

Everything here is derived from findings (things fetched in this run). Nothing is looked up or typed in.
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

import yaml

from research.freshness.net import now_iso

from .discover.base import Context
from .model import Finding, host_of
from .taxonomy import ADDRESS_DEPENDENT_POLYGON, NEAREST, TOPICS, classify_layer, desk_for, desk_id, lookup_method, pick_fields

FEDERAL_PUBLISHERS = {"census.gov": "U.S. Census Bureau", "nces.ed.gov": "National Center for Education Statistics",
                      "huduser.gov": "HUD Office of Policy Development and Research", "hud.gov": "U.S. Department of Housing and Urban Development",
                      "cisa.gov": "CISA", "fcc.gov": "Federal Communications Commission", "bls.gov": "Bureau of Labor Statistics"}
COUNTY_CHECKLIST = ["municipal-boundary", "parcel", "trash", "recycling", "school-attendance-elementary", "school-attendance-middle",
                    "school-attendance-high", "school-sites", "parks", "libraries",
                    "voting", "representatives", "water-sewer", "broadband", "public-safety", "zoning", "flood", "311-history"]
CITY_CHECKLIST = ["trash", "parks", "zoning"]
DESK_CHECKLIST = {"county": ["311", "211", "school-district", "housing-authority", "legal-aid", "license-and-tag-agent"],
                  "state": ["dmv"], "city": ["311"]}
QUESTIONS = {
    "municipal-boundary": "Which municipality (or unincorporated area) is this address in?",
    "parcel": "What does the property record say about this address (year built, use, condo flag, folio)?",
    "trash": "Which days is garbage collected at this address, and by whom?",
    "recycling": "Which day and week is recycling collected at this address?",
    "bulky-waste": "How is bulky trash scheduled at this address?",
    "school-attendance": "Which public school is this address zoned for?",
    "school-attendance-elementary": "Which public elementary school is this address zoned for?",
    "school-attendance-middle": "Which public middle school is this address zoned for?",
    "school-attendance-high": "Which public high school is this address zoned for?",
    "school-attendance-k8": "Which public K-8 school is this address zoned for?",
    "school-sites": "Which schools are nearest to this address?",
    "parks": "Which parks are nearest to this address?",
    "libraries": "Which library branch is nearest to this address?",
    "voting": "Where does a voter at this address vote?",
    "representatives": "Which districts and representatives cover this address?",
    "water-sewer": "Which utility provides water and sewer at this address?",
    "broadband": "Which providers advertise internet service on this block, at what speeds?",
    "public-safety": "Which fire and police stations serve this address?",
    "zoning": "What is the zoning at this address?",
    "flood": "What flood zone or evacuation zone is this address in?",
    "mosquito": "What mosquito-control activity is scheduled near this address?",
    "transit": "Which transit stops and routes are near this address?",
    "311-history": "What 311 requests were filed near this address?",
}


# ledger value_type (final list: text, code, codes, phone, date, money, quantity, weekdays, place, flag)
TOPIC_VALUE_TYPE = {"school-attendance-elementary": "place", "school-attendance-middle": "place", "school-attendance-high": "place",
                    "school-attendance-k8": "place", "municipal-boundary": "place", "parcel": "text", "trash": "weekdays", "recycling": "weekdays",
                    "bulky-waste": "text", "school-attendance": "place", "school-sites": "place", "parks": "place",
                    "libraries": "place", "voting": "place", "representatives": "text", "water-sewer": "text",
                    "broadband": "text", "public-safety": "place", "zoning": "code", "flood": "code", "mosquito": "text",
                    "transit": "place", "311-history": "text"}


def _slug(s: str, n: int = 40) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", str(s).lower())).strip("-")[:n] or "x"


def publisher_for(ctx: Context, url: str) -> str:
    h = host_of(url)
    for f in ctx.of("domain"):
        d = f.data.get("domain", "")
        if d and (h == d or h.endswith("." + d)) and "security contact" not in f.title:
            return f.data.get("organization") or f.title
    for f in ctx.of("domain"):
        d = f.data.get("domain", "")
        if d and (h == d or h.endswith("." + d)):
            return f.data.get("organization") or f.title
    for d, name in FEDERAL_PUBLISHERS.items():
        if h == d or h.endswith("." + d):
            return name
    return f"{h} (publisher not established)"


# --------------------------------------------------------------------------- adapters

def build_adapters(ctx: Context) -> dict[str, dict[str, list[dict[str, Any]]]]:
    """pack -> topic -> ranked candidate list."""
    out: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for f in ctx.of("arcgis_layer"):
        if f.data.get("sublayer"):
            continue
        fields = f.data.get("fields") or []
        names = [x.get("name", "") for x in fields]
        for m in classify_layer(f.data.get("service", ""), f.data.get("layer_name", ""), names, f.data.get("geometry")):
            out[f.jurisdiction][m.topic].append({
                "topic": m.topic, "endpoint": f.url, "layer_id": f.data.get("layer_id"), "layer_name": f.data.get("layer_name"),
                "service": f.data.get("service"), "geometry": f.data.get("geometry"), "fields": pick_fields(m.topic, fields),
                "all_fields": names, "method": lookup_method(m.topic, f.data.get("geometry")), "official": f.official,
                "confidence": round(min(1.0, m.score / 4.5), 2), "why": m.reason, "evidence_url": f.evidence.url,
                "retrieved_at": f.evidence.retrieved_at, "last_edit": f.data.get("edited"),
            })
    for pack in out:
        for topic in out[pack]:
            # higher confidence, official, then the most generic (shortest) layer name, MapServer before a FeatureServer twin
            out[pack][topic].sort(key=lambda a: (-a["confidence"], not a["official"], len(a["layer_name"] or ""), "FeatureServer" in a["endpoint"]))
    return out


# --------------------------------------------------------------------------- outputs

def build_manifest(ctx: Context, adapters) -> dict[str, Any]:
    packs = []
    for j in ctx.chain.levels:
        pid = j.pack_id
        langs = [{"name": f.title, "share_of_pop_5plus": f.data["share"], "speakers": f.data["speakers"],
                  "limited_english": f.data.get("limited_english"), "source": f.url, "year": f.data["year"]}
                 for f in ctx.of("language", pid)]
        desks = []
        for f in ctx.of("desk", pid):
            desks.append({"id": f"{pid}.{_slug(f.data.get('topic', 'desk'))}", "topic": f.data.get("topic"), "name": f.title,
                          "phone": f.data.get("phone"), "address": f.data.get("address"), "website": f.data.get("website"),
                          "url": f.url, "official": f.official, "found_by": f.discoverer, "quote": (f.evidence.quote or "")[:300],
                          "status": "unverified"})
        for f in ctx.of("domain", pid):
            if f.data.get("desk_topic"):
                desks.append({"id": f"{pid}.{_slug(f.data['desk_topic'])}", "topic": f.data["desk_topic"], "name": f.data.get("organization"),
                              "phone": None, "url": (f.data.get("homepage") or {}).get("final_url") or f.url, "official": True,
                              "found_by": f.discoverer, "status": "unverified (website only; phone not read)"})
        ad = []
        for topic, cands in sorted(adapters.get(pid, {}).items()):
            best = cands[0]
            ad.append({k: best[k] for k in ("topic", "endpoint", "layer_id", "layer_name", "fields", "geometry", "method", "official", "confidence")}
                      | {"alternatives": [{"endpoint": c["endpoint"], "layer_id": c["layer_id"], "layer_name": c["layer_name"], "confidence": c["confidence"]}
                                          for c in cands[1:4]]})
        transit = [{"title": f.title, "url": f.url, "official": f.official, **{k: f.data.get(k) for k in ("mdb_id", "data_type", "status", "key_required", "mirror")},
                    "reachable": (f.data.get("probe") or {}).get("status")} for f in ctx.of("gtfs_feed", pid)]
        portals = [{"title": f.title, "url": f.url, "platform": f.data.get("platform"), "official": f.official, "verified": f.data.get("verified")}
                   for f in ctx.of("portal", pid)]
        roots = [{"url": f.url, "verified": f.data.get("verified"), "services": f.data.get("service_count"), "found_by": f.data.get("found_by") or f.discoverer}
                 for f in ctx.of("arcgis_root", pid)]
        pack = {"id": pid, "parent": j.parent, "level": j.level, "name": j.name, "fips": j.fips}
        if langs:
            pack["languages"] = {"observed": langs, "note": "ACS language spoken at home; surfaces (UI languages) are a human decision."}
        if desks:
            pack["desks"] = desks
        if ad:
            pack["adapters"] = ad
        if transit:
            pack["transit"] = transit
        if portals:
            pack["portals"] = portals
        if roots:
            pack["gis_roots"] = roots
        packs.append(pack)
    return {"region": ctx.chain.region_id, "generated_at": now_iso(), "generator": "research.onboarding propose",
            "status": "proposed — every entry unverified until a human or agent confirms it", "packs": packs}


def _source(ctx: Context, sid: str, url: str, kind: str, jur: str, title: str, *, official: bool, extraction: str,
            check_every: str, notes: str, key_required: bool = False, publisher: str | None = None) -> dict[str, Any]:
    return {"id": sid, "publisher": publisher or publisher_for(ctx, url), "title": title, "url": url, "kind": kind,
            "jurisdiction": jur, "key_required": key_required, "check_every": check_every, "notes": notes,
            "official": official, "extraction": extraction}


def build_sources_and_facts(ctx: Context, adapters) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    sources: dict[str, dict[str, Any]] = {}
    facts: list[dict[str, Any]] = []
    fact_ids: set[str] = set()

    def add_fact(f: dict[str, Any]) -> None:
        base, i = f["id"], 2
        while f["id"] in fact_ids:
            f["id"] = f"{base}-{i}"
            i += 1
        fact_ids.add(f["id"])
        facts.append(f)

    def skeleton(fid, claim, jur, sid, url, ts, *, unit=None, check="P30D", notes="", **extra):
        return {"id": fid, "claim": claim, "value": None, "unit": unit, "jurisdiction": jur, "source_id": sid, "url": url,
                "quote": "", "retrieved_at": ts, "check_every": check, "status": "unsourced", "notes": notes, **extra}

    for pack, topics in adapters.items():
        for topic, cands in sorted(topics.items()):
            a = cands[0]
            sid = f"{pack}.gis-{_slug(a['service'], 30)}-{a['layer_id']}"
            sources.setdefault(sid, _source(ctx, sid, f"{a['endpoint']}/{a['layer_id']}", "gis-layer", pack,
                                            f"{a['service']} / {a['layer_name']}", official=a["official"], extraction="arcgis-query",
                                            check_every="P30D", notes=f"Proposed by onboarding for topic '{topic}' ({a['why']})."))
            if topic in ADDRESS_DEPENDENT_POLYGON or topic in NEAREST:
                add_fact(skeleton(
                    f"{pack}.{topic}.lookup", QUESTIONS.get(topic, topic), pack, sid, f"{a['endpoint']}/{a['layer_id']}", a["retrieved_at"],
                    notes=f"Onboarding proposal: layer '{a['layer_name']}' matched topic '{topic}' ({a['why']}). Verify the layer answers the "
                          f"question at a known address before marking verified.",
                    kind="lookup", desk=desk_id(pack, topic), value_type=TOPIC_VALUE_TYPE.get(topic, "text"),
                    **{"x-desk-name": desk_for(topic)},
                    lookup={"endpoint": a["endpoint"], "layer_id": a["layer_id"], "fields": a["fields"] or a["all_fields"][:5] or ["*"],
                            "method": a["method"], "question": QUESTIONS.get(topic, topic),
                            **({"params": {"distance": 30, "units": "esriSRUnit_Meter"}} if topic == "parcel" else {})},
                    **{"x-candidate": {"confidence": a["confidence"], "geometry": a["geometry"], "alternatives":
                                       [f"{c['endpoint']}/{c['layer_id']} ({c['layer_name']})" for c in cands[1:4]]}}))
    for f in ctx.findings:
        if f.kind == "desk":
            topic = _slug(f.data.get("topic", "desk"))
            sid = f"{f.jurisdiction}.{_slug(host_of(f.url), 30)}-{_slug(f.discoverer, 20)}"
            kind = "gis-layer" if "/rest/services" in f.url else "html"
            sources.setdefault(sid, _source(ctx, sid, f.url, kind, f.jurisdiction, f"{publisher_for(ctx, f.url)} — {f.title}"[:120],
                                            official=f.official, extraction="arcgis-query" if kind == "gis-layer" else "html-quote",
                                            check_every="P90D", notes=f"Desk contact candidates found by {f.discoverer}."))
            did = f"{f.jurisdiction}.{topic}"  # same id the manifest's desks list uses
            if f.data.get("phone"):
                add_fact(skeleton(f"{did}.phone", f"Phone for {f.title} ({f.data.get('topic')}).", f.jurisdiction,
                                  sid, f.url, f.evidence.retrieved_at, unit="phone", check="P90D", desk=did, value_type="phone",
                                  **{"x-desk-name": f.title[:120]},
                                  notes=f"Candidate phone read from a fetched page/record by {f.discoverer}; confirm on the office's own page.",
                                  **{"x-candidate": {"value": f.data["phone"], "quote": (f.evidence.quote or "")[:400], "official_source": f.official}}))
            if f.data.get("address"):
                add_fact(skeleton(f"{did}.address", f"Office address for {f.title}.", f.jurisdiction, sid, f.url,
                                  f.evidence.retrieved_at, unit="text", check="P365D", desk=did, value_type="place",
                                  **{"x-desk-name": f.title[:120]},
                                  notes=f"Candidate address from {f.discoverer}.", **{"x-candidate": {"value": f.data["address"]}}))
        elif f.kind == "language":
            sid = f"{f.jurisdiction}.acs-b16001-{f.data['year']}"
            sources.setdefault(sid, _source(ctx, sid, f.url, "dataset", f.jurisdiction, f"ACS {f.data['year']} {f.data['product']} B16001 language spoken at home",
                                            official=True, extraction="manual", check_every="P365D",
                                            notes=f"Pipe-delimited table-based summary file; labels from {f.data['labels_url']}.",
                                            publisher="U.S. Census Bureau"))
            add_fact(skeleton(f"{f.jurisdiction}.languages.{_slug(f.title, 30)}.share", f"Share of residents 5+ who speak {f.title} at home.",
                              f.jurisdiction, sid, f.url, f.evidence.retrieved_at, unit="ratio", check="P365D", value_type="quantity",
                              notes="Candidate from the ACS summary file row for this geography.",
                              **{"x-candidate": {"value": f.data["share"], "speakers": f.data["speakers"], "quote": f.evidence.quote}}))
        elif f.kind == "gtfs_feed" and f.url and not f.data.get("realtime"):
            sid = f"{f.jurisdiction}.gtfs-{_slug(f.data.get('provider', 'feed'), 30)}"
            sources.setdefault(sid, _source(ctx, sid, f.url, "gtfs", f.jurisdiction, f"{f.data.get('provider')} GTFS schedule",
                                            official=f.official, extraction="manual", check_every="P7D",
                                            notes=f"Mobility Database {f.data.get('mdb_id')} (catalog status {f.data.get('status')}); "
                                                  f"probe HTTP {(f.data.get('probe') or {}).get('status')}.",
                                            key_required=bool(f.data.get("key_required")), publisher=f.data.get("provider")))
            add_fact(skeleton(f"{f.jurisdiction}.transit.gtfs.{_slug(f.data.get('provider', 'feed'), 30)}.url",
                              f"Schedule feed (GTFS) for {f.data.get('provider')}.", f.jurisdiction, sid, f.url, f.evidence.retrieved_at,
                              unit="url", check="P7D", value_type="text", notes="Candidate feed from the Mobility Database catalog.",
                              **{"x-candidate": {"value": f.url, "mdb_id": f.data.get("mdb_id"), "probe": f.data.get("probe")}}))
        elif f.kind == "arcgis_service" and f.data.get("hosted") and re.search(r"\b311\b", f.title):
            sid = f"{f.jurisdiction}.ago-{_slug(f.title, 40)}"
            sources.setdefault(sid, _source(ctx, sid, f.url, "gis-layer", f.jurisdiction, f.title, official=f.official, extraction="arcgis-query",
                                            check_every="P30D", notes=f"ArcGIS Online item {f.data.get('item_id')} in org {f.data.get('org_id')}."))
        elif f.kind == "portal" and f.data.get("verified"):
            sid = f"{f.jurisdiction}.portal-{_slug(host_of(f.url), 40)}"
            sources.setdefault(sid, _source(ctx, sid, f.url, "html" if f.data.get("platform") == "arcgis-hub" else "api", f.jurisdiction,
                                            f.title, official=f.official, extraction="manual", check_every="P90D",
                                            notes=f"Open-data portal ({f.data.get('platform')}), found by {f.discoverer}."))
    return list(sources.values()), facts


def render_gaps(ctx: Context, adapters, manifest) -> str:
    L = [f"# Onboarding gaps — {ctx.chain.region_id}", "", f"Generated {now_iso()} by `research.onboarding propose`.", ""]
    L.append("Jurisdiction chain: " + " > ".join(f"{j.name} (`{j.pack_id}`, FIPS {j.fips})" for j in ctx.chain.levels))
    L += ["", "Everything below was fetched in this run. Nothing is verified yet: each item needs a human/agent pass before it "
          "becomes a `verified` ledger fact.", ""]
    for j in ctx.chain.levels:
        checklist = COUNTY_CHECKLIST if j.level == "county" else CITY_CHECKLIST if j.level == "city" else []
        desks = DESK_CHECKLIST.get(j.level, [])
        if not checklist and not desks:
            continue
        L += [f"## {j.name} (`{j.pack_id}`)", "", "| need | status | best candidate |", "| --- | --- | --- |"]
        topics = adapters.get(j.pack_id, {})
        for t in checklist:
            if t in topics:
                a = topics[t][0]
                L.append(f"| {t} | found ({'official' if a['official'] else 'secondary'}, confidence {a['confidence']}) | "
                         f"`{a['endpoint']}/{a['layer_id']}` {a['layer_name']} |")
            else:
                L.append(f"| {t} | **missing** | - |")
        present = {f.data.get("topic") for f in ctx.of("desk", j.pack_id)} | {f.data.get("desk_topic") for f in ctx.of("domain", j.pack_id)}
        for d in desks:
            hits = [f for f in ctx.of("desk", j.pack_id) if f.data.get("topic") == d]
            if hits:
                h = hits[0]
                more = f" (+{len(hits) - 1} more)" if len(hits) > 1 else ""
                L.append(f"| desk: {d} | found{' (phone candidate)' if h.data.get('phone') else ' (no phone)'} | {h.title}: {h.data.get('phone') or ''} {h.url}{more} |")
            elif d in present:
                doms = sorted((f for f in ctx.of("domain", j.pack_id) if f.data.get("desk_topic") == d), key=lambda f: len(f.data.get("domain", "")))
                L.append(f"| desk: {d} | website only, phone not read | " + ", ".join(f"{f.data.get('organization')}: {f.url}" for f in doms)[:300] + " |")
            else:
                L.append(f"| desk: {d} | **missing** | - |")
        if j.level == "county":
            g = ctx.of("gtfs_feed", j.pack_id)
            L.append(f"| transit GTFS | {'found: ' + str(len(g)) + ' feed(s)' if g else '**missing**'} | " + ", ".join(f.url for f in g if not f.data.get('realtime'))[:300] + " |")
            lg = ctx.of("language", j.pack_id)
            L.append(f"| languages (ACS) | {'found' if lg else '**missing**'} | " + ", ".join(f"{f.title} {f.data['share']:.1%}" for f in lg[:5]) + " |")
        L.append("")
    if ctx.gaps:
        L += ["## Gaps reported by discoverers", ""]
        for g in ctx.gaps:
            L.append(f"- **{g.topic}** (`{g.jurisdiction}`): {g.reason}" + (f" Tried: {', '.join(g.tried)}" if g.tried else ""))
        L.append("")
    if ctx.notes:
        L += ["## Run notes", ""] + [f"- {n.splitlines()[0][:300]}" for n in ctx.notes if n.strip()] + [""]
    L += ["## Rules this proposal followed", "",
          "- Only URLs that were fetched in this run are recorded. Phones are recorded only with the text they were read from.",
          "- Official = .gov/.mil host, a domain in the CISA .gov registry for this jurisdiction (or its registry contact domain), "
          "or a federal data host. Everything else is marked secondary.",
          "- Every fact skeleton is `status: unsourced` with `value: null`; candidates are in `x-candidate`.", ""]
    return "\n".join(L)


def emit(ctx: Context, out: Path, place: str, started_at: str) -> dict[str, Path]:
    out.mkdir(parents=True, exist_ok=True)
    adapters = build_adapters(ctx)
    manifest = build_manifest(ctx, adapters)
    manifest["place"] = place
    sources, facts = build_sources_and_facts(ctx, adapters)
    paths = {
        "manifest": out / "manifest.proposed.yaml",
        "sources": out / "sources.fragment.yaml",
        "facts": out / "facts.skeleton.json",
        "gaps": out / "gaps.md",
        "findings": out / "findings.json",
        "fetch_log": out / "fetch-log.json",
    }
    dump = lambda d: yaml.safe_dump(d, sort_keys=False, allow_unicode=True, width=120)  # noqa: E731
    paths["manifest"].write_text("# Proposed region pack manifest. Generated; review before use.\n" + dump(manifest), encoding="utf-8")
    paths["sources"].write_text("# Proposed sources.yaml fragment (same shape as research/sources.yaml). Review before merging.\n"
                                + dump({"sources": sources}), encoding="utf-8")
    paths["facts"].write_text(json.dumps(facts, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    paths["gaps"].write_text(render_gaps(ctx, adapters, manifest), encoding="utf-8")
    paths["findings"].write_text(json.dumps({"place": place, "started_at": started_at, "finished_at": now_iso(),
                                             "chain": [j.__dict__ | {"evidence": [e.__dict__ for e in j.evidence]} for j in ctx.chain.levels],
                                             "county_places": ctx.chain.county_places,
                                             "official_domains": ctx.official_domains,
                                             "findings": [f.to_dict() for f in ctx.findings],
                                             "gaps": [g.__dict__ for g in ctx.gaps], "notes": ctx.notes},
                                            indent=1, ensure_ascii=False, default=str) + "\n", encoding="utf-8")
    paths["fetch_log"].write_text(json.dumps(ctx.fetcher.log, indent=1) + "\n", encoding="utf-8")
    return paths


def load_context(run_dir: Path) -> Context:
    """Rebuild a Context from a run's findings.json + fetch-log.json (re-emit without refetching)."""
    from research.freshness.net import Fetcher

    from .model import Evidence, Gap, Jurisdiction, JurisdictionChain

    doc = json.loads((run_dir / "findings.json").read_text(encoding="utf-8"))
    levels = []
    for j in doc["chain"]:
        ev = [Evidence(**e) for e in j.pop("evidence", [])]
        levels.append(Jurisdiction(**{**j, "evidence": ev}))
    fetcher = Fetcher(replay_dir=run_dir / ".no-network")
    log = run_dir / "fetch-log.json"
    fetcher.log = json.loads(log.read_text()) if log.exists() else []
    ctx = Context(chain=JurisdictionChain(levels, doc.get("county_places", [])), fetcher=fetcher)
    ctx.official_domains = doc.get("official_domains", {})
    for f in doc["findings"]:
        ctx.add(Finding(**{**f, "evidence": Evidence(**f["evidence"])}))
    ctx.gaps = [Gap(**g) for g in doc.get("gaps", [])]
    ctx.notes = doc.get("notes", [])
    ctx.options["place"] = doc.get("place")
    ctx.options["started_at"] = doc.get("started_at")
    return ctx
