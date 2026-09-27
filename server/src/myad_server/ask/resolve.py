"""Pure intent resolution for the phase-1c-i /v1/ask endpoint."""
from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from datetime import datetime, timezone

from ..cards import BundleCard, CardBundle
from ..intent import ANavigate, AskRequest, Clarification, ClarifyOption, DCard, DDesk, GCard, GDesk, IntentResolution
from ..ledger import Ledger
from ..values import FactRef, Mode, StringKey
from ..verifier import grounding_facts
from ..visibility import card_visible
from .calibrate import ACT
from .desk_only import DeskOnlyRule
from .desks import DeskScope
from .language import reply_language
from .policy import AskPolicy, load_policy
from .ranker import Ranker, StubRanker
from .retrieval import Candidate, IntentIndex, normalize

CARDS_TABLE = "Cards"
ROUTER_TABLE = "ADRouter"
CLIENT_TABLE = "ADAgentsClient"
NO_ANSWER = StringKey(key="router.no_answer", table=ROUTER_TABLE)
CLARIFY_QUESTION = StringKey(key="router.clarify.which_card", table=ROUTER_TABLE)
CLOSE_MARGIN = 0.12
CLOSE_FLOOR = 0.35
# An ambiguous desk-only domain word (e.g. "clinic" with no price cue) reaches a card only when a card about
# that same domain matches at least this well (the phone's act threshold). Anything weaker fails closed.
AMBIGUOUS_CARD_FLOOR = ACT


def _card_map(cards: CardBundle | Mapping[str, BundleCard] | Iterable[BundleCard]) -> dict[str, BundleCard]:
    if isinstance(cards, CardBundle):
        return dict(cards.cards)
    if isinstance(cards, Mapping):
        return dict(cards)
    return {card.id: card for card in cards}


def _reply_language(request: AskRequest) -> str:
    return reply_language(request.utterance.language)


def _utterances(card: BundleCard) -> list[str]:
    return [*card.utterances.es, *card.utterances.en, *card.utterances.ht]


def _ground(card: BundleCard, ledger: Ledger) -> list[FactRef]:
    # /ask has no pin and no adapter call. Lookup refs are still valid grounding
    # references; the phone supplies values from its household-week context.
    return grounding_facts(card, ledger, datetime.now(timezone.utc))


def _action(card: BundleCard, request: AskRequest) -> ANavigate:
    person_id = request.utterance.context.person_id if card.scope != "household" else None
    return ANavigate(destination=DCard(card_id=card.id, person_id=person_id))


def _desk_resolution(request: AskRequest, desk: str, reason: StringKey, confidence: float, *, navigate: bool) -> IntentResolution:
    action = ANavigate(destination=DDesk(desk_id=desk)) if navigate else None
    return IntentResolution(
        action=action,
        grounding=GDesk(desk_id=desk, reason=reason),
        confidence=round(max(0.0, min(1.0, confidence)), 3),
        clarification=None,
        reply_language=_reply_language(request),
    )


def _no_answer(request: AskRequest, scope: DeskScope, confidence: float, desk: str | None = None) -> IntentResolution:
    """The 'I don't have this' shape without a desk-only reason: name the closest allowed desk, no action."""
    desk = scope.card_desk(desk) if desk else scope.generic()
    if desk:
        return _desk_resolution(request, desk, NO_ANSWER, confidence, navigate=False)
    return IntentResolution(confidence=round(max(0.0, min(1.0, confidence)), 3), reply_language=_reply_language(request))


def _clarification(candidates: list[Candidate], cards: dict[str, BundleCard], grounded: dict[str, list[FactRef]], request: AskRequest) -> Clarification | None:
    if len(candidates) < 2:
        return None
    top = candidates[0]
    close = [c for c in candidates if top.q - c.q <= CLOSE_MARGIN and c.q >= CLOSE_FLOOR]
    close = close[:3]
    close = [c for c in close if c.card_id in grounded]
    if len(close) < 2:
        return None
    options = [
        ClarifyOption(
            id=f"card.{candidate.card_id}",
            label=StringKey(key=f"card.{candidate.card_id}.title", table=CARDS_TABLE),
            action=_action(cards[candidate.card_id], request),
        )
        for candidate in close
    ]
    return Clarification(question=CLARIFY_QUESTION, options=options)


def resolve_intent(
    request: AskRequest,
    cards,
    ledger: Ledger,
    ranker: Ranker | None = None,
    policy: AskPolicy | None = None,
    jurisdiction: Sequence[str] | None = None,
) -> IntentResolution:
    """Resolve one request using retrieval, deterministic ranking, and grounding.

    This function has no model, network, adapter, persistence, or prose path.
    Confidence is reported, never interpreted as a server policy threshold.

    Desk-only questions (visa outcome, clinic price, jobs, appointment slots, school-bus eligibility) are
    decided by the structural classifier in ``desk_only.py`` BEFORE any card can ground, and a card whose own
    utterances are desk-only questions never grounds either. ``jurisdiction`` is the household's resolved
    Regions pack chain when the caller knows it; /v1/ask carries no pin, so it is normally None and the
    generic desk is the county's.
    """
    card_map = _card_map(cards)
    index = IntentIndex(card_map.values())
    policy = policy or load_policy()
    scope = DeskScope(policy, ledger, jurisdiction)
    ranker = ranker or StubRanker()
    normalized = normalize(request.utterance.text)
    allowed = {
        card.id for card in card_map.values()
        if card_visible(card, request.mode, policy.immigration_topics)
    }
    desk_only_cards = {cid: rule for cid in allowed
                       if (rule := policy.card_desk_only(_utterances(card_map[cid]))) is not None}

    def relevant(cid: str, rule: DeskOnlyRule) -> bool:
        """A card may lend its desk to a desk-only handoff only if it is about that desk-only question."""
        c = card_map[cid]
        return (desk_only_cards.get(cid) == rule or bool(set(rule.topics) & set(c.topics))
                or policy.in_domain(rule, _utterances(c)))

    def desk_only(rule: DeskOnlyRule, card: BundleCard | None = None) -> IntentResolution:
        # Visibility is evaluated first. Tourist mode must not turn an immigration question into a visible
        # visa handoff, even when a matching card exists: only the generic no-answer path.
        if request.mode == Mode.tourist and rule.immigration:
            return _no_answer(request, scope, 0.0)
        if card is None or not relevant(card.id, rule):
            pool = {cid for cid in allowed if relevant(cid, rule)}
            found = index.search(normalized, stage=None, allowed=pool) if pool else []
            chosen = ranker.rank(found, request.utterance.text) if found else None
            card = card_map.get(chosen.card_id) if isinstance(chosen, Candidate) else None
        # No related card: the jurisdiction's generic desk, never an unrelated card's desk.
        desk = scope.card_desk(card.desk if card is not None else None)
        if desk is None:
            return IntentResolution(confidence=0.0, reply_language=_reply_language(request))
        return _desk_resolution(request, desk, StringKey(key=f"ask.reason.desk_only.{rule.id}", table=CLIENT_TABLE),
                                1.0, navigate=True)

    hit = policy.classify(request.utterance.text)
    if hit is not None and hit.hard:
        return desk_only(hit.rule)

    candidates = index.search(normalized, stage=request.stage, allowed=allowed)
    if not candidates:
        # Fail closed: an ambiguous desk-only domain with no card at all still goes to the desk.
        return desk_only(hit.rule) if hit is not None else _no_answer(request, scope, 0.0)

    chosen = ranker.rank(candidates, request.utterance.text)
    if not isinstance(chosen, Candidate) or chosen.card_id not in card_map:
        chosen = candidates[0]
    card = card_map[chosen.card_id]

    # Second line of defence: a card that is itself a desk-only question never grounds an answer.
    if card.id in desk_only_cards:
        return desk_only(desk_only_cards[card.id], card)
    # Fail closed on an ambiguous overlap: the domain word without its question cue reaches a card only when
    # that card is about the same domain and matches confidently.
    if hit is not None and not (chosen.q >= AMBIGUOUS_CARD_FLOOR and policy.in_domain(hit.rule, _utterances(card))):
        return desk_only(hit.rule, card)

    grounded = {candidate.card_id: _ground(card_map[candidate.card_id], ledger) for candidate in candidates
                if candidate.card_id in card_map and candidate.card_id not in desk_only_cards}
    facts = grounded.get(card.id, [])
    if not facts:
        return _no_answer(request, scope, chosen.q, card.desk)

    clarification = _clarification(candidates, card_map, grounded, request)
    if clarification is not None:
        return IntentResolution(action=None, grounding=None, confidence=round(chosen.q, 3), clarification=clarification, reply_language=_reply_language(request))
    return IntentResolution(action=_action(card, request), grounding=GCard(card_id=card.id, facts=facts), confidence=round(chosen.q, 3), clarification=None, reply_language=_reply_language(request))
