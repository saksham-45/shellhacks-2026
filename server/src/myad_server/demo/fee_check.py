"""Fee Check: a deterministic matcher over ledger fee facts, admitted by the existing verifier.

Pipeline (plan "## 2. Fee Check"; hard rule: never invent facts):
1. the extractor (rule offline, Gemini live) turns text into a FeeAsk; `sanitize` re-validates it;
2. the purpose resolves to a Regions fee group / declared fact ids for the region's pack chain;
3. drafts go through `verifier.verify` (ledger status, freshness, typed value, jurisdiction chain, tourist
   immigration drop) and only admitted facts reach the answer;
4. the sentence is reviewed copy (data/fee_purposes.yaml) filled ONLY with admitted facts' own fields: the
   money value, the text value, the source publisher. The asked amount never appears in the answer, and a
   private price never gets a verdict.
Every answer names a desk: the fact's desk, the group's desk, the accredited-help desk for immigration, or
the region's 311 desk. Desk contact lines are only `<desk>.*` ledger facts admitted by the verifier.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
from typing import Sequence

from ..demo_models import FeeAnswerLine, FeeAsk, FeeCheckRequest, FeeCheckResponse, FeeOutcome
from ..ledger import Ledger
from ..models import FactOutcome, Handoff, OFact, StringKey, WireFact
from ..values import FactRef, Mode
from ..verifier import DraftClaim, Verdict, VerifyContext, _handoff, verify
from ..visibility import IMMIGRATION_TOPICS
from .fee_catalog import FeeCatalog, FeeGroup
from .fee_extract import PRIVATE_SERVICE, UNKNOWN, FeeExtractor, combined_text, sanitize
from .fee_vocab import FeeVocab, load_vocab

COPY_TABLE = "ADAgentsClient"


@dataclass(frozen=True)
class _Plan:
    outcome: FeeOutcome
    group: FeeGroup | None
    fact_ids: tuple[str, ...]
    desk_id: str | None
    immigration: bool


def purpose_keys(groups: Sequence[FeeGroup]) -> list[str]:
    """The request's purpose enum: Regions group keys and their declared fact ids (plus the two sentinels,
    added by the extractor schema)."""
    keys: list[str] = []
    for g in groups:
        keys.append(g.key)
        keys.extend(g.fact_ids)
    return list(dict.fromkeys(keys))


def _is_immigration(group: FeeGroup, ledger: Ledger) -> bool:
    topics = set(group.topics())
    for fid in group.fact_ids:
        f = ledger.get(fid)
        if f is not None:
            topics.update(f.raw.topics)
    return bool(topics & IMMIGRATION_TOPICS)


def _default_desk(catalog: FeeCatalog, chain: tuple[str, ...], ledger: Ledger) -> str | None:
    """The region's general desk: a manifest `<pack>.311` desk (most local first) that the ledger knows."""
    declared = [d for d in catalog.desks_for(chain) if d.endswith(".311")]
    for desk in dict.fromkeys([*declared, *(f"{pack}.311" for pack in reversed(chain))]):
        if ledger.has_desk(desk):
            return desk
    return declared[0] if declared else None


def _plan(ask: FeeAsk, groups: Sequence[FeeGroup], ledger: Ledger, vocab: FeeVocab, mode: Mode,
          default_desk: str | None) -> _Plan:
    by_key = {g.key: g for g in groups}
    by_fact = {fid: g for g in groups for fid in g.fact_ids}
    purpose = ask.purpose_key
    group = by_key.get(purpose) or by_fact.get(purpose)

    if group is None:
        private = purpose == PRIVATE_SERVICE or (purpose == UNKNOWN and ask.payee_type == "private")
        return _Plan("private_no_verdict" if private else "no_official_fee", None, (), default_desk, False)
    if group.key in vocab.private_groups:
        return _Plan("private_no_verdict", group, (), group.desk_id or default_desk, False)

    immigration = _is_immigration(group, ledger)
    if immigration:
        if mode == Mode.tourist:
            # The drafts still go to the verifier, which drops them (tourist_immigration); the desk is the
            # region's general desk, never an immigration desk.
            return _Plan("not_shown_tourist", group, group.fact_ids[:3], default_desk, True)
        desk = vocab.immigration_desk if vocab.immigration_desk and ledger.has_desk(vocab.immigration_desk) \
            else group.desk_id
        return _Plan("immigration_lines", group, group.fact_ids[:3], desk or default_desk, True)

    fact_id = purpose if purpose in group.fact_ids else group.fact_ids[0]
    f = ledger.get(fact_id)
    desk = (f.raw.desk if f is not None and f.raw.desk else None) or group.desk_id or default_desk
    return _Plan("official_fee", group, (fact_id,), desk, False)


def _money(fact: WireFact) -> str | None:
    v = fact.value
    if getattr(v, "type", None) != "money":
        return None
    amount = Decimal(v.amount).quantize(Decimal("0.01"))
    return f"${amount:,}" if v.currency == "USD" else f"{amount:,} {v.currency}"


def _source(fact: WireFact) -> str:
    return fact.source_name or fact.source_id


def _admitted(verdict: Verdict, fact_id: str) -> WireFact | None:
    o = verdict.facts.get(fact_id)
    return o.fact if isinstance(o, OFact) else None


def _desk_label(verdict: Verdict, desk_id: str | None, language: str, vocab: FeeVocab) -> tuple[str, list[str]]:
    if desk_id:
        name = _admitted(verdict, f"{desk_id}.name")
        if name is not None:
            v = name.value
            text = getattr(v, "code", None) or getattr(v, "text", None)
            if isinstance(text, str) and text:
                return text, [name.fact_id]
    return vocab.text("desk_fallback" if desk_id else "desk_none", language), []


def _line(fact: WireFact, text: str, extra_ids: Sequence[str] = ()) -> FeeAnswerLine:
    return FeeAnswerLine(text=text, fact_ids=[fact.fact_id, *extra_ids], source_id=fact.source_id,
                         source_name=fact.source_name, url=fact.url or None)


def _rule_line(fact: WireFact, language: str, vocab: FeeVocab) -> FeeAnswerLine | None:
    v = fact.value
    if getattr(v, "type", None) != "text":
        return None
    text_lang = v.language.split("-")[0]
    if text_lang not in ("en", language):  # never show a quote in a third language
        return None
    note = "" if text_lang == language else vocab.text("quoted_in_english", language)
    return _line(fact, vocab.text("official_rule", language).format(source=_source(fact), text=v.text, note=note))


async def run(
    req: FeeCheckRequest,
    *,
    request_id: str,
    ledger: Ledger,
    catalog: FeeCatalog,
    extractor: FeeExtractor,
    now: datetime,
    vocab: FeeVocab | None = None,
) -> FeeCheckResponse:
    vocab = vocab or load_vocab()
    language = req.language.value
    chain = catalog.chain(req.region)
    groups = catalog.groups_for(chain)
    purposes = purpose_keys(groups)
    text = combined_text(req.text, req.ocr_text)

    raw_ask = await extractor.extract(text, purposes)
    ask, dropped_fields = sanitize(raw_ask, text, purposes)
    extractor_name = "gemini" if getattr(extractor, "name", "") == "gemini" and not getattr(
        extractor, "used_fallback", False) else "rule"

    default_desk = _default_desk(catalog, chain, ledger)
    plan = _plan(ask, groups, ledger, vocab, req.mode, default_desk)

    # Drafts: one per fact so one bad row never hides another. The addon is its own draft.
    drafts: list[DraftClaim] = []
    card_id = f"fee-check.{plan.group.key if plan.group else 'none'}"
    for fid in plan.fact_ids:
        drafts.append(DraftClaim(card_id=card_id, copy_key=StringKey(key=f"fee_check.{plan.outcome}",
                                                                     table=COPY_TABLE),
                                 fact_refs=[FactRef.of(fid)], desk_id=plan.desk_id, immigration=plan.immigration))
    addon_ids: tuple[str, ...] = ()
    if plan.outcome == "official_fee" and plan.group is not None:
        addon_ids = tuple(a for a in vocab.addons.get(plan.group.key, ()) if a not in plan.fact_ids)
        for aid in addon_ids:
            f = ledger.get(aid)
            drafts.append(DraftClaim(card_id=card_id, copy_key=StringKey(key="fee_check.addon", table=COPY_TABLE),
                                     fact_refs=[FactRef.of(aid)],
                                     desk_id=(f.raw.desk if f is not None else None) or plan.desk_id))

    ctx = VerifyContext(ledger=ledger, results=(), chain=chain, mode=req.mode, now=now,
                        default_desk=plan.desk_id)
    verdict = verify(drafts, ctx) if drafts else Verdict()
    # Every answer ends at a desk: add the plan's desk (contact lines only if the ledger verifies them).
    _handoff(plan.desk_id, f"fee_check.{plan.outcome}", ctx, verdict, {})

    lines: list[FeeAnswerLine] = []
    outcome: FeeOutcome = plan.outcome
    admitted_main = [w for fid in plan.fact_ids if (w := _admitted(verdict, fid)) is not None
                     and any(fid in [r.fact_id for r in c.fact_refs] for _, c in verdict.claims)]
    if plan.outcome == "official_fee" and admitted_main:
        main = admitted_main[0]
        amount = _money(main)
        if amount is not None:
            addon_text, addon_used = "", []
            for aid in addon_ids:
                w = _admitted(verdict, aid)
                a = _money(w) if w is not None else None
                if a is not None and any(aid in [r.fact_id for r in c.fact_refs] for _, c in verdict.claims):
                    addon_text, addon_used = vocab.text("addon", language).format(amount=a), [aid]
                    addon_fact = ledger.get(aid)
                    if addon_fact is not None and addon_fact.raw.desk:
                        # The office that charges the add-on is a desk too (e.g. the Tax Collector).
                        _handoff(addon_fact.raw.desk, "fee_check.addon", ctx, verdict, {})
                    break
            lines.append(_line(main, vocab.text("official_fee", language).format(
                source=_source(main), amount=amount, addon=addon_text), addon_used))
        else:
            rule = _rule_line(main, language, vocab)
            if rule is not None:
                lines.append(rule)
                outcome = "official_rule"
    elif plan.outcome == "immigration_lines":
        for w in admitted_main:
            rule = _rule_line(w, language, vocab)
            if rule is not None:
                lines.append(rule)

    if not lines:
        if plan.outcome in ("official_fee", "immigration_lines"):
            outcome = "no_official_fee"
        desk_text, desk_ids = _desk_label(verdict, plan.desk_id, language, vocab)
        lines.append(FeeAnswerLine(text=vocab.text(outcome, language).format(desk=desk_text), fact_ids=desk_ids))

    # Only admitted facts that a line or a handoff actually uses go out.
    used = {fid for line in lines for fid in line.fact_ids}
    used |= {ref.fact_id for h in verdict.handoffs for ref in h.contact}
    facts: dict[str, FactOutcome] = {k: v for k, v in verdict.facts.items()
                                     if not isinstance(v, OFact) or k in used}
    handoffs: list[Handoff] = verdict.handoffs
    return FeeCheckResponse(
        request_id=request_id,
        language=language,
        facts=facts,
        handoffs=handoffs,
        has_demo=any(isinstance(o, OFact) and o.fact.is_demo for o in facts.values()),
        dropped_claims=verdict.dropped_claims + dropped_fields,
        region=req.region,
        mode=req.mode,
        extractor=extractor_name,
        ask=ask,
        outcome=outcome,
        lines=lines,
        desk_id=plan.desk_id,
    )
