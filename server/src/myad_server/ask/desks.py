"""Which desk /v1/ask names when it does not ground a card (review r3, M4).

The generic desk follows the household's resolved jurisdiction (a Regions pack chain such as
``["us", "us-fl", "us-fl-miamidade", "us-fl-miami"]``). When the jurisdiction is unknown, or nothing more local
than the state is known, the county desk is used. A city desk is used only when the chain contains that city.
Ledger desk ids are never sorted across packs to pick a winner.
"""
from __future__ import annotations

from collections.abc import Sequence

from ..ledger import DESK_CONTACT_FIELDS, Ledger
from .policy import AskPolicy


def desk_pack(desk_id: str) -> str:
    return desk_id.split(".", 1)[0]


def _verified_desks(ledger: Ledger) -> dict[str, list[str]]:
    """Pack id -> desks that have at least one verified contact fact in the ledger."""
    by_pack: dict[str, set[str]] = {}
    for fact_id, fact in ledger.facts.items():
        desk, _, field = fact_id.rpartition(".")
        if field in DESK_CONTACT_FIELDS and desk and fact.raw.status == "verified":
            by_pack.setdefault(desk_pack(desk), set()).add(desk)
    return {pack: sorted(desks) for pack, desks in by_pack.items()}


class DeskScope:
    """Desk choice for one request, given the household's resolved jurisdiction (None = unknown)."""

    def __init__(self, policy: AskPolicy, ledger: Ledger, jurisdiction: Sequence[str] | None = None):
        self.ledger = ledger
        self.names = policy.generic_desk_names
        j = policy.jurisdictions
        if j is None:
            self.packs: list[str] = []
        else:
            self.packs = j.ancestors(j.most_local(jurisdiction))  # most local first, e.g. county, state, us

    def allows(self, desk_id: str | None) -> bool:
        """A desk may be named only if its pack is the household's jurisdiction or one of its parents."""
        return bool(desk_id) and desk_pack(desk_id) in self.packs

    def generic(self) -> str | None:
        """The declared generic desk (`<pack>.311`) of the most local allowed pack that the ledger knows;
        otherwise the most local allowed pack's own verified desk; otherwise None."""
        verified = _verified_desks(self.ledger)
        for pack in self.packs:
            for name in self.names:
                desk = f"{pack}.{name}"
                if desk in verified.get(pack, ()):
                    return desk
        for pack in self.packs:
            if verified.get(pack):
                return verified[pack][0]
        return None

    def card_desk(self, desk_id: str | None) -> str | None:
        """A card's own desk when it is inside the household's jurisdiction, else the generic desk."""
        return desk_id if self.allows(desk_id) else self.generic()
