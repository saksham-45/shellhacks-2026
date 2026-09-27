"""Typed household-week flow.

This module deliberately has no presentation model or address persistence.  Cards select the
questions, Regions supplies request-scoped evidence, and the existing pure verifier is the only
way a claim reaches the wire.
"""
from __future__ import annotations

import re
import uuid
from collections.abc import Iterable
from datetime import datetime, timezone
from typing import Any

from ..adapter import AdapterResult, parse_results
from ..cards import BundleCard, CardBundle
from ..ledger import Ledger
from ..models import (
    FactRef,
    FactOutcome,
    HouseholdWeekRequest,
    HouseholdWeekResponse,
    ODeferred,
    ONotApplicable,
    OUnavailable,
    OUnsourced,
    StringKey,
    WeekItem,
)
from ..regions import RegionsRuntime
from ..verifier import DraftClaim, VerifyContext, Verdict, verify
from ..values import Mode
from ..visibility import fact_visible, is_immigration_card
from . import membership

# Regions clamps this value too; keeping the cap here protects a replacement runtime.
_TIMEOUT_S = 20.0
_DEMO_PIN = re.compile(r"\.demo\.(pin-[a-z0-9-]+)$")


def _request_id(req: HouseholdWeekRequest) -> str:
    return req.request_id or uuid.uuid4().hex


def _cards(bundle: CardBundle, mode: Mode) -> list[BundleCard]:
    """Stable household card selection, independent of dict insertion order."""
    out = []
    for card in sorted(bundle.cards.values(), key=lambda c: c.id):
        if card.scope != "household" or mode.value not in card.modes or not card.fact_refs:
            continue
        if mode == Mode.tourist and is_immigration_card(card):
            continue
        out.append(card)
    return out


def _query(cards: Iterable[BundleCard]) -> tuple[list[str], list[str]]:
    # Preserve each card's reviewed fact order, while making the set operation stable.
    fact_ids: list[str] = []
    topics: set[str] = set()
    for card in cards:
        for fact_id in card.fact_refs:
            if fact_id not in fact_ids:
                fact_ids.append(fact_id)
        topics.update(card.topics)
    return fact_ids, sorted(topics)


def _pin(req: HouseholdWeekRequest) -> dict[str, Any]:
    # Do not pass the Pydantic object to a third party: this is the only request-scoped pin copy.
    return {"address": req.pin.address, "lat": req.pin.lat, "lon": req.pin.lon}


def _pin_slug(results: Iterable[AdapterResult]) -> str | None:
    for result in results:
        match = _DEMO_PIN.search(result.effective_ledger_id)
        if match:
            return match.group(1)
    return None


def _desk_for(fact_id: str, ledger: Ledger, cards_by_fact: dict[str, BundleCard]) -> str | None:
    fact = ledger.get(fact_id) or ledger.lookup_for(fact_id)
    if fact and fact.raw.desk:
        return fact.raw.desk
    card = cards_by_fact.get(fact_id)
    return card.desk if card else None


def _fallback_results(fact_ids: Iterable[str], ledger: Ledger, cards_by_fact: dict[str, BundleCard]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for fact_id in fact_ids:
        fact = ledger.get(fact_id) or ledger.lookup_for(fact_id)
        if fact is None or not fact.is_lookup:
            continue
        rows.append({
            "fact_id": fact_id,
            "ledger_id": fact_id,
            "pack_id": fact.pack_id,
            "status": "unavailable",
            "desk": _desk_for(fact_id, ledger, cards_by_fact),
            "jurisdiction": fact.raw.jurisdiction,
        })
    return rows


def _non_ok_outcome(result: AdapterResult, ledger: Ledger, cards_by_fact: dict[str, BundleCard]) -> FactOutcome | None:
    desk = result.desk or _desk_for(result.fact_id, ledger, cards_by_fact)
    if not desk:
        return None
    if result.status in ("unavailable", "error"):
        return OUnavailable(fact_id=result.fact_id, desk_id=desk)
    if result.status == "unsourced":
        return OUnsourced(fact_id=result.fact_id, desk_id=desk)
    if result.status == "not_applicable":
        na = result.not_applicable
        reason = StringKey(key=(na.reason if na else "not_applicable"), table="ADCityPack")
        if na and na.defer_to:
            try:
                return ODeferred(fact_id=result.fact_id, reason=reason, defer_to=FactRef(
                    pack_id=na.defer_to.pack_id, fact_id=na.defer_to.fact_id), desk_id=desk)
            except ValueError:
                pass
        return ONotApplicable(fact_id=result.fact_id, reason=reason, desk_id=desk)
    return None


def _response(
    req: HouseholdWeekRequest,
    cards: list[BundleCard],
    ledger: Ledger,
    results: list[AdapterResult],
    verdict: Verdict,
    *,
    chain: tuple[str, ...],
    malformed_count: int = 0,
) -> HouseholdWeekResponse:
    cards_by_fact = {fact_id: card for card in cards for fact_id in card.fact_refs}
    facts = dict(verdict.facts)
    # Preserve explicit adapter non-ok outcomes even where no selected claim cited that result, but only
    # for facts a selected card asked for, and never a fact this mode may not show.
    for result in results:
        if result.fact_id not in facts and _requested(result.fact_id, ledger, cards_by_fact) \
                and fact_visible(_ledger_fact(ledger, result.fact_id), req.mode):
            outcome = _non_ok_outcome(result, ledger, cards_by_fact)
            if outcome is not None:
                facts[result.fact_id] = outcome
    items: list[WeekItem] = []
    claim_indexes = {index: claim for index, claim in verdict.claims}
    for index, card in enumerate(cards):
        claim = claim_indexes.get(index)
        if claim is not None:
            items.append(WeekItem(card_id=card.id, date=None, claims=[claim]))
    return HouseholdWeekResponse(
        request_id=_request_id(req),
        language=req.surface_language.value,
        facts=facts,
        handoffs=verdict.handoffs,
        has_demo=verdict.has_demo,
        dropped_claims=verdict.dropped_claims + malformed_count,
        pack_ids=list(chain),
        items=items,
    )


def _ledger_fact(ledger: Ledger, fact_id: str):
    return ledger.get(fact_id) or ledger.lookup_for(fact_id)


def _requested(fact_id: str, ledger: Ledger, cards_by_fact: dict[str, BundleCard]) -> bool:
    """A fact a selected card asked for, directly or as a ranked result (`<lookup>.1`) of its lookup."""
    if fact_id in cards_by_fact:
        return True
    base = ledger.lookup_for(fact_id)
    return base is not None and base.id in cards_by_fact


async def run(
    req: HouseholdWeekRequest,
    *,
    bundle: CardBundle,
    ledger: Ledger,
    runtime: RegionsRuntime | None,
    now: datetime | None = None,
) -> HouseholdWeekResponse:
    """Run one stateless household request.  Runtime failures become desk outcomes."""
    cards = _cards(bundle, req.mode)
    fact_ids, topics = _query(cards)
    cards_by_fact = {fact_id: card for card in cards for fact_id in card.fact_refs}
    rows: list[Any] = []
    resolved_packs: tuple[str, ...] | None = None
    runtime_resolved = False
    if runtime is not None:
        try:
            rows, resolved_packs = await membership.call_runtime(
                runtime, _pin(req), membership.runtime_fact_ids(fact_ids), topics, _TIMEOUT_S)
            runtime_resolved = True
        except Exception:  # runtime boundary must never crash HTTP
            rows = _fallback_results(fact_ids, ledger, cards_by_fact)
    else:
        rows = _fallback_results(fact_ids, ledger, cards_by_fact)

    unknown = runtime_resolved and membership.membership_unknown(rows)
    rows = membership.normalize_membership(rows, unknown)
    # A malformed row is dropped and counted here; it never reaches a FactRef or a WireFact (M2).
    parsed, bad = parse_results(rows)
    if req.pin.lat is not None and req.pin.lon is not None:
        parsed = [
            result.model_copy(update={"basis": result.basis or {"method": "device_coords"}})
            for result in parsed
        ]
    chain = membership.chain(rows, runtime_resolved=runtime_resolved, unknown=unknown,
                             resolved_packs=resolved_packs)
    current = now or datetime.now(timezone.utc)
    drafts = [
        DraftClaim(
            card_id=card.id,
            copy_key=StringKey(key=f"card.{card.id}.summary", table="Cards"),
            fact_refs=[FactRef.of(fid) for fid in card.fact_refs],
            desk_id=card.desk,
            question=card.id,
            immigration=is_immigration_card(card),
        )
        for card in cards
    ]
    planned = tuple(card.id for card in cards)
    question_facts = {card.id: card.fact_refs[0] for card in cards if card.fact_refs}
    question_desks = {card.id: card.desk for card in cards}
    verify_context = VerifyContext(
        ledger=ledger,
        results=tuple(parsed),
        chain=chain,
        mode=req.mode,
        now=current,
        pin_slug=_pin_slug(parsed),
        planned_questions=planned,
        question_facts=question_facts,
        question_desks=question_desks,
        default_desk=cards[0].desk if cards else None,
        default_desks=membership.default_desks(parsed, chain),
        cards={card.id: card for card in cards},
        local_membership_known=runtime_resolved and not unknown,
    )
    verdict = verify(drafts, verify_context)

    # The response also exposes request-scoped evidence that no card happened to use.  Admit it
    # through the same pure verifier, but do not turn evidence into a client claim or a dropped
    # claim count.  Evidence is limited to fact ids a selected card asked for (never the boundary
    # fact or anything else Regions volunteered), and goes through the shared visibility policy, so
    # tourist mode never shows an immigration-topic fact (M6).
    evidence_drafts = [
        DraftClaim(
            card_id="__evidence__",
            copy_key=StringKey(key="evidence", table="ADAgentsClient"),
            fact_refs=[FactRef.of(result.fact_id)],
        )
        for result in parsed
        if result.status == "ok" and _requested(result.fact_id, ledger, cards_by_fact)
        and result.fact_id not in verdict.facts and fact_visible(_ledger_fact(ledger, result.fact_id), req.mode)
    ]
    if evidence_drafts:
        evidence_verdict = verify(evidence_drafts, verify_context)
        for fact_id, outcome in evidence_verdict.facts.items():
            verdict.facts.setdefault(fact_id, outcome)
    return _response(req, cards, ledger, parsed, verdict, chain=chain, malformed_count=len(bad))


# Descriptive alias for callers that use the flow name rather than the generic runner.
household_week = run
