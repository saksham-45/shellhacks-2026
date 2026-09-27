"""One Regions adapter result, as the verifier admits it (Regions' CONTRACT.md, as amended 2026-09-25).

`fact_id` is the stable lookup id (also the destination address). `ledger_id` names the ledger entry the
result must be checked against: `<fact_id>.demo.<pin>` (status demo) in fixture mode, `fact_id` in live
mode. Statuses: ok | not_applicable | error | unavailable | unsourced (CONTRACT §2). Only `ok` can ever
become a claim; the others route to their desk (not_applicable may defer to another pack's fact; unsourced
becomes the `unsourced(desk)` outcome).

This model is tolerant of extra keys (internal boundary) and accepts Regions' older key names
(`pack`, `publisher`) so the swap to the aligned names does not break us.
"""
from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, ValidationError

from .values import FACT_ID, PACK_ID, FactValue, _check_bcp47

Status = Literal["ok", "not_applicable", "error", "unavailable", "unsourced", "membership_unknown"]

# Regions' pack-membership boundary fact (CONTRACT §5, `BOUNDARY_ADAPTER` in regionpacks/runtime.py). Flows
# always ask for it so a failed boundary layer, and only that, marks local membership unknown (M3).
BOUNDARY_FACT_IDS: tuple[str, ...] = ("us-fl-miamidade.government.municipality",)
_ID_MAX = 200


class DeferTo(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    pack_id: str = Field(validation_alias=AliasChoices("pack_id", "pack"))
    fact_id: str = Field(validation_alias=AliasChoices("fact_id", "fact"))


class NotApplicable(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True)
    reason: str
    defer_to: DeferTo | None = None


class AdapterResult(BaseModel):
    model_config = ConfigDict(extra="ignore", frozen=True, populate_by_name=True)

    fact_id: str
    ledger_id: str | None = None
    pack_id: str = Field(validation_alias=AliasChoices("pack_id", "pack"))
    status: Status
    fact_status: Literal["demo", "verified"] | None = None
    # Regions must carry this provenance bit through the server boundary.  It
    # is intentionally not derived here: the verifier compares it with the
    # ledger id and status before admitting a WireFact.
    is_demo: bool | None = None
    value: FactValue | None = None
    source_id: str | None = None
    source_name: str | None = Field(default=None, validation_alias=AliasChoices("source_name", "publisher"))
    source_language: str | None = Field(
        default=None, validation_alias=AliasChoices("source_language", "publisher_language")
    )
    url: str | None = None
    retrieved_at: str | None = None
    quote: str | None = None
    jurisdiction: str | None = None
    desk: str | None = None
    basis: dict[str, Any] | None = None
    not_applicable: NotApplicable | None = None
    membership_unknown: bool = False
    error: str | None = None

    @property
    def effective_ledger_id(self) -> str:
        # Missing provenance is rejected at the adapter boundary and verifier;
        # callers that inspect a non-ok fallback still get a safe string.
        return self.ledger_id or ""

    def provenance_error(self) -> str | None:
        """Validate the explicit Regions provenance for an ``ok`` result."""
        if self.status != "ok":
            return None
        if not self.ledger_id or self.is_demo is None or not self.source_id:
            return "missing_provenance"
        if self.is_demo:
            if self.fact_status not in (None, "demo"):
                return "contradictory_provenance"
            if self.ledger_id == self.fact_id or not re.fullmatch(
                re.escape(self.fact_id) + r"\.demo\.pin-[a-z0-9-]+", self.ledger_id
            ):
                return "contradictory_provenance"
        else:
            if self.fact_status not in (None, "verified") or self.ledger_id != self.fact_id:
                return "contradictory_provenance"
        return None


def shape_error(result: AdapterResult) -> str | None:
    """Wire constraints a result must meet before it can reach a FactRef or a WireFact (M2).

    One bad row must be dropped and counted, never turn the whole response into a 503.
    """
    if len(result.fact_id) > _ID_MAX or not FACT_ID.match(result.fact_id):
        return "bad_fact_id"
    if len(result.pack_id) > _ID_MAX or not PACK_ID.match(result.pack_id) \
            or not result.fact_id.startswith(result.pack_id + "."):
        return "bad_pack_id"
    if result.ledger_id is not None and (len(result.ledger_id) > _ID_MAX or not FACT_ID.match(result.ledger_id)):
        return "bad_ledger_id"
    for name in ("source_id", "jurisdiction", "desk"):
        v = getattr(result, name)
        if v is not None and not (1 <= len(v) <= _ID_MAX):
            return f"bad_{name}"
    if result.source_language is not None:
        try:
            _check_bcp47(result.source_language)
        except ValueError:
            return "bad_source_language"
        if not (2 <= len(result.source_language) <= 35):
            return "bad_source_language"
    na = result.not_applicable
    if na and na.defer_to and (not FACT_ID.match(na.defer_to.fact_id) or not PACK_ID.match(na.defer_to.pack_id)):
        return "bad_defer_to"
    return None


def parse_results(raw: list[dict[str, Any]]) -> tuple[list[AdapterResult], list[str]]:
    """Parse Regions' JSON results. Malformed ones are dropped and reported (never raised)."""
    ok: list[AdapterResult] = []
    bad: list[str] = []
    for r in raw if isinstance(raw, list) else []:
        fid = r.get("fact_id") if isinstance(r, dict) else None
        try:
            result = AdapterResult.model_validate(r)
        except ValidationError as e:
            bad.append(f"{fid!r}: {e.error_count()} validation error(s)")
            continue
        reason = shape_error(result) or result.provenance_error()
        if reason is not None:
            bad.append(f"{fid!r}: {reason}")
        else:
            ok.append(result)
    return ok, bad
