"""Pack manifests (server/regionpacks/<pack>/manifest.json), the source registry excerpt, and topics.

Loaded once, then read-only (frozen dataclasses and tuples), so parallel workers can share them.
Desk ids live ONLY in the manifests (placeholder ids until myAD Research posts the final ones).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

ROOT = Path(__file__).resolve().parent.parent
PACK_ORDER = ("us", "us-fl", "us-fl-miamidade", "us-fl-miami")  # country first, most local last
LEVELS = ("country", "state", "county", "city")

# TODO(myAD Research): research/topics.yaml is the single topic vocabulary (ARCHITECTURE.md §13.x). It does
# not exist yet; until it does, this constant is the one list. tests/test_manifests.py checks every manifest
# and ledger-draft tag against research/topics.yaml when present, else against this constant.
TOPICS = frozenset({"trash", "schools", "parcel", "water", "parks", "libraries", "voting",
                    "representatives", "transit", "tolls", "rent", "desk", "municipality", "flood", "storm",
                    "immigration", "scams", "license"})


@dataclass(frozen=True)
class FactDecl:
    id: str
    topics: tuple[str, ...]


@dataclass(frozen=True)
class AdapterDecl:
    id: str
    pack: str
    answers: tuple[str, ...]
    sources: tuple[str, ...]
    desk: str
    facts: tuple[FactDecl, ...]

    @property
    def fact_ids(self) -> tuple[str, ...]:
        return tuple(f.id for f in self.facts)


@dataclass(frozen=True)
class Boundary:
    method: str               # always | any_child | fact_ok | fact_equals
    fact: str | None = None
    value: str | None = None


@dataclass(frozen=True)
class Manifest:
    id: str
    parent: str | None
    level: str
    boundary: Boundary
    adapters: tuple[AdapterDecl, ...]
    sources: tuple[str, ...]
    desks: tuple[str, ...]
    desks_placeholder: bool
    languages: tuple[str, ...]


@dataclass(frozen=True)
class Source:
    id: str
    publisher: str
    url: str
    check_every: str | None


def _manifest(data: dict) -> Manifest:
    pack = data["id"]
    adapters = tuple(
        AdapterDecl(id=a["id"], pack=pack, answers=tuple(a["answers"]), sources=tuple(a["sources"]),
                    desk=a["desk"],
                    facts=tuple(FactDecl(f["id"], tuple(f.get("topics") or ())) if isinstance(f, dict)
                                else FactDecl(f, ()) for f in a.get("facts") or ()))
        for a in data.get("adapters") or ())
    b = data.get("boundary") or {"method": "always"}
    return Manifest(id=pack, parent=data.get("parent"), level=data.get("level", ""),
                    boundary=Boundary(b["method"], b.get("fact"), b.get("value")), adapters=adapters,
                    sources=tuple(data.get("sources") or ()), desks=tuple(data.get("desks") or ()),
                    desks_placeholder=bool(data.get("desks_placeholder")),
                    languages=tuple(data.get("languages") or ()))


@lru_cache(maxsize=1)
def manifests() -> tuple[Manifest, ...]:
    return tuple(_manifest(json.loads((ROOT / p / "manifest.json").read_text(encoding="utf-8"))) for p in PACK_ORDER)


def manifest(pack: str) -> Manifest:
    for m in manifests():
        if m.id == pack:
            return m
    raise KeyError(pack)


@lru_cache(maxsize=1)
def sources() -> Mapping[str, Source]:
    data = json.loads((ROOT / "sources.json").read_text(encoding="utf-8"))
    return MappingProxyType({s["id"]: Source(s["id"], s["publisher"], s["url"], s.get("check_every"))
                             for s in data["sources"]})


def all_adapters() -> tuple[AdapterDecl, ...]:
    return tuple(a for m in manifests() for a in m.adapters)


def adapter_decl(adapter_id: str) -> AdapterDecl:
    for a in all_adapters():
        if a.id == adapter_id:
            return a
    raise KeyError(adapter_id)


def adapters_for_topic(topic: str, packs: tuple[str, ...] | list[str] | None = None) -> list[tuple[str, list[str]]]:
    """(adapter id, fact ids tagged `topic`) for every adapter with at least one such fact.

    For the household-week path (which has the pin): run only the adapters the week's topics need.
    `packs` narrows the answer to a resolved pack chain.
    """
    out = []
    for a in all_adapters():
        if packs is not None and a.pack not in packs:
            continue
        ids = [f.id for f in a.facts if topic in f.topics]
        if ids:
            out.append((a.id, ids))
    return out


def defer_target(question: str, chain: tuple[str, ...] | list[str], exclude_pack: str) -> dict | None:
    """FactRef JSON ({pack_id, fact_id}) a not-applicable answer defers to: the first declared fact of the most
    local pack in the chain that is MORE local than `exclude_pack` and has an adapter for the same question.
    Never defers upward: a parent cannot answer inside a child government that hauls its own."""
    chain = list(chain)
    more_local = chain[chain.index(exclude_pack) + 1:] if exclude_pack in chain else []
    for pack in reversed(more_local):
        for a in manifest(pack).adapters:
            if question in a.answers and a.facts:
                return {"pack_id": pack, "fact_id": a.facts[0].id}
    return None
