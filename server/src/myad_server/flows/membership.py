"""Shared Regions boundary for the household and person flows: one runtime call, pack membership, and the
country-first pack chain the verifier uses for most-local-wins.

Rules (REVIEW r3 B3, B4, M3):
- National and state packs (`us`, `us-fl`) need no address: they are always in the chain.
- Local packs join the chain only from Regions evidence for this request (a result row's pack, or
  `resolve(pin)`), never from card text or ledger jurisdictions.
- Local membership is unknown when Regions says so explicitly (`membership_unknown`), when the pack
  boundary fact itself could not be read, or when the runtime could not be called.  One unavailable
  county layer is not a membership problem and never erases other answers.
"""
from __future__ import annotations

import asyncio
from collections.abc import Iterable
from typing import Any

from ..adapter import BOUNDARY_FACT_IDS, AdapterResult
from ..regions import RegionsRuntime
from ..values import PACK_ID

SEED_PACKS: tuple[str, ...] = ("us", "us-fl")
_ORDER = {"us": 0, "us-fl": 1, "us-fl-miamidade": 2, "us-fl-miami": 3}
_BOUNDARY_FAILED = ("unavailable", "error", "unsourced", "membership_unknown")


def is_local_pack(pack: str | None) -> bool:
    return bool(pack and pack.startswith("us-") and pack != "us-fl")


def runtime_fact_ids(card_fact_ids: Iterable[str]) -> list[str]:
    """Card fact ids plus the boundary fact, which is always asked for so its failure is visible."""
    out = list(card_fact_ids)
    out.extend(fid for fid in BOUNDARY_FACT_IDS if fid not in out)
    return out


def membership_unknown(raw_rows: Iterable[Any]) -> bool:
    for row in raw_rows:
        if not isinstance(row, dict):
            continue
        if bool(row.get("membership_unknown")) or row.get("status") == "membership_unknown":
            return True
        if row.get("fact_id") in BOUNDARY_FACT_IDS and row.get("status") in _BOUNDARY_FAILED:
            return True
    return False


def normalize_membership(rows: list[Any], unknown: bool) -> list[Any]:
    """Never let a local result through as an answer when membership is unknown."""
    if not unknown:
        return rows
    out: list[Any] = []
    for row in rows:
        if not isinstance(row, dict):
            out.append(row)
            continue
        copy = dict(row)
        pack = copy.get("pack_id", copy.get("pack"))
        if copy.get("status") == "membership_unknown" or is_local_pack(pack) or is_local_pack(
                str(copy.get("fact_id", "")).split(".", 1)[0]):
            copy["status"] = "unavailable"
            copy["value"] = None
            copy["not_applicable"] = None
            copy["ledger_id"] = copy.get("fact_id")
        out.append(copy)
    return out


async def call_runtime(runtime: RegionsRuntime, pin: dict[str, Any], fact_ids: list[str], topics: list[str],
                       timeout_s: float) -> tuple[list[Any], tuple[str, ...] | None]:
    """answer() (and resolve() when the runtime has it) in parallel worker threads, both capped.

    Raises whatever answer() raised or a timeout; the caller turns that into desk outcomes.  A failing
    resolve() is ignored: answer() rows are enough evidence on their own.
    """
    answer = asyncio.wait_for(
        asyncio.to_thread(runtime.answer, pin, fact_ids=fact_ids, topics=topics, timeout_s=timeout_s),
        timeout=timeout_s,
    )
    resolve_fn = getattr(runtime, "resolve", None)
    if not callable(resolve_fn):
        raw = await answer
        return (list(raw) if isinstance(raw, list) else []), None
    resolved = asyncio.wait_for(asyncio.to_thread(resolve_fn, pin), timeout=timeout_s)
    raw, packs = await asyncio.gather(answer, resolved, return_exceptions=True)
    if isinstance(raw, BaseException):
        raise raw
    if isinstance(packs, BaseException) or not isinstance(packs, list) \
            or not all(isinstance(p, str) for p in packs):
        packs = None
    return (list(raw) if isinstance(raw, list) else []), (tuple(packs) if packs is not None else None)


def row_packs(raw_rows: Iterable[Any]) -> list[str]:
    """Pack ids Regions answered for on this request, including rows later dropped as malformed.

    Regions only returns rows for packs that contain the pin, so a row is membership evidence even when
    its fact payload is unusable; the fact itself is still never admitted from a malformed row.
    """
    out: list[str] = []
    for row in raw_rows:
        if not isinstance(row, dict) or row.get("status") == "membership_unknown" or row.get("membership_unknown"):
            continue
        pack = row.get("pack_id", row.get("pack"))
        if isinstance(pack, str) and len(pack) <= 64 and PACK_ID.match(pack) and pack not in out:
            out.append(pack)
    return out


def chain(raw_rows: Iterable[Any], *, runtime_resolved: bool, unknown: bool,
          resolved_packs: Iterable[str] | None = None) -> tuple[str, ...]:
    """Country-first pack chain: seeds, plus local packs Regions placed the pin in (known membership only)."""
    present: list[str] = list(SEED_PACKS)
    if runtime_resolved and not unknown:
        for pack in [*(resolved_packs or ()), *row_packs(raw_rows)]:
            if pack and pack not in present:
                present.append(pack)
    return tuple(sorted(present, key=lambda pack: (_ORDER.get(pack, 100), present.index(pack))))


def default_desks(results: Iterable[AdapterResult], packs: tuple[str, ...]) -> dict[str, str]:
    """Each chain pack's desk as Regions reported it on this request (first row wins)."""
    out: dict[str, str] = {}
    for r in results:
        if r.desk and r.pack_id in packs and r.pack_id not in out:
            out[r.pack_id] = r.desk
    return out
