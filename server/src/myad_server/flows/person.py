"""Deterministic, privacy-scoped person next-steps flow.

The request contains one person only.  Cards choose reviewed copy and fact ids; the
verifier is the only component allowed to admit facts or desk contact information.
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
    NextStep,
    OUnavailable,
    PersonNextStepsRequest,
    PersonNextStepsResponse,
    StringKey,
    Handoff,
    OFact,
)
from ..regions import RegionsRuntime
from ..verifier import DraftClaim, VerifyContext, Verdict, desk_only_kind_for_topics, verify
from ..values import Mode
from ..visibility import is_immigration_card
from . import membership

_TIMEOUT_S = 20.0
_DEMO_PIN = re.compile(r"\.demo\.(pin-[a-z0-9-]+)$")

# The compiled card contract does not carry a separate goal/status field.  These
# vocabularies are consequently only ranking hints derived from reviewed card ids
# and topics; generic person cards remain eligible when no goal-specific card exists.
_GOAL_TERMS: dict[str, frozenset[str]] = {
    "arrive": frozenset({"arrive", "arrival", "mail", "language", "housing", "rent", "papers"}),
    "study": frozenset({"study", "school", "student", "education", "college", "dso"}),
    "work": frozenset({"work", "job", "jobs", "employment", "career", "permit", "wage"}),
    "reunite": frozenset({"reunite", "family", "relative", "child", "spouse"}),
    "visit": frozenset({"visit", "tourist", "airport", "travel"}),
    "getThroughWeek": frozenset({"week", "health", "clinic", "emergency", "language", "food"}),
}
_STATUS_TERMS = frozenset({"status", "status-word", "status_word", "immigration-status"})
def _request_id(req: PersonNextStepsRequest) -> str:
    return req.request_id or uuid.uuid4().hex


def _terms(card: BundleCard) -> set[str]:
    text = " ".join((card.id, *card.topics)).casefold()
    return {part for part in re.split(r"[^a-z0-9_-]+", text) if part}


def _status_card(card: BundleCard) -> bool:
    terms = _terms(card)
    return bool(terms & _STATUS_TERMS) or "status" in card.id.casefold()


def _goal_score(card: BundleCard, goal: str) -> int:
    return len(_terms(card) & _GOAL_TERMS.get(goal, frozenset()))


def _desk_only_kind(card: BundleCard) -> str | None:
    # One source of truth with the verifier: research topic ids mapped in the ask policy (REVIEW B1).
    return desk_only_kind_for_topics(card.topics)


def _cards(bundle: CardBundle, req: PersonNextStepsRequest) -> list[BundleCard]:
    person = req.person
    candidates: list[BundleCard] = []
    for card in bundle.cards.values():
        if card.scope not in ("person", "person-papers"):
            continue
        if person.stage not in card.stages or person.mode.value not in card.modes:
            continue
        if person.mode == Mode.tourist and is_immigration_card(card):
            continue
        # A status-specific card cannot be selected unless the person supplied the
        # optional status word.  The word itself is never used as a fact or logged.
        if _status_card(card) and not person.status_word:
            continue
        candidates.append(card)

    # If the bundle offers goal-specific cards, cards for another goal are not
    # candidates at all. When the bundle has no goal metadata, generic person
    # cards remain eligible. Ranking and the three-card cap are deterministic.
    scored = [(card, _goal_score(card, person.goal)) for card in candidates]
    specific = [card for card, score in scored if score > 0]
    if specific:
        candidates = specific
    candidates.sort(
        key=lambda card: (
            -_goal_score(card, person.goal),
            -(1 if person.status_word and _status_card(card) else 0),
            card.id,
        )
    )
    return candidates[:3]


def _query(cards: Iterable[BundleCard]) -> tuple[list[str], list[str]]:
    fact_ids: list[str] = []
    topics: set[str] = set()
    for card in cards:
        for fact_id in card.fact_refs:
            if fact_id not in fact_ids:
                fact_ids.append(fact_id)
        topics.update(card.topics)
    return fact_ids, sorted(topics)


def _pin(req: PersonNextStepsRequest) -> dict[str, Any] | None:
    if req.pin is None:
        return None
    return {"address": req.pin.address, "lat": req.pin.lat, "lon": req.pin.lon}


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
            "desk": fact.raw.desk or (cards_by_fact.get(fact_id).desk if cards_by_fact.get(fact_id) else None),
            "jurisdiction": fact.raw.jurisdiction,
        })
    return rows


def _pin_slug(results: Iterable[AdapterResult]) -> str | None:
    for result in results:
        match = _DEMO_PIN.search(result.effective_ledger_id)
        if match:
            return match.group(1)
    return None


def _origin_cards(bundle: CardBundle, req: PersonNextStepsRequest) -> list[BundleCard]:
    lenses = [lens for lens in req.person.origin_lenses if lens != "questionnaire"]
    if not lenses:
        return []
    out: list[BundleCard] = []
    for card in bundle.cards.values():
        if card.scope not in ("person", "person-papers") or not card.fact_refs:
            continue
        card_id = card.id.casefold()
        if any(lens.casefold() in card_id for lens in lenses):
            if req.person.mode.value in card.modes and not (req.person.mode == Mode.tourist and is_immigration_card(card)):
                out.append(card)
    return sorted(out, key=lambda card: card.id)


def _merge_handoffs(*verdicts: Verdict) -> list[Handoff]:
    out: list[Handoff] = []
    for verdict in verdicts:
        for handoff in verdict.handoffs:
            if not any(existing.desk_id == handoff.desk_id for existing in out):
                out.append(handoff)
    return out


def _merge_facts(*verdicts: Verdict) -> dict[str, FactOutcome]:
    facts: dict[str, FactOutcome] = {}
    for verdict in verdicts:
        facts.update({key: value for key, value in verdict.facts.items() if key not in facts})
    return facts


def _missing_origin_outcomes(cards: Iterable[BundleCard], ledger: Ledger) -> dict[str, FactOutcome]:
    """Represent an absent origin ledger fact as unavailable, never as prose."""
    out: dict[str, FactOutcome] = {}
    for card in cards:
        for fact_id in card.fact_refs:
            if ledger.get(fact_id) is None and ledger.lookup_for(fact_id) is None:
                out[fact_id] = OUnavailable(fact_id=fact_id, desk_id=card.desk)
    return out


async def run(
    req: PersonNextStepsRequest,
    *,
    bundle: CardBundle,
    ledger: Ledger,
    runtime: RegionsRuntime | None,
    now: datetime | None = None,
) -> PersonNextStepsResponse:
    """Run one stateless request for exactly one person."""
    cards = _cards(bundle, req)
    origin_cards = _origin_cards(bundle, req)
    all_cards = cards + [card for card in origin_cards if card.id not in {c.id for c in cards}]
    fact_ids, topics = _query(all_cards)
    cards_by_fact = {fact_id: card for card in all_cards for fact_id in card.fact_refs}

    rows: list[Any] = []
    resolved_packs: tuple[str, ...] | None = None
    runtime_resolved = False
    pin = _pin(req)
    if pin is not None and runtime is not None and fact_ids:
        try:
            rows, resolved_packs = await membership.call_runtime(
                runtime, pin, membership.runtime_fact_ids(fact_ids), topics, _TIMEOUT_S)
            runtime_resolved = True
        except Exception:  # runtime boundary is a desk outcome, not an HTTP failure
            rows = _fallback_results(fact_ids, ledger, cards_by_fact)
    elif fact_ids:
        rows = _fallback_results(fact_ids, ledger, cards_by_fact)

    # Local membership needs a pin and a Regions answer; national and state facts need neither (B4).
    unknown = runtime_resolved and membership.membership_unknown(rows)
    rows = membership.normalize_membership(rows, unknown)
    parsed, malformed = parse_results(rows)
    chain = membership.chain(rows, runtime_resolved=runtime_resolved, unknown=unknown,
                             resolved_packs=resolved_packs)
    current = now or datetime.now(timezone.utc)
    cards_map = {card.id: card for card in all_cards}
    default_desk = cards[0].desk if cards else (origin_cards[0].desk if origin_cards else None)
    context = VerifyContext(
        ledger=ledger,
        results=tuple(parsed),
        chain=chain,
        mode=req.person.mode,
        now=current,
        pin_slug=_pin_slug(parsed),
        cards=cards_map,
        default_desk=default_desk,
        default_desks=membership.default_desks(parsed, chain),
        local_membership_known=runtime_resolved and not unknown,
    )

    step_drafts = [
        DraftClaim(
            card_id=card.id,
            copy_key=StringKey(key=f"card.{card.id}.summary", table="Cards"),
            fact_refs=[FactRef.of(fact_id) for fact_id in card.fact_refs],
            desk_id=card.desk,
            question=card.id,
            kind=_desk_only_kind(card),
            immigration=is_immigration_card(card),
        )
        for card in cards
        if card.fact_refs
    ]
    step_verdict = verify(step_drafts, context)

    origin_drafts = [
        DraftClaim(
            card_id=card.id,
            copy_key=StringKey(key=f"card.{card.id}.summary", table="Cards"),
            fact_refs=[FactRef.of(fact_id) for fact_id in card.fact_refs],
            desk_id=card.desk,
        )
        for card in origin_cards
    ]
    origin_verdict = verify(origin_drafts, context) if origin_drafts else Verdict()

    facts = _merge_facts(step_verdict, origin_verdict)
    facts.update({key: value for key, value in _missing_origin_outcomes(origin_cards, ledger).items() if key not in facts})
    handoffs = _merge_handoffs(step_verdict, origin_verdict)

    claims_by_index = {index: claim for index, claim in step_verdict.claims}
    steps: list[NextStep] = []
    draft_index = 0
    for card in cards:
        if not card.fact_refs:
            # Questionnaire/lens cards have no factual claim by design.
            if _desk_only_kind(card) is None:
                steps.append(NextStep(card_id=card.id, claims=[]))
            continue
        claim = claims_by_index.get(draft_index)
        draft_index += 1
        if claim is not None:
            steps.append(NextStep(card_id=card.id, claims=[claim]))

    response = PersonNextStepsResponse(
        request_id=_request_id(req),
        language=req.surface_language.value,
        facts=facts,
        handoffs=handoffs,
        has_demo=any(isinstance(outcome, OFact) and outcome.fact.is_demo for outcome in facts.values()),
        dropped_claims=len(step_verdict.dropped) + len(origin_verdict.dropped) + len(malformed),
        person_id=req.person.person_id,
        steps=steps[:3],
        origin_comparison=[claim for _, claim in origin_verdict.claims],
    )
    return response


person_next_steps = run
