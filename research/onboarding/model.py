"""Types for region onboarding."""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any, Literal
from urllib.parse import urlsplit

Level = Literal["country", "state", "county", "city"]
FindingKind = Literal["domain", "desk", "portal", "arcgis_root", "arcgis_service", "arcgis_layer",
                      "gtfs_feed", "dataset", "language", "page", "catalog"]

FEDERAL_HOSTS = ("census.gov", "hud.gov", "huduser.gov", "nces.ed.gov", "ed.gov", "fcc.gov", "bls.gov",
                 "data.gov", "cisa.gov", "lsc.gov", "usa.gov")
LEGAL_SUFFIX = re.compile(r"\s+(county|parish|borough|city and borough|census area|municipality|city|town|village|"
                          r"borough|cdp|consolidated government|metropolitan government|unified government)$", re.I)


def base_name(name: str) -> str:
    """'Miami-Dade County' -> 'Miami-Dade'; 'Miami city' -> 'Miami'."""
    n = name.strip()
    for _ in range(2):
        n = LEGAL_SUFFIX.sub("", n).strip()
    return n


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", base_name(name).lower())


def norm_words(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def host_of(url: str) -> str:
    return urlsplit(url).netloc.lower().split(":")[0]


@dataclass
class Evidence:
    url: str
    http_status: int | None
    retrieved_at: str
    provider: str
    official: bool
    quote: str | None = None


@dataclass
class Jurisdiction:
    level: Level
    name: str
    pack_id: str
    parent: str | None
    fips: str | None = None
    state_abbr: str | None = None
    evidence: list[Evidence] = field(default_factory=list)

    @property
    def base(self) -> str:
        return base_name(self.name)


@dataclass
class JurisdictionChain:
    levels: list[Jurisdiction]
    county_places: list[dict[str, str]] = field(default_factory=list)  # every place row in the county

    def by_level(self, level: str) -> Jurisdiction | None:
        return next((j for j in self.levels if j.level == level), None)

    def by_pack(self, pack_id: str) -> Jurisdiction | None:
        return next((j for j in self.levels if j.pack_id == pack_id), None)

    def most_local(self) -> Jurisdiction:
        return self.levels[-1]

    @property
    def region_id(self) -> str:
        c = self.by_level("county")
        return c.pack_id if c else self.most_local().pack_id


@dataclass
class Finding:
    kind: FindingKind
    jurisdiction: str
    title: str
    url: str
    official: bool
    discoverer: str
    evidence: Evidence
    data: dict[str, Any] = field(default_factory=dict)

    def key(self) -> tuple[str, str, str]:
        return (self.kind, self.url.rstrip("/").lower(), str(self.data.get("layer_id", "")))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class Gap:
    topic: str
    jurisdiction: str
    reason: str
    tried: list[str] = field(default_factory=list)
