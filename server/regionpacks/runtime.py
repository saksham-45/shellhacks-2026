"""Entry point for myAD Agents (in-process, read-only import). Owner: myAD Regions.

    from runtime import resolve, answer            # with server/regionpacks on sys.path
    resolve({"address": "...", "lat": 25.66, "lon": -80.41}) -> ["us", "us-fl", "us-fl-miamidade"]
    answer(pin, fact_ids=None, topics=None, timeout_s=20.0) -> [result dict, ...]   (CONTRACT.md §2)

Both are safe to call from parallel workers: module state is only the read-only manifests, source registry,
adapter instances and fixture index (loaded once). Each call builds its own Deadline, transport and executor.
`timeout_s` caps the whole call and is clamped to at most 20 s. Neither function raises for source problems:
unreachable or timed-out sources come back as `unavailable`, bad responses as `error`, both with the manifest
desk. Nothing here logs addresses, coordinates, or bodies.
"""
from __future__ import annotations

import sys
from concurrent.futures import ThreadPoolExecutor, wait
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from myad_regions.adapters import Adapter, Ctx, adapter  # noqa: E402
from myad_regions.geocode import GeocodeFailed, resolve_point  # noqa: E402
from myad_regions.manifests import PACK_ORDER, AdapterDecl, all_adapters, manifest, manifests, sources  # noqa: E402
from myad_regions.pins import demo_pin_id  # noqa: E402
from myad_regions.transport import MAX_TIMEOUT_S, Deadline, Transport, default_transport  # noqa: E402
from myad_regions.types import FactResult, PinInput, ResolvedPin, now_iso  # noqa: E402

__all__ = ["resolve", "answer", "answer_question", "MAX_TIMEOUT_S"]
BOUNDARY_ADAPTER = "us-fl-miamidade.municipality"
_WORKERS = 8


def _clamp(timeout_s: float) -> float:
    try:
        return max(0.0, min(float(timeout_s), MAX_TIMEOUT_S))
    except (TypeError, ValueError):
        return MAX_TIMEOUT_S


def _run(a: Adapter, ctx: Ctx, transport: Transport, deadline: Deadline) -> list[FactResult]:
    try:
        return a.run(ctx, transport, deadline)
    except Exception as e:  # never raise to the caller; the message carries no pin data
        return _failed(a.decl, ctx.pin.method if ctx.pin else None, "error", f"internal adapter error ({type(e).__name__})")


def _failed(decl: AdapterDecl, pin_method: str | None, status: str, message: str) -> list[FactResult]:
    """Results for an adapter that could not run. The url is the source's registry URL (no pin in it)."""
    src = sources()[decl.sources[0]] if decl.sources else None
    out = []
    for fid in decl.fact_ids:
        r = FactResult(fact_id=fid, pack=decl.pack, status=status if src else "unsourced", jurisdiction=decl.pack,
                       desk=decl.desk, source_id=src.id if src else None, publisher=src.publisher if src else None,
                       url=src.url if src else None, retrieved_at=now_iso() if src else None,
                       check_every=src.check_every if src else None, error=message if src else None,
                       basis={"method": pin_method} if pin_method else None)
        out.append(r)
    return out


def _chain(pin: ResolvedPin, transport: Transport, deadline: Deadline) -> tuple[tuple[str, ...], list[FactResult]]:
    """Pack membership from each manifest's boundary (the phone does no point-in-polygon)."""
    boundary = _run(adapter(BOUNDARY_ADAPTER), Ctx(pin, ()), transport, deadline)
    by_id = {r.fact_id: r for r in boundary}
    member: dict[str, bool] = {}
    for m in manifests():
        b = m.boundary
        r = by_id.get(b.fact or "")
        if b.method == "always":
            member[m.id] = True
        elif b.method == "fact_ok":
            member[m.id] = bool(r and r.status == "ok")
        elif b.method == "fact_equals":
            member[m.id] = bool(r and r.status == "ok" and (r.value or {}).get("code") == b.value)
        else:
            member[m.id] = False
    for m in reversed(manifests()):  # any_child: inside a member child means inside the parent
        if m.boundary.method == "any_child":
            member[m.id] = any(member.get(c.id) for c in manifests() if c.parent == m.id)
    chain = tuple(m.id for m in manifests() if member[m.id])
    return chain, boundary


def _wanted(decl: AdapterDecl, fact_ids, topics) -> bool:
    if fact_ids is None and topics is None:
        return True
    return any((fact_ids is not None and f.id in fact_ids) or (topics is not None and set(f.topics) & set(topics))
               for f in decl.facts)


def _keep(r: FactResult, decls: dict[str, AdapterDecl], fact_ids, topics) -> bool:
    if fact_ids is None and topics is None:
        return True
    if fact_ids is not None and r.fact_id in fact_ids:
        return True
    if topics is not None:
        for d in decls.values():
            for f in d.facts:
                if f.id == r.fact_id and set(f.topics) & set(topics):
                    return True
    return False


def _stamp(results: list[FactResult], live: bool, pin_suffix: str) -> list[dict]:
    out = []
    for r in results:
        static = (r.basis or {}).get("lookup") == "ledger"  # Research's own row, the same in every mode
        r.is_demo = not live and not static
        r.ledger_id = r.fact_id if live or static else f"{r.fact_id}.demo.{pin_suffix}"
        out.append(r.to_json())
    return out


def resolve(pin: PinInput | dict, timeout_s: float = MAX_TIMEOUT_S, transport: Transport | None = None) -> list[str]:
    """Pack ids that contain the pin, country first. ["us"] when the county layer cannot be read."""
    deadline, transport = Deadline(_clamp(timeout_s)), transport or default_transport()
    try:
        rp = resolve_point(PinInput.of(pin), transport, deadline)
    except GeocodeFailed:
        return ["us"]
    return list(_chain(rp, transport, deadline)[0])


def answer(pin: PinInput | dict, fact_ids: list[str] | None = None, topics: list[str] | None = None,
           timeout_s: float = MAX_TIMEOUT_S, transport: Transport | None = None) -> list[dict]:
    """Results for every declared fact of the pin's packs, narrowed by fact_ids and/or topics.

    Facts of packs that do not contain the pin never appear (a City of Miami fact never answers an
    unincorporated pin). Order is stable: manifest order."""
    return _answer(pin, fact_ids, topics, timeout_s, transport)[1]


def _answer(pin, fact_ids, topics, timeout_s, transport) -> tuple[tuple[str, ...], list[dict]]:
    deadline, transport = Deadline(_clamp(timeout_s)), transport or default_transport()
    fid_set = set(fact_ids) if fact_ids is not None else None
    top_set = set(topics) if topics is not None else None
    p = PinInput.of(pin)
    try:
        rp = resolve_point(p, transport, deadline)
    except GeocodeFailed as e:
        status = "unavailable" if e.unreachable else "error"
        failed = [r for d in all_adapters() if d.pack != "us-fl-miami" and _wanted(d, fid_set, top_set)
                  for r in _failed(d, None, status, str(e))]
        decls = {d.id: d for d in all_adapters()}
        return ("us",), _stamp([r for r in failed if _keep(r, decls, fid_set, top_set)], transport.live, "pin-unresolved")

    suffix = demo_pin_id(rp.lat, rp.lon) or "pin-unmatched"
    chain, boundary = _chain(rp, transport, deadline)
    county_failed = "us-fl-miamidade" not in chain and any(r.status in ("unavailable", "error") for r in boundary)
    ctx = Ctx(rp, chain)
    decls = [d for d in all_adapters() if d.pack in chain and _wanted(d, fid_set, top_set)]
    if county_failed:  # membership unknown: county facts are unavailable, city facts are not claimed
        decls += [d for d in manifest("us-fl-miamidade").adapters if _wanted(d, fid_set, top_set)]
    by_adapter: dict[str, list[FactResult]] = {}
    if BOUNDARY_ADAPTER in {d.id for d in decls} and not county_failed:
        by_adapter[BOUNDARY_ADAPTER] = boundary
    todo = [d for d in decls if d.id not in by_adapter]
    if county_failed:
        err = next(r for r in boundary if r.status in ("unavailable", "error"))
        for d in todo:
            by_adapter[d.id] = _failed(d, rp.method, err.status, f"pack membership unknown: {err.error}")
        todo = []
    if todo:
        pool = ThreadPoolExecutor(max_workers=min(_WORKERS, len(todo)))
        try:
            futures = {d.id: pool.submit(_run, adapter(d.id), ctx, transport, deadline) for d in todo}
            wait(futures.values(), timeout=deadline.remaining() + 1.0)
            for d in todo:
                f = futures[d.id]
                by_adapter[d.id] = f.result() if f.done() else _failed(d, rp.method, "unavailable", "timed out")
        finally:
            pool.shutdown(wait=False, cancel_futures=True)
    all_decls = {d.id: d for d in decls}
    ordered = [r for d in all_adapters() if d.id in by_adapter for r in by_adapter[d.id]
               if _keep(r, all_decls, fid_set, top_set)]
    return chain, _stamp(ordered, transport.live, suffix)


def answer_question(pin: PinInput | dict, question: str, timeout_s: float = MAX_TIMEOUT_S,
                    transport: Transport | None = None) -> dict:
    """Most local pack that declares the question wins. A pack whose answers are all not_applicable passes to
    its parent (e.g. county trash inside the City of Miami); error/unavailable/unsourced stops there and hands
    over that pack's desk, never silently falling back."""
    chain, results = _answer(pin, None, None, timeout_s, transport)
    # When membership is unknown (county layer or geocoder down), _answer returns failed results for packs
    # outside the resolved chain. Walk those packs too so their desk still reaches the caller.
    failed_packs = {r["pack"] for r in results if r["status"] in ("unavailable", "error") and r["pack"] not in chain}
    walk = tuple(pk for pk in PACK_ORDER if pk in chain or pk in failed_packs)
    unknown = bool(failed_packs)
    passed: list[str] = []
    for pk in reversed(walk):
        ids = {f.id for d in manifest(pk).adapters if question in d.answers for f in d.facts}
        mine = [r for r in results if r["fact_id"] in ids]
        if not mine:
            continue
        if all(r["status"] == "not_applicable" for r in mine):
            passed.append(pk)
            continue
        return {"question": question, "owner": pk, "results": mine, "passed_over": passed,
                "membership_unknown": unknown}
    return {"question": question, "owner": None, "results": [], "passed_over": passed, "membership_unknown": unknown}
