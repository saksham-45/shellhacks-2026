"""Discoverer protocol and the shared findings board."""
from __future__ import annotations

import traceback
from dataclasses import dataclass, field
from typing import Any, Protocol

from research.freshness.net import BudgetExceeded, Fetched, Fetcher, NetworkDisabled

from ..model import FEDERAL_HOSTS, Evidence, Finding, Gap, JurisdictionChain, host_of


class Discoverer(Protocol):
    name: str

    def run(self, ctx: "Context") -> None: ...


@dataclass
class Context:
    chain: JurisdictionChain
    fetcher: Fetcher
    findings: list[Finding] = field(default_factory=list)
    gaps: list[Gap] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    options: dict[str, Any] = field(default_factory=dict)
    _keys: set = field(default_factory=set)
    # official domain -> pack id that owns it
    official_domains: dict[str, str] = field(default_factory=dict)

    def add(self, f: Finding) -> bool:
        k = f.key()
        if k in self._keys:
            return False
        self._keys.add(k)
        self.findings.append(f)
        return True

    def gap(self, topic: str, jurisdiction: str, reason: str, tried: list[str] | None = None) -> None:
        self.gaps.append(Gap(topic, jurisdiction, reason, tried or []))

    def of(self, kind: str, jurisdiction: str | None = None) -> list[Finding]:
        return [f for f in self.findings if f.kind == kind and (jurisdiction is None or f.jurisdiction == jurisdiction)]

    def is_official_host(self, host: str) -> bool:
        host = host.lower()
        if host.endswith(".gov") or host.endswith(".mil") or host.endswith(".fed.us"):
            return True
        if any(host == h or host.endswith("." + h) for h in FEDERAL_HOSTS):
            return True
        return any(host == d or host.endswith("." + d) for d in self.official_domains)

    def owner_of_host(self, host: str) -> str | None:
        host = host.lower()
        best = None
        for d, jur in self.official_domains.items():
            if host == d or host.endswith("." + d):
                if best is None or len(d) > len(best[0]):
                    best = (d, jur)
        return best[1] if best else None

    def evidence(self, r: Fetched, provider: str, quote: str | None = None, official: bool | None = None) -> Evidence:
        off = self.is_official_host(host_of(r.final_url or r.url)) if official is None else official
        return Evidence(r.url, r.status, r.retrieved_at, provider, off, quote)


def run_all(ctx: Context, discoverers: list[Discoverer]) -> None:
    for d in discoverers:
        try:
            d.run(ctx)
        except BudgetExceeded as e:
            ctx.notes.append(f"{d.name}: stopped, {e}")
            ctx.gap("request-budget", ctx.chain.region_id, f"{d.name} stopped early: {e}")
        except NetworkDisabled:
            raise
        except Exception as e:  # a broken discoverer must not sink the run
            ctx.notes.append(f"{d.name}: crashed: {type(e).__name__}: {e}")
            ctx.notes.append(traceback.format_exc(limit=3))
