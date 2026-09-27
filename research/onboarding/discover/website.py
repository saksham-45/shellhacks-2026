"""Bounded crawl of official homepages: harvest ArcGIS roots, portals, GTFS links, desk phones (quoted)."""
from __future__ import annotations

import re
from urllib.parse import urljoin, urlsplit

from research.freshness.text import normalize

from ..model import Finding, host_of
from .base import Context

FOLLOW = re.compile(r"\b(open ?data|gis|maps?|developer|data portal|transit|transportation|311|211|solid waste|garbage|"
                    r"trash|recycl|schools?|housing|legal|water|contact us|departments|services)\b", re.I)
ARCGIS_ROOT = re.compile(r"(https?://[^\s\"'<>]+?/(?:arcgis|server|gis)/rest/services)", re.I)
HUB = re.compile(r"https?://[a-z0-9.-]+\.(?:hub\.arcgis\.com|opendata\.arcgis\.com|maps\.arcgis\.com)[^\s\"'<>]*", re.I)
GTFS = re.compile(r"(gtfs|google_transit)[^\"'<>\s]*\.zip|/gtfs\b", re.I)
PHONE = re.compile(r"(?<![\d-])(?:\+?1[\s.-]?)?\(?([2-9]\d{2})\)?[\s.-]?([2-9]\d{2})[\s.-](\d{4})(?![\d-])")
SHORT = re.compile(r"(?<![\d-])(311|211)(?![\d-])")
DESK_TOPICS = {
    "311": re.compile(r"\b311\b"),
    "211": re.compile(r"\b211\b"),
    "legal-aid": re.compile(r"legal (aid|services)", re.I),
    "housing-authority": re.compile(r"public housing|housing authority|section 8", re.I),
    "school-district": re.compile(r"school district|public schools", re.I),
    "license-and-tag-agent": re.compile(r"tax collector|driver'?s? licen[cs]e|auto tag", re.I),
    "solid-waste": re.compile(r"solid waste|garbage|trash", re.I),
    "water-utility": re.compile(r"water and sewer|water & sewer|water utility", re.I),
}
MAX_HOME_PER_JUR = 6
META_REFRESH = re.compile(r"<meta[^>]+http-equiv=[\"']?refresh[^>]+content=[\"']?\s*\d+\s*;\s*url=([^\"'>]+)", re.I)
MAX_FOLLOW_PER_SITE = 6


class WebsiteDiscoverer:
    name = "official-website"

    def run(self, ctx: Context) -> None:
        for jur in [j for j in ctx.chain.levels if j.level in ("county", "city")]:
            doms = ctx.of("domain", jur.pack_id)
            doms.sort(key=lambda f: (0 if "security-contact" in f.data.get("via", "") else 1 if not f.data.get("desk_topic") else 2))
            seen_hosts: set[str] = set()
            fetched = 0
            for d in doms:
                if fetched >= MAX_HOME_PER_JUR:
                    break
                r = ctx.fetcher.get(f"https://{d.data['domain']}/", max_bytes=3_000_000)
                fetched += 1
                mr = META_REFRESH.search(r.content[:5000].decode("utf-8", errors="replace")) if r.ok else None
                if mr:
                    r = ctx.fetcher.get(urljoin(r.final_url, mr.group(1).strip("'\" ")), max_bytes=3_000_000)
                if not r.ok:
                    d.data["homepage"] = {"error": r.error}
                    continue
                final_host = host_of(r.final_url)
                d.data["homepage"] = {"final_url": r.final_url, "status": r.status}
                if final_host in seen_hosts:
                    continue
                seen_hosts.add(final_host)
                ctx.official_domains.setdefault(final_host, jur.pack_id)
                ctx.add(Finding("page", jur.pack_id, f"homepage of {d.data.get('organization')}", r.final_url,
                                ctx.is_official_host(final_host), self.name, ctx.evidence(r, self.name),
                                {"desk_topic": d.data.get("desk_topic"), "organization": d.data.get("organization")}))
                follow = self._harvest(ctx, jur.pack_id, r, d.data.get("organization"), d.data.get("desk_topic"))
                for url in follow[:MAX_FOLLOW_PER_SITE]:
                    rr = ctx.fetcher.get(url, max_bytes=3_000_000)
                    if rr.ok and "html" in rr.content_type:
                        self._harvest(ctx, jur.pack_id, rr, d.data.get("organization"), d.data.get("desk_topic"))

    def _harvest(self, ctx: Context, jur: str, r, org: str | None, desk_topic: str | None) -> list[str]:
        from bs4 import BeautifulSoup

        html = r.content.decode("utf-8", errors="replace")
        soup = BeautifulSoup(html, "html.parser")
        base = r.final_url
        site = host_of(base)
        follow: list[str] = []
        for m in ARCGIS_ROOT.finditer(html):
            root = m.group(1)
            ctx.add(Finding("arcgis_root", ctx.owner_of_host(host_of(root)) or jur, f"ArcGIS REST root linked from {site}", root,
                            ctx.is_official_host(host_of(root)), self.name, ctx.evidence(r, self.name, quote=root),
                            {"linked_from": base, "verified": False}))
        for a in soup.find_all("a", href=True):
            href = urljoin(base, a["href"].strip())
            if not href.startswith("http"):
                continue
            text = normalize(a.get_text(" "))[:120]
            h = host_of(href)
            if HUB.match(href):
                ctx.add(Finding("portal", jur, f"ArcGIS Hub/Online site: {text or h}", href.split("?")[0], ctx.is_official_host(h),
                                self.name, ctx.evidence(r, self.name, quote=text or href), {"platform": "arcgis-hub", "linked_from": base, "verified": False}))
            elif re.search(r"\bopen ?data\b|data portal", text, re.I) and h != site:
                ctx.add(Finding("portal", jur, f"open data link: {text}", href.split("#")[0], ctx.is_official_host(h), self.name,
                                ctx.evidence(r, self.name, quote=text), {"platform": "unknown", "linked_from": base, "verified": False}))
            if GTFS.search(href):
                ctx.add(Finding("gtfs_feed", jur, f"GTFS link: {text or href}", href, ctx.is_official_host(h), self.name,
                                ctx.evidence(r, self.name, quote=text or href), {"linked_from": base, "verified": False}))
            if h == site and FOLLOW.search(text) and href != base and href not in follow and not re.search(r"\.(pdf|zip|jpg|png)$", href, re.I):
                follow.append(href.split("#")[0])
        self._phones(ctx, jur, r, soup, org, desk_topic)
        return follow

    def _phones(self, ctx: Context, jur: str, r, soup, org: str | None, desk_topic: str | None) -> None:
        text = normalize(soup.get_text(" "))
        found: dict[str, int] = {}
        for rx in (PHONE, SHORT):
            for m in rx.finditer(text):
                s, e = max(0, m.start() - 90), min(len(text), m.end() + 40)
                quote = text[s:e]
                topic = next((t for t, trx in DESK_TOPICS.items() if trx.search(quote)), None)
                if rx is SHORT:
                    topic = m.group(1)
                    if not re.search(r"call|dial|phone|text|contact|llame|rele", quote, re.I):
                        continue
                if topic is None and desk_topic and re.search(r"call|phone|contact|tel", quote, re.I):
                    topic = desk_topic
                if topic is None:
                    continue
                if found.get(topic, 0) >= 2:
                    continue
                found[topic] = found.get(topic, 0) + 1
                phone = m.group(1) if rx is SHORT else f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
                ctx.add(Finding("desk", jur, f"{topic} phone on {host_of(r.final_url)}", r.final_url, ctx.is_official_host(host_of(r.final_url)),
                                self.name, ctx.evidence(r, self.name, quote=quote),
                                {"topic": topic, "phone": phone, "organization": org, "layer_id": f"{topic}:{phone}"}))
