"""Which ledger facts answer Fee Check, as Regions declares them (read-only).

Regions exposes official fees and payment rules through its `*.fee-check-*` adapters
(server/regionpacks/CONTRACT.md §2, README "Hazards and Fee Check"): each adapter lives in the pack whose
government owns the question, names a desk, and declares fact ids; each fact is answered ONLY from myAD
Research's verified row in research/facts/*.json (basis.lookup = "ledger"; no value in code or fixtures, no
request, `ledger_id == fact_id`, never demo). Because those rows are the same rows this server's Ledger
loads, the matcher reads values from the Ledger (through the verifier) and reads only the *declarations*
from the manifests: pack parents (the region chain), per-pack desk ids, and fee groups.

This module parses manifest JSON only. It never imports, executes or writes anything under
server/regionpacks/ (owned by myAD Regions).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

FEE_ADAPTER_MARK = ".fee-check-"


@dataclass(frozen=True)
class FeeGroup:
    key: str                      # the adapter's `answers` key, e.g. "fees.license"
    adapter_id: str
    pack_id: str
    desk_id: str | None
    fact_ids: tuple[str, ...]
    fact_topics: Mapping[str, tuple[str, ...]] = field(default_factory=dict)

    def topics(self) -> set[str]:
        return {t for ts in self.fact_topics.values() for t in ts}


@dataclass(frozen=True)
class FeeCatalog:
    groups: tuple[FeeGroup, ...] = ()
    parents: Mapping[str, str | None] = field(default_factory=dict)
    pack_desks: Mapping[str, tuple[str, ...]] = field(default_factory=dict)

    @classmethod
    def from_manifests(cls, packs_dir: Path | str) -> "FeeCatalog":
        """Read `<packs_dir>/*/manifest.json`. A missing folder or a broken manifest yields fewer groups,
        never an exception: Fee Check then answers with the desk only."""
        root = Path(packs_dir)
        groups: list[FeeGroup] = []
        parents: dict[str, str | None] = {}
        desks: dict[str, tuple[str, ...]] = {}
        for path in sorted(root.glob("*/manifest.json")) if root.is_dir() else []:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(data, dict) or not isinstance(data.get("id"), str):
                continue
            pack = data["id"]
            parent = data.get("parent")
            parents[pack] = parent if isinstance(parent, str) else None
            desks[pack] = tuple(d for d in data.get("desks") or [] if isinstance(d, str))
            for adapter in data.get("adapters") or []:
                group = _group(pack, adapter)
                if group is not None:
                    groups.append(group)
        return cls(groups=tuple(groups), parents=parents, pack_desks=desks)

    def chain(self, region: str) -> tuple[str, ...]:
        """Root-first pack chain for a region: manifest parents when known, else the id's dash prefixes."""
        if region in self.parents:
            out: list[str] = []
            cur: str | None = region
            while cur is not None and cur not in out and len(out) < 8:
                out.append(cur)
                cur = self.parents.get(cur)
            return tuple(reversed(out))
        parts = region.split("-")
        return tuple("-".join(parts[: i + 1]) for i in range(len(parts)))

    def groups_for(self, chain: Iterable[str]) -> list[FeeGroup]:
        packs = list(chain)
        return [g for g in self.groups if g.pack_id in packs]

    def desks_for(self, chain: Iterable[str]) -> list[str]:
        """Manifest desk ids, most local pack first."""
        return [d for pack in reversed(list(chain)) for d in self.pack_desks.get(pack, ())]


def _group(pack: str, adapter: Any) -> FeeGroup | None:
    if not isinstance(adapter, dict):
        return None
    aid = adapter.get("id")
    if not isinstance(aid, str) or FEE_ADAPTER_MARK not in aid:
        return None
    answers = [a for a in adapter.get("answers") or [] if isinstance(a, str)]
    facts = [f for f in adapter.get("facts") or [] if isinstance(f, dict) and isinstance(f.get("id"), str)]
    if not answers or not facts:
        return None
    desk = adapter.get("desk") if isinstance(adapter.get("desk"), str) else None
    return FeeGroup(
        key=answers[0],
        adapter_id=aid,
        pack_id=pack,
        desk_id=desk,
        fact_ids=tuple(f["id"] for f in facts),
        fact_topics={f["id"]: tuple(t for t in f.get("topics") or [] if isinstance(t, str)) for f in facts},
    )
