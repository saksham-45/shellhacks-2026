"""Dependencies for the demo routes, built once per app (no per-request state, nothing stored)."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable

from ..ledger import Ledger
from ..settings import Settings
from .fee_catalog import FeeCatalog
from .fee_extract import FeeExtractor, select_extractor
from .handoff import HandoffSummarizer, select_summarizer


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class DemoServices:
    ledger: Ledger
    catalog: FeeCatalog
    now: Callable[[], datetime] = _utcnow
    # Chosen per request so a key added to the environment takes effect; tests inject fakes here.
    extractor_factory: Callable[[], FeeExtractor] = field(default=select_extractor)
    summarizer_factory: Callable[[], HandoffSummarizer] = field(default=select_summarizer)

    @classmethod
    def from_settings(cls, settings: Settings, ledger: Ledger) -> "DemoServices":
        """Reuse the harness ledger (research/facts, validated at start-up) and read Regions' manifest
        declarations read-only. A missing regionpacks folder only means an empty catalog."""
        try:
            catalog = FeeCatalog.from_manifests(settings.regionpacks_dir)
        except Exception:  # noqa: BLE001 - the route still answers with the desk
            catalog = FeeCatalog()
        return cls(ledger=ledger, catalog=catalog)
