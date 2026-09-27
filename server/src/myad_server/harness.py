"""The one entry point: FastAPI routes are thin wrappers over the ask resolver.

Start-up contract (REVIEW r3 B2, M10):
- ``MYAD_OFFLINE=1`` wins over ``MYAD_LIVE=1``.  Offline, the Regions address lookup is only ever built
  over Regions' saved fixtures; the live transport (and so the county locator/geocoder network calls) is
  never constructed.  If fixture mode cannot be forced, there is no address lookup at all.
- A broken ledger, topic vocabulary, card bundle or desk-only policy raises :class:`HarnessStartupError`
  from :meth:`Harness.from_settings` with a message that names the file.  Only a missing or unloadable
  optional Regions runtime degrades (to desk outcomes).
"""
from __future__ import annotations

import inspect
import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable

from .ask.chooser import IntentChooser, RetrievalChooser
from .ask.flow import AskDeps
from .ask.policy import load_policy
from .ask.ranker import Ranker, StubRanker, select_ranker
from .ask.retrieval import IntentIndex
from .ask.resolve import resolve_intent
from .flows.household import run as run_household
from .flows.person import run as run_person
from .models import (HouseholdWeekRequest, HouseholdWeekResponse, PersonNextStepsRequest, PersonNextStepsResponse)
from .regions import RegionsRuntime, load_runtime
from .cards import CardBundle, load_bundle
from .intent import AskRequest, IntentResolution
from .ledger import Ledger, load_ledger
from .settings import Settings
from .topics import load_topics
from .verifier import load_desk_only_topics

_log = logging.getLogger("myad.harness")


class HarnessStartupError(RuntimeError):
    """The server must not start: a required input (ledger, topics, bundle, policy) is broken."""


class FixtureOnlyRuntime:
    """Regions runtime pinned to its saved fixtures (MYAD_OFFLINE=1).

    Every call passes an explicit fixture transport, so Regions' ``default_transport()`` (which reads
    ``MYAD_LIVE``) is never consulted and no socket is opened.
    """

    def __init__(self, module: Any, transport_factory: Callable[[], Any]):
        self._module = module
        self._transport_factory = transport_factory

    def _transport(self) -> Any:
        transport = self._transport_factory()
        if getattr(transport, "live", True) is not False:  # fail closed on anything but a fixture transport
            raise RuntimeError("offline Regions transport is not a fixture transport")
        return transport

    def resolve(self, pin: dict[str, Any], timeout_s: float = 20.0) -> list[str]:
        transport = self._transport()  # checked before Regions is touched
        return self._module.resolve(pin, timeout_s=timeout_s, transport=transport)

    def answer(self, pin: dict[str, Any], fact_ids: list[str] | None = None, topics: list[str] | None = None,
               timeout_s: float = 20.0) -> list[dict[str, Any]]:
        transport = self._transport()  # checked before Regions is touched
        return self._module.answer(pin, fact_ids=fact_ids, topics=topics, timeout_s=timeout_s,
                                   transport=transport)


def _accepts_transport(fn: Any) -> bool:
    try:
        return "transport" in inspect.signature(fn).parameters
    except (TypeError, ValueError):
        return False


def _fixture_transport_factory() -> Callable[[], Any] | None:
    # Regions' own read-only package (importable once load_runtime put regionpacks/ on sys.path).
    try:
        from myad_regions.transport import FixtureTransport  # type: ignore[import-not-found]
    except Exception:  # noqa: BLE001 - no fixture transport means no offline address lookup
        return None
    return FixtureTransport


def build_runtime(settings: Settings,
                  loader: Callable[[Any], RegionsRuntime | None] = load_runtime) -> RegionsRuntime | None:
    """The optional Regions runtime for these settings; None when it is missing or cannot run safely."""
    try:
        module = loader(settings.regionpacks_dir)
    except Exception as e:  # noqa: BLE001 - optional dependency; desks answer instead
        _log.warning("regions runtime unavailable (%s); lookups become desk handoffs", type(e).__name__)
        return None
    if module is None or settings.regions_live:
        return module
    # Not live (MYAD_OFFLINE=1 always lands here, whatever MYAD_LIVE says): pin Regions to fixtures
    # explicitly instead of trusting its per-call MYAD_LIVE read.
    factory = _fixture_transport_factory()
    if factory is None or not (_accepts_transport(getattr(module, "answer", None))
                               and _accepts_transport(getattr(module, "resolve", None))):
        if settings.offline:
            _log.warning("offline and Regions fixture mode cannot be forced; no address lookup")
            return None
        return module
    return FixtureOnlyRuntime(module, factory)


def load_command_keys(path) -> frozenset[str]:
    if not path.is_file():
        return frozenset()
    return frozenset(json.loads(path.read_text(encoding="utf-8")).get("command_keys", []))


@dataclass
class Harness:
    """Validated, immutable-ish request dependencies shared by the app."""

    deps: AskDeps
    ranker: Ranker
    runtime: RegionsRuntime | None = None

    @classmethod
    def build(
        cls,
        *,
        bundle: CardBundle,
        ledger: Ledger,
        chooser: IntentChooser | None = None,
        ranker: Ranker | None = None,
        command_keys: frozenset[str] = frozenset(),
        topics: frozenset[str] | None = None,
        now=None,
        runtime: RegionsRuntime | None = None,
    ) -> "Harness":
        # chooser remains accepted for compatibility with the earlier ask flow;
        # phase 1c-i routes through the deterministic ranker instead.
        deps = AskDeps(
            bundle=bundle,
            index=IntentIndex(list(bundle.cards.values())),
            ledger=ledger,
            policy=load_policy(topics=topics),
            chooser=chooser or RetrievalChooser(),
            command_keys=command_keys,
            now=now or (lambda: datetime.now(timezone.utc)),
        )
        return cls(deps=deps, ranker=ranker or StubRanker(), runtime=runtime)

    @classmethod
    def from_settings(cls, settings: Settings, *,
                      runtime_loader: Callable[[Any], RegionsRuntime | None] = load_runtime) -> "Harness":
        try:
            topics = load_topics(settings.topics_path)
        except Exception as e:  # noqa: BLE001
            raise HarnessStartupError(f"topic vocabulary {settings.topics_path} is invalid: {e}") from e
        try:
            ledger = load_ledger(settings.facts_dir, settings.sources_path, topics)
        except Exception as e:  # noqa: BLE001
            raise HarnessStartupError(f"ledger {settings.facts_dir} failed start-up validation: {e}") from e
        try:
            bundle = load_bundle(settings.cards_bundle, topics)
        except Exception as e:  # noqa: BLE001
            raise HarnessStartupError(f"card bundle {settings.cards_bundle} is invalid: {e}") from e
        try:
            load_desk_only_topics(vocab=topics)
            harness = cls.build(
                bundle=bundle,
                ledger=ledger,
                chooser=RetrievalChooser(),
                ranker=select_ranker(offline=settings.offline),
                command_keys=load_command_keys(settings.command_keys_path),
                topics=topics,
            )
        except Exception as e:  # noqa: BLE001
            raise HarnessStartupError(f"ask policy or command keys are invalid: {e}") from e
        harness.runtime = build_runtime(settings, runtime_loader)
        return harness

    def resolve(self, req: AskRequest) -> IntentResolution:
        return resolve_intent(req, self.deps.bundle, self.deps.ledger, self.ranker, self.deps.policy)

    async def household_week(self, req: HouseholdWeekRequest) -> HouseholdWeekResponse:
        return await run_household(req, bundle=self.deps.bundle, ledger=self.deps.ledger, runtime=self.runtime,
                                    now=self.deps.now())

    async def person_next_steps(self, req: PersonNextStepsRequest) -> PersonNextStepsResponse:
        return await run_person(req, bundle=self.deps.bundle, ledger=self.deps.ledger, runtime=self.runtime,
                                 now=self.deps.now())


def harness_factory(env: dict[str, str] | None = None) -> Callable[[], Harness]:
    """A ``create_app`` factory that builds from the environment and lets start-up errors abort."""
    return lambda: Harness.from_settings(Settings.from_env(env))
