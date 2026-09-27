"""Pure admission of drafted claims.

The verifier is deliberately boring: it performs no request I/O, calls no model, and gets
all request evidence through :class:`VerifyContext`.  A claim is returned only
when every referenced fact that applies at the pin can be grounded in the ledger and
(for lookups) in an adapter result from this request.

Most local wins (ARCHITECTURE.md §4, Regions CONTRACT §5).  One card may list the city and the county
answer to the same question, because one bundle serves every pin:
- a local fact whose jurisdiction is outside a *known* pack chain does not apply here.  It is skipped,
  never a failure, and its desk is never chosen (no City of Miami desk at an unincorporated pin);
- a `not_applicable` result that defers to another fact is satisfied when that fact is verified in the
  same request (the claim then cites the deferred-to fact); otherwise the claim hands off to the
  deferred-to fact's desk;
- `not_applicable` without a target passes over to a verified fact of a less local pack in the claim;
- `unavailable`, `error`, `unsourced` and every admission failure stop the claim and hand off.
National and state facts need no address: they always apply.

The only module-level I/O is loading the desk-only topic map from the ask policy once at import.
"""
from __future__ import annotations

from dataclasses import dataclass, field, replace
from datetime import datetime
from pathlib import Path
from types import MappingProxyType
from typing import Any, Literal, Mapping

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .adapter import AdapterResult
from .cards import BundleCard
from .ledger import DEMO_ID, Ledger, LedgerFact, is_stale, parse_instant
from .models import Claim, FactOutcome, Handoff, ODeferred, OFact, ONotApplicable, OUnavailable, OUnsourced, WireFact
from .values import FactRef, FactValue, Mode, StringKey, values_equal
from .visibility import card_visible, fact_visible, is_immigration_card

DeskOnlyKind = Literal["visa_outcome", "clinic_price", "job", "appointment_slot", "school_bus_eligibility"]
DESK_ONLY_KINDS: tuple[str, ...] = (
    "visa_outcome", "clinic_price", "job", "appointment_slot", "school_bus_eligibility",
)
# Names a presenter may put in DraftClaim.kind / DraftClaim.topic.  These are desk-only *kinds*
# (the brief's wording), not research topic ids, and they are never matched against card topics.
_DESK_ONLY_KIND_NAMES = {
    "visa outcome": "visa_outcome", "visa_outcome": "visa_outcome",
    "clinic price": "clinic_price", "clinic_price": "clinic_price",
    "job": "job", "job availability": "job", "job_availability": "job",
    "appointment slot": "appointment_slot", "appointment_slot": "appointment_slot",
    "school-bus eligibility": "school_bus_eligibility",
    "school bus eligibility": "school_bus_eligibility",
    "school_bus_eligibility": "school_bus_eligibility",
}
_POLICY_PATH = Path(__file__).resolve().parent / "data" / "ask_policy.yaml"


def load_desk_only_topics(path: Path = _POLICY_PATH, vocab: frozenset[str] | None = None) -> dict[str, str]:
    """Card topic id -> desk-only kind, read from the ask policy's ``desk_only[].topics``.

    Card topics are validated against research/topics.yaml by parse_bundle, so the card-level backstop can
    only ever fire on topic ids from that vocabulary.  With ``vocab`` given, a named topic that is not in it
    is a start-up error rather than a silently dead guard (REVIEW B1).
    """
    data: Any = yaml.safe_load(path.read_text(encoding="utf-8"))
    rows = data.get("desk_only") if isinstance(data, dict) else None
    if rows is None:
        rows = []
    if not isinstance(rows, list):
        raise ValueError(f"{path}: desk_only must be a list")
    out: dict[str, str] = {}
    for row in rows:
        kind = row.get("id") if isinstance(row, dict) else None
        if kind not in DESK_ONLY_KINDS:
            raise ValueError(f"{path}: unknown desk-only kind {kind!r}")
        topics = row.get("topics") or []
        if not isinstance(topics, list) or not all(isinstance(t, str) and t for t in topics):
            raise ValueError(f"{path}: {kind}: topics must be a list of topic ids")
        for topic in topics:
            if out.get(topic, kind) != kind:
                raise ValueError(f"{path}: topic {topic!r} is mapped to two desk-only kinds")
            out[topic] = kind
    if vocab is not None:
        missing = sorted(set(out) - vocab)
        if missing:
            raise ValueError(f"{path}: desk-only topics {missing} are not in research/topics.yaml")
    return out


# Read at call time (never bound as a default) so the flows and grounding share one map.
DESK_ONLY_TOPICS: Mapping[str, str] = MappingProxyType(load_desk_only_topics())


def desk_only_kind_for_topics(topics: Any) -> str | None:
    """The desk-only kind of the first card topic the policy maps, else None."""
    for topic in topics or ():
        kind = DESK_ONLY_TOPICS.get(topic)
        if kind is not None:
            return kind
    return None


REASON_TABLE = "ADAgentsClient"
_PRIVATE_BASIS_KEYS = frozenset({
    "address", "lat", "lon", "latitude", "longitude", "pin", "coordinate", "coordinates", "query",
})


def reason_key(name: str) -> StringKey:
    return StringKey(key=f"handoff.reason.{name}", table=REASON_TABLE)


class DraftClaim(BaseModel):
    """A claim proposal. It is never sent to a client without verification."""

    model_config = ConfigDict(extra="forbid", frozen=True)
    card_id: str
    copy_key: StringKey
    fact_refs: list[FactRef] = Field(min_length=1)
    # A presenter may assert a typed value; it must equal the ledger/adapter value.
    asserted: dict[str, FactValue] = Field(default_factory=dict)
    kind: str | None = None
    topic: str | None = None
    question: str | None = None
    desk_id: str | None = None
    immigration: bool = False


@dataclass(frozen=True)
class VerifyContext:
    ledger: Ledger
    results: tuple[AdapterResult, ...]
    chain: tuple[str, ...]
    mode: Mode
    now: datetime
    pin_slug: str | None = None
    # The fields below make unanswered questions explicit without making the
    # verifier depend on the graph or card registry.
    planned_questions: tuple[str, ...] = ()
    question_facts: Mapping[str, str] = field(default_factory=dict)
    question_desks: Mapping[str, str] = field(default_factory=dict)
    default_desk: str | None = None
    default_desks: Mapping[str, str] = field(default_factory=dict)
    cards: Mapping[str, BundleCard] = field(default_factory=dict)
    # A pin is not enough to establish local membership.  Flows set this to
    # False when Regions did not resolve membership for this request.  When it
    # is True, `chain` is authoritative: a local pack missing from it does not
    # contain the pin.
    local_membership_known: bool = True


@dataclass(frozen=True)
class Drop:
    index: int
    card_id: str
    reason: str
    fact_id: str | None = None


@dataclass
class Verdict:
    claims: list[tuple[int, Claim]] = field(default_factory=list)
    facts: dict[str, FactOutcome] = field(default_factory=dict)
    handoffs: list[Handoff] = field(default_factory=list)
    dropped: list[Drop] = field(default_factory=list)

    @property
    def has_demo(self) -> bool:
        return any(isinstance(o, OFact) and o.fact.is_demo for o in self.facts.values())

    @property
    def dropped_claims(self) -> int:
        return len(self.dropped)


@dataclass(frozen=True)
class _Fail:
    reason: str
    fact_id: str
    outcome: FactOutcome | None
    desk: str | None
    defer_to: FactRef | None = None


# A local fact whose jurisdiction does not contain the pin: skipped, never a failure or a desk.
_NOT_HERE = "not_applicable_here"


def _sanitize_basis(basis: dict | None) -> dict | None:
    if not basis:
        return None
    return {k: v for k, v in basis.items() if k not in _PRIVATE_BASIS_KEYS} or None


def _is_local_jurisdiction(jurisdiction: str | None) -> bool:
    """Return whether a US fact is below the state level.

    The current pack hierarchy is us > us-fl > county/city.  Treating every
    descendant of us-fl as local is deliberately conservative for future
    county and city packs.
    """
    return bool(jurisdiction and jurisdiction.startswith("us-") and jurisdiction != "us-fl")


def _applies_here(jurisdiction: str | None, ctx: VerifyContext) -> bool:
    """National and state figures need no address; a local one needs its pack in the chain."""
    return not _is_local_jurisdiction(jurisdiction) or jurisdiction in ctx.chain


def _rank(pack: str | None, ctx: VerifyContext) -> int:
    """Position in the country-first chain (larger = more local); -1 when the pack is not in it."""
    return ctx.chain.index(pack) if pack in ctx.chain else -1


def _desk_pack(desk: str) -> str:
    return desk.split(".", 1)[0]


def _desk_applies(desk: str | None, ctx: VerifyContext) -> bool:
    """A desk may be handed to this household only if its pack can contain the pin.

    With known membership, a local desk outside the chain is never chosen.  With unknown membership the
    desk is the only safe answer left, so it is allowed (its facts still are not).
    """
    if not desk:
        return False
    pack = _desk_pack(desk)
    return _applies_here(pack, ctx) or not ctx.local_membership_known


def _fact_for_ref(ledger: Ledger, fact_id: str) -> LedgerFact | None:
    """Resolve exact ids and the ranked lookup ids supported by ``Ledger``."""
    return ledger.get(fact_id) or ledger.lookup_for(fact_id)


def _static_wire(f: LedgerFact, fact_id: str, ledger: Ledger) -> WireFact:
    r = f.raw
    # Callers only use this after typed-value admission; they catch wire-shape errors.
    return WireFact(
        fact_id=fact_id,
        pack_id=fact_id.split(".", 1)[0],
        value=f.typed_value,
        status=r.status,
        is_demo=r.status == "demo",
        source_id=r.source_id,
        source_name=ledger.source_name(r.source_id),
        source_language=ledger.source_language(r.source_id),
        url=r.url or "",
        quote=r.quote or "",
        retrieved_at=r.retrieved_at or "",
        jurisdiction=r.jurisdiction or f.pack_id,
    )


def _type_matches(f: LedgerFact, value: FactValue | None) -> bool:
    return value is not None and (f.raw.value_type is None or value.type == f.raw.value_type)


def _check_static(
    ref: FactRef,
    f: LedgerFact,
    draft: DraftClaim | None,
    ctx: VerifyContext,
    fallback_desk: str | None,
) -> WireFact | _Fail:
    fid = ref.fact_id
    desk = f.raw.desk or fallback_desk
    if f.status not in ("verified", "demo") or is_stale(f, ctx.now):
        return _Fail("not_displayable", fid, OUnsourced(fact_id=fid, desk_id=desk) if desk else None, desk)
    if f.typed_value is None or not _type_matches(f, f.typed_value):
        return _Fail("type_mismatch", fid, OUnsourced(fact_id=fid, desk_id=desk) if desk else None, desk)
    match = DEMO_ID.match(fid)
    if match and ctx.pin_slug is not None and match.group("pin") != ctx.pin_slug:
        return _Fail("wrong_demo_pin", fid, None, desk)
    # Static values are supplied by the ledger. If the presenter also asserted a
    # value, it is an additional equality check, never a source of truth.
    if draft is not None and fid in draft.asserted and not values_equal(draft.asserted[fid], f.typed_value):
        return _Fail("value_mismatch", fid, None, desk)
    try:
        return _static_wire(f, fid, ctx.ledger)
    except (ValidationError, ValueError):
        return _Fail("not_displayable", fid, None, desk)


def _result_for(results: Mapping[str, AdapterResult], fact_id: str) -> AdapterResult | None:
    # Same-request identity is intentional: a result for another fact cannot
    # satisfy this claim, even if its value happens to look useful.
    return results.get(fact_id)


def _defer_desk(ctx: VerifyContext, res: AdapterResult, f: LedgerFact, draft: DraftClaim) -> str | None:
    na = res.not_applicable
    if na and na.defer_to:
        target = _fact_for_ref(ctx.ledger, na.defer_to.fact_id)
        if target and target.raw.desk:
            return target.raw.desk
    return res.desk or f.raw.desk or draft.desk_id


def _check_lookup(
    ref: FactRef,
    f: LedgerFact,
    draft: DraftClaim,
    ctx: VerifyContext,
    results: Mapping[str, AdapterResult],
    fallback_desk: str | None,
) -> WireFact | _Fail:
    fid = ref.fact_id
    res = _result_for(results, fid)
    lookup_desk = f.raw.desk or draft.desk_id or fallback_desk
    if res is None:
        return _Fail("no_lookup_evidence", fid, OUnavailable(fact_id=fid, desk_id=lookup_desk) if lookup_desk else None,
                     lookup_desk)
    if res.membership_unknown:
        return _Fail("membership_unknown", fid,
                     OUnavailable(fact_id=fid, desk_id=lookup_desk) if lookup_desk else None,
                     lookup_desk)
    desk = _defer_desk(ctx, res, f, draft)
    if res.status == "not_applicable":
        na = res.not_applicable
        reason = StringKey(key=(na.reason if na else "not_applicable"), table="ADCityPack")
        outcome: FactOutcome | None = None
        target: FactRef | None = None
        if na and na.defer_to:
            try:
                target = FactRef(pack_id=na.defer_to.pack_id, fact_id=na.defer_to.fact_id)
            except ValueError:
                target = None
        if desk:
            if target is not None:
                outcome = ODeferred(fact_id=fid, reason=reason, defer_to=target, desk_id=desk)
            else:
                outcome = ONotApplicable(fact_id=fid, reason=reason, desk_id=desk)
        return _Fail("not_applicable", fid, outcome, desk, defer_to=target)
    if res.status == "unsourced":
        # Regions: no source exists yet (CONTRACT §2) -> the unsourced(desk) outcome, never unavailable.
        return _Fail("no_source", fid, OUnsourced(fact_id=fid, desk_id=desk) if desk else None, desk)
    if res.status in ("error", "unavailable", "membership_unknown"):
        return _Fail(res.status, fid, OUnavailable(fact_id=fid, desk_id=desk) if desk else None, desk)

    if (provenance_error := res.provenance_error()) is not None:
        return _Fail(provenance_error, fid, None, desk)

    # Adapter admission: explicit Regions provenance is mandatory. retrieved_at is also
    # required to be an offset-bearing ISO instant, matching ledger validation.
    if res.value is None or not (res.url or "").strip() or not (res.retrieved_at or "").strip() \
            or not (res.quote or "").strip():
        return _Fail("adapter_error", fid, None, desk)
    at = parse_instant(res.retrieved_at)
    if at is None or at.utcoffset() is None:
        return _Fail("adapter_error", fid, None, desk)
    if not _type_matches(f, res.value):
        return _Fail("type_mismatch", fid, None, desk)
    if not res.jurisdiction or not _applies_here(res.jurisdiction, ctx):
        return _Fail("wrong_jurisdiction", fid, None, desk)
    # An adapter must not claim to answer through a different pack than the
    # fact it is backing. This also prevents a City figure at a county pin.
    if f.raw.jurisdiction and res.jurisdiction != f.raw.jurisdiction:
        return _Fail("wrong_jurisdiction", fid, None, desk)
    if res.pack_id != ref.pack_id:
        return _Fail("wrong_jurisdiction", fid, None, desk)

    # Provenance has already established the live-vs-demo relationship.  Do
    # not infer or repair it here: only an explicit demo bit can label a demo.
    effective = res.ledger_id
    is_demo = res.is_demo
    if is_demo:
        entry = ctx.ledger.get(effective)
        match = DEMO_ID.match(effective)
        if entry is None or entry.status != "demo" or match is None or match.group("base") != fid:
            return _Fail("wrong_demo_pin", fid, None, desk)
        if ctx.pin_slug is not None and match.group("pin") != ctx.pin_slug:
            return _Fail("wrong_demo_pin", fid, None, desk)
        if entry.typed_value is None or not values_equal(entry.typed_value, res.value):
            return _Fail("value_mismatch", fid, None, desk)
    if fid in draft.asserted and not values_equal(draft.asserted[fid], res.value):
        return _Fail("value_mismatch", fid, None, desk)
    try:
        return WireFact(
            fact_id=fid,
            pack_id=ref.pack_id,
            value=res.value,
            status="demo" if is_demo else "verified",
            is_demo=is_demo,
            source_id=res.source_id,
            source_name=res.source_name or ctx.ledger.source_name(res.source_id),
            source_language=res.source_language or ctx.ledger.source_language(res.source_id),
            url=res.url,
            quote=res.quote,
            retrieved_at=res.retrieved_at,
            jurisdiction=res.jurisdiction,
            basis=_sanitize_basis(res.basis),
        )
    except (ValidationError, ValueError):
        # One malformed adapter row is dropped (and counted), never a 503 for the household (M2).
        return _Fail("adapter_error", fid, None, desk)


def _check_ref(ref: FactRef, draft: DraftClaim, ctx: VerifyContext, results: Mapping[str, AdapterResult],
               fallback_desk: str | None) -> WireFact | _Fail:
    f = _fact_for_ref(ctx.ledger, ref.fact_id)
    if f is None:
        return _Fail("unknown_fact", ref.fact_id, None, draft.desk_id or fallback_desk)
    fact_jurisdiction = f.raw.jurisdiction or f.pack_id
    if not ctx.local_membership_known and _is_local_jurisdiction(fact_jurisdiction):
        desk = f.raw.desk or draft.desk_id or fallback_desk
        return _Fail("membership_unknown", ref.fact_id,
                     OUnavailable(fact_id=ref.fact_id, desk_id=desk) if desk else None,
                     desk)
    if not _applies_here(fact_jurisdiction, ctx):
        # Most local wins: another jurisdiction's figure is not a failure here, and its desk is not ours.
        return _Fail(_NOT_HERE, ref.fact_id, None, None)
    if f.is_lookup:
        return _check_lookup(ref, f, draft, ctx, results, fallback_desk)
    return _check_static(ref, f, draft, ctx, draft.desk_id or fallback_desk)


def _default_desk(ctx: VerifyContext) -> str | None:
    """The most local chain pack's default desk, else the caller's default desk (if it can serve the pin)."""
    for pack in reversed(ctx.chain):
        if pack in ctx.default_desks and _desk_applies(ctx.default_desks[pack], ctx):
            return ctx.default_desks[pack]
    if _desk_applies(ctx.default_desk, ctx):
        return ctx.default_desk
    return None


def _pick_desk(ctx: VerifyContext, *candidates: str | None) -> str | None:
    """The first candidate desk that can serve this pin, else the most local default desk."""
    for desk in candidates:
        if _desk_applies(desk, ctx):
            return desk
    return _default_desk(ctx)


def _card_desk(ctx: VerifyContext, card_id: str) -> str | None:
    card = ctx.cards.get(card_id)
    return card.desk if card else None


def _handoff(desk: str | None, reason: str, ctx: VerifyContext, verdict: Verdict,
             results: Mapping[str, AdapterResult]) -> None:
    if not desk or any(h.desk_id == desk for h in verdict.handoffs):
        return
    contact: list[FactRef] = []
    for cid in ctx.ledger.desk_contact_ids(desk):
        # Contact lines describe the desk, not the pin: once the desk is chosen they need no address,
        # only the normal display checks (verified or demo, fresh, typed).
        f = ctx.ledger.get(cid)
        if f is None or f.is_lookup or not fact_visible(f, ctx.mode):
            continue
        checked = _check_static(FactRef.of(cid), f, None, ctx, desk)
        if isinstance(checked, WireFact):
            contact.append(FactRef.of(cid))
            verdict.facts.setdefault(cid, OFact(fact=checked))
    verdict.handoffs.append(Handoff(desk_id=desk, reason=reason_key(reason), contact=contact))


def _desk_only_kind(draft: DraftClaim, ctx: VerifyContext) -> str | None:
    raw = draft.kind or draft.topic
    if raw:
        name = raw.strip().casefold()
        found = _DESK_ONLY_KIND_NAMES.get(name) or DESK_ONLY_TOPICS.get(raw.strip())
        if found:
            return found
        if draft.kind:
            return None
    card = ctx.cards.get(draft.card_id)
    return desk_only_kind_for_topics(card.topics) if card else None


def _question_desk(question: str, ctx: VerifyContext, drafts: list[DraftClaim]) -> str | None:
    candidates: list[str | None] = [ctx.question_desks.get(question)]
    fid = ctx.question_facts.get(question)
    if fid:
        f = _fact_for_ref(ctx.ledger, fid)
        candidates.append(f.raw.desk if f else None)
    for d in drafts:
        if d.question == question:
            # Most local applicable fact desk first, then the draft's own desk.
            refs = [_fact_for_ref(ctx.ledger, ref.fact_id) for ref in d.fact_refs]
            refs = sorted((f for f in refs if f is not None and f.raw.desk),
                          key=lambda f: -_rank(f.raw.jurisdiction or f.pack_id, ctx))
            candidates.extend(f.raw.desk for f in refs)
            candidates.append(d.desk_id)
    # Lookup question strings are stable in the ledger.
    for f in ctx.ledger.facts.values():
        if f.raw.lookup and f.raw.lookup.question == question and f.raw.desk:
            candidates.append(f.raw.desk)
    return _pick_desk(ctx, *candidates)


def _deferred_packs(results: Mapping[str, AdapterResult]) -> tuple[str, ...]:
    out: list[str] = []
    for res in results.values():
        na = res.not_applicable
        if res.status == "not_applicable" and na and na.defer_to and na.defer_to.pack_id not in out:
            out.append(na.defer_to.pack_id)
    return tuple(out)


def _is_tourist_hidden(draft: DraftClaim, card: BundleCard | None, ctx: VerifyContext) -> bool:
    if ctx.mode != Mode.tourist:
        return False
    if draft.immigration or is_immigration_card(card):
        return True
    return any(not fact_visible(_fact_for_ref(ctx.ledger, ref.fact_id), ctx.mode) for ref in draft.fact_refs)


def _evaluate(draft: DraftClaim, ctx: VerifyContext, results: Mapping[str, AdapterResult],
              verdict: Verdict) -> tuple[list[WireFact], _Fail | None]:
    """Check every ref of one claim under most-local-wins.  Returns (answering facts, failure)."""
    fallback = _card_desk(ctx, draft.card_id) or _default_desk(ctx)
    passed: dict[str, WireFact] = {}
    deferred: list[_Fail] = []
    passed_over: list[_Fail] = []
    skipped: list[str] = []
    for ref in draft.fact_refs:
        checked = _check_ref(ref, draft, ctx, results, fallback)
        if isinstance(checked, WireFact):
            passed.setdefault(checked.fact_id, checked)
            continue
        if checked.reason == _NOT_HERE:
            skipped.append(checked.fact_id)
            continue
        if checked.outcome is not None:
            verdict.facts.setdefault(checked.fact_id, checked.outcome)
        if checked.reason == "not_applicable":
            (deferred if checked.defer_to is not None else passed_over).append(checked)
            continue
        return [], checked

    # defer_to: the deferred-to fact answers, if it is verified in this same request.
    for na in deferred:
        target = na.defer_to
        if target is None or target.fact_id in passed:
            continue
        if target.fact_id in results:
            checked = _check_ref(target, draft, ctx, results, fallback)
            if isinstance(checked, WireFact):
                passed[checked.fact_id] = checked
                continue
            if checked.outcome is not None:
                verdict.facts.setdefault(checked.fact_id, checked.outcome)
        # Nothing verified answers for the deferred-to pack: hand off to its desk, never drop silently.
        return [], na

    # not_applicable without a target passes to a verified parent-pack answer in the same claim.
    for na in passed_over:
        na_pack = na.fact_id.split(".", 1)[0]
        if not any(_rank(w.jurisdiction, ctx) < _rank(na_pack, ctx) for w in passed.values()):
            return [], na

    if not passed:
        # Every ref belongs to a jurisdiction that does not contain the pin.
        first = skipped[0] if skipped else draft.fact_refs[0].fact_id
        return [], _Fail("wrong_jurisdiction", first, None, None)
    return list(passed.values()), None


def verify(drafts: list[DraftClaim], ctx: VerifyContext) -> Verdict:
    """Verify claims using only the supplied ledger, evidence, and context."""
    results: dict[str, AdapterResult] = {}
    for result in ctx.results:
        # The first result is deterministic if a buggy adapter repeats an id.
        results.setdefault(result.fact_id, result)
    if ctx.local_membership_known:
        # Regions' own defer_to says the pin is inside the deferred-to (more local) pack.
        extra = tuple(p for p in _deferred_packs(results) if p not in ctx.chain)
        if extra:
            ctx = replace(ctx, chain=ctx.chain + extra)
    verdict = Verdict()
    survived_questions: set[str] = set()

    for index, draft in enumerate(drafts):
        card = ctx.cards.get(draft.card_id)
        if _is_tourist_hidden(draft, card, ctx):
            verdict.dropped.append(Drop(index, draft.card_id, "tourist_immigration"))
            continue
        kind = _desk_only_kind(draft, ctx)
        if kind is not None:
            verdict.dropped.append(Drop(index, draft.card_id, "desk_only", draft.fact_refs[0].fact_id if draft.fact_refs else None))
            desk = _pick_desk(ctx, draft.desk_id, _card_desk(ctx, draft.card_id))
            _handoff(desk, f"desk_only.{kind}", ctx, verdict, results)
            continue

        passed, failure = _evaluate(draft, ctx, results, verdict)
        if failure is not None:
            verdict.dropped.append(Drop(index, draft.card_id, failure.reason, failure.fact_id))
            if failure.defer_to is not None and failure.desk:
                desk = failure.desk  # Regions routed this question to the deferred-to pack's desk
            else:
                desk = _pick_desk(ctx, failure.desk, draft.desk_id, _card_desk(ctx, draft.card_id))
            reason = "not_applicable" if failure.reason == "wrong_jurisdiction" and failure.desk is None \
                else failure.reason
            _handoff(desk, reason, ctx, verdict, results)
            continue
        for wire in passed:
            verdict.facts.setdefault(wire.fact_id, OFact(fact=wire))
        verdict.claims.append((index, Claim(copy_key=draft.copy_key,
                                            fact_refs=[FactRef(pack_id=w.pack_id, fact_id=w.fact_id) for w in passed],
                                            desk_id=draft.desk_id if _desk_applies(draft.desk_id, ctx) else None)))
        if draft.question:
            survived_questions.add(draft.question)

    # A planned question must have either a surviving claim or an explicit desk.
    # This is intentionally after claim verification so a failed claim cannot
    # accidentally make a question look answered.
    for question in ctx.planned_questions:
        if question not in survived_questions:
            _handoff(_question_desk(question, ctx, drafts), "no_source", ctx, verdict, results)
    return verdict


# ---- pinless /ask grounding helpers ----------------------------------------------------------------------


def _card_has_desk_only_topic(card: BundleCard) -> bool:
    return desk_only_kind_for_topics(card.topics) is not None


def grounding_facts(card: BundleCard, ledger: Ledger, now: datetime) -> list[FactRef]:
    # Desk-only cards may be indexed for handoff, but their facts are never card grounding.
    if _card_has_desk_only_topic(card):
        return []
    out: list[FactRef] = []
    for fid in card.fact_refs:
        f = ledger.get(fid)
        if f is None or f.demo_base is not None:
            continue
        if f.is_lookup or (f.typed_value is not None and f.status in ("verified", "demo") and not is_stale(f, now)):
            out.append(FactRef.of(fid))
    return out


def place_fact_ok(ref: FactRef, ledger: Ledger) -> bool:
    f = ledger.get(ref.fact_id)
    return bool(f and ((f.raw.value_type == "place") or (f.typed_value is not None and f.typed_value.type == "place")))
