"""Pure steps of the /v1/ask flow. Nothing here writes text for a person: every output is typed ids,
StringKeys and numbers.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable

from ..cards import BundleCard, CardBundle
from ..intent import (
    ACallDesk,
    ANavigate,
    AOpenMap,
    AskRequest,
    Clarification,
    ClarifyOption,
    DCard,
    DDesk,
    GCard,
    GDesk,
    IntentResolution,
    MDesk,
)
from ..ledger import Ledger
from ..values import FactRef, StringKey
from ..verifier import grounding_facts
from ..visibility import card_visible
from .calibrate import ACT, CLARIFY, OPTION_FLOOR, calibrate
from .chooser import ChoiceOption, IntentChooser
from .language import reply_language
from .policy import AskPolicy, DeskOnlyRule
from .retrieval import Candidate, IntentIndex, normalize

MAX_ROUNDS = 3            # first choice + 2 retries after failed grounding
DESK_ONLY_CONFIDENCE = 0.9
CLIENT_TABLE = "ADAgentsClient"
CARDS_TABLE = "Cards"
# Keys Lead's golden files use (contracts/intent/intent_resolution.*.json), table "ADRouter".
CLARIFY_QUESTION = StringKey(key="router.clarify.which_card", table="ADRouter")
NO_ANSWER = StringKey(key="router.no_answer", table="ADRouter")


def client_key(key: str) -> StringKey:
    return StringKey(key=key, table=CLIENT_TABLE)


@dataclass(frozen=True)
class AskDeps:
    bundle: CardBundle
    index: IntentIndex
    ledger: Ledger
    policy: AskPolicy
    chooser: IntentChooser
    command_keys: frozenset[str]
    now: Callable[[], datetime]


@dataclass
class Prepared:
    normalized: str
    allowed: set[str]
    candidates: list[Candidate]
    desk_only: DeskOnlyRule | None
    counts: dict[str, int] = field(default_factory=dict)


def prepare(req: AskRequest, deps: AskDeps) -> Prepared:
    normalized = normalize(req.utterance.text)
    allowed = {c.id for c in deps.bundle.cards.values()
               if card_visible(c, req.mode, deps.policy.immigration_topics)}
    candidates = deps.index.search(normalized, stage=req.stage, allowed=allowed)
    hit = deps.policy.classify(req.utterance.text)
    rule = hit.rule if hit is not None and hit.hard else None
    if req.mode.value == "tourist" and rule is not None and rule.immigration:
        rule = None
    return Prepared(normalized, allowed, candidates, rule, {"candidates": len(candidates)})


def options_for(candidates: list[Candidate], bundle: CardBundle) -> list[ChoiceOption]:
    out = []
    for c in candidates:
        card = bundle.get(c.card_id)
        if card is None:
            continue
        title = card.title.get("en") or card.title.get("es") or card.id
        examples = tuple(u for _, u in card.all_utterances()[:3])
        out.append(ChoiceOption(c.card_id, title, examples))
    return out


def check_card(card_id: str | None, req: AskRequest, deps: AskDeps, allowed: set[str]) -> list[FactRef] | None:
    """Grounding verification for one card: it exists, is visible for the mode, and has >= 1 groundable
    ledger fact. None = fails (the flow retries without it)."""
    if card_id is None or card_id not in allowed:
        return None
    card = deps.bundle.get(card_id)
    if card is None:
        return None
    facts = grounding_facts(card, deps.ledger, deps.now())
    return facts or None


def _card_action(card: BundleCard, req: AskRequest, normalized: str, deps: AskDeps):
    for key in ("call_desk", "open_map"):
        verb = deps.policy.action_verbs.get(key)
        if key in card.action_keys and key in deps.command_keys and verb is not None and verb.search(normalized):
            return ACallDesk(desk_id=card.desk) if key == "call_desk" else AOpenMap(target=MDesk(desk_id=card.desk))
    person = req.utterance.context.person_id if card.scope != "household" else None
    return ANavigate(destination=DCard(card_id=card.id, person_id=person))


def _desk_resolution(desk_id: str, reason: StringKey, confidence: float, req: AskRequest,
                     navigate: bool) -> IntentResolution:
    """Desk grounding. A confident desk-only answer also navigates to the desk; a low-confidence one only
    names the closest desk (contracts/intent/intent_resolution.desk_handoff.json: action null)."""
    action = ANavigate(destination=DDesk(desk_id=desk_id)) if navigate else None
    return IntentResolution(action=action, grounding=GDesk(desk_id=desk_id, reason=reason),
                            confidence=round(confidence, 3), clarification=None,
                            reply_language=reply_language(req.utterance.language))


def empty_resolution(req: AskRequest) -> IntentResolution:
    """Nothing matched and no desk is known: the phone says it doesn't have this and shows the offices."""
    return IntentResolution(confidence=0.0, reply_language=reply_language(req.utterance.language))


def desk_only_resolution(prep: Prepared, req: AskRequest, deps: AskDeps) -> IntentResolution:
    rule = prep.desk_only
    assert rule is not None
    pool = prep.allowed
    if rule.topics:
        tagged = {cid for cid in pool if set(rule.topics) & set(deps.bundle.cards[cid].topics)}
        if tagged:
            pool = tagged
    ranked = deps.index.search(prep.normalized, stage=None, allowed=pool) or \
        deps.index.search(prep.normalized, stage=None, allowed=prep.allowed)
    if not ranked:
        return empty_resolution(req)
    desk = deps.bundle.cards[ranked[0].card_id].desk
    return _desk_resolution(desk, client_key(f"ask.reason.desk_only.{rule.id}"), DESK_ONLY_CONFIDENCE, req,
                            navigate=True)


def fallback_resolution(prep: Prepared, req: AskRequest, deps: AskDeps, confidence: float) -> IntentResolution:
    """Below the clarify band: name the closest desk (the phone offers it and says it doesn't have this)."""
    if not prep.candidates:
        return empty_resolution(req)
    desk = deps.bundle.cards[prep.candidates[0].card_id].desk
    return _desk_resolution(desk, NO_ANSWER, min(confidence, CLARIFY - 0.01), req, navigate=False)


def card_resolution(card_id: str, facts: list[FactRef], confidence: float, prep: Prepared, req: AskRequest,
                    deps: AskDeps, excluded: set[str]) -> IntentResolution:
    card = deps.bundle.cards[card_id]
    if confidence < CLARIFY:
        return fallback_resolution(prep, req, deps, confidence)
    if confidence < ACT:
        # Clarify band (contracts/intent/intent_resolution.clarification_three_options.json): no action and
        # no grounding; every option carries its own verified action.
        return IntentResolution(action=None, grounding=None, confidence=confidence,
                                clarification=build_clarification(card, prep, req, deps, excluded),
                                reply_language=reply_language(req.utterance.language))
    return IntentResolution(action=_card_action(card, req, prep.normalized, deps),
                            grounding=GCard(card_id=card.id, facts=facts), confidence=confidence,
                            clarification=None, reply_language=reply_language(req.utterance.language))


def build_clarification(chosen: BundleCard, prep: Prepared, req: AskRequest, deps: AskDeps,
                        excluded: set[str]) -> Clarification:
    """One question, 2-3 options, each an action. Card options must pass grounding verification; if only
    the chosen card qualifies, the second option is its desk."""
    picks = [chosen.id]
    for c in prep.candidates:
        if len(picks) == 3:
            break
        if c.card_id in picks or c.card_id in excluded or c.q < OPTION_FLOOR:
            continue
        if check_card(c.card_id, req, deps, prep.allowed) is not None:
            picks.append(c.card_id)
    options = [
        ClarifyOption(id=f"card.{cid}", label=StringKey(key=f"card.{cid}.title", table=CARDS_TABLE),
                      action=_card_action(deps.bundle.cards[cid], req, prep.normalized, deps))
        for cid in picks
    ]
    if len(options) == 1:
        options.append(ClarifyOption(id=f"desk.{chosen.desk}", label=client_key("ask.clarify.option.desk"),
                                     action=ANavigate(destination=DDesk(desk_id=chosen.desk))))
    return Clarification(question=CLARIFY_QUESTION, options=options)


def score(prep: Prepared, chosen: str | None, by_model: bool, excluded: set[str]) -> float:
    remaining = [c for c in prep.candidates if c.card_id not in excluded]
    return calibrate(remaining, chosen, by_model)
