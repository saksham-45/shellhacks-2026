"""/v1 wire models for household-week and person-next-steps (owner: myAD Agents; golden files in
contracts/v1/*.json, reviewed by Lead). /v1/ask models live in intent.py (ARCHITECTURE.md §13.2).

JSON is snake_case with `type`-tagged unions. No model-written prose anywhere (§5, Q17): a claim is a
StringKey into Content's reviewed copy plus the ledger facts that fill it. Every response carries:
- `request_id`: random, echoed, never stored, never tied to a household;
- `facts`: a typed map keyed by fact_id, each entry a tagged FactOutcome (never a nullable value);
- `is_demo` per fact and `has_demo` per response (ledger status `demo`);
- `handoffs`: desk handoffs whose contact lines are only `<desk-id>.*` ledger facts.
"""
from __future__ import annotations

from typing import Annotated, Any, Literal, Union

from pydantic import Field, field_validator, model_serializer, model_validator

from .values import (
    FactRef,
    FactValue,
    LanguageTag,
    Mode,
    StringKey,
    Strict,
    SurfaceLanguage,
    _check_bcp47,
)

Id = Annotated[str, Field(min_length=1, max_length=200)]
RequestId = Annotated[str, Field(pattern=r"^[A-Za-z0-9-]{8,64}$")]


# Plain strings on the wire; values mirror ADCore Goal and OriginLens.
GoalName = Literal["arrive", "study", "work", "reunite", "visit", "getThroughWeek"]
OriginLensName = Literal["latinAmerica", "haiti", "leftDriving", "internationalStudent", "tourist", "questionnaire"]


class Pin(Strict):
    """Address plus optional device coordinates (§13.x). With coordinates the server skips geocoding and
    records basis.method = device_coords. Request-only: never logged, never stored."""

    address: str = Field(min_length=1, max_length=300)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def _both_or_neither(self) -> "Pin":
        if (self.lat is None) != (self.lon is None):
            raise ValueError("lat and lon come together")
        return self


class Money(Strict):
    amount: float = Field(ge=0)
    currency: str = Field(pattern=r"^[A-Z]{3}$")


class Car(Strict):
    gantry_ids: list[Id] = Field(default_factory=list, max_length=20)


class HouseholdInputs(Strict):
    """The household's own answers (not facts). All optional; each is sent only if the phone has it."""

    home_language: LanguageTag | None = None
    rent: Money | None = None
    car: Car | None = None
    child_ages: list[Annotated[int, Field(ge=0, le=25)]] = Field(default_factory=list, max_length=12)

    @field_validator("home_language")
    @classmethod
    def _lang(cls, v: str | None) -> str | None:
        return None if v is None else _check_bcp47(v)


class HouseholdWeekRequest(Strict):
    request_id: RequestId | None = None
    pin: Pin
    surface_language: SurfaceLanguage
    think_in: LanguageTag | None = None
    mode: Mode
    household: HouseholdInputs = Field(default_factory=HouseholdInputs)

    @field_validator("think_in")
    @classmethod
    def _lang(cls, v: str | None) -> str | None:
        return None if v is None else _check_bcp47(v)


class PersonContext(Strict):
    """This person only. Another person's papers never enter this model; status_word only if the person
    chose to enter it."""

    person_id: Id
    age: int | None = Field(default=None, ge=0, le=120)
    origin_lenses: list[OriginLensName] = Field(default_factory=list)
    stage: int = Field(ge=1, le=10)
    mode: Mode
    goal: GoalName
    status_word: str | None = Field(default=None, max_length=40)


class PersonNextStepsRequest(Strict):
    request_id: RequestId | None = None
    person: PersonContext
    pin: Pin | None = None
    surface_language: SurfaceLanguage
    think_in: LanguageTag | None = None

    @field_validator("think_in")
    @classmethod
    def _lang(cls, v: str | None) -> str | None:
        return None if v is None else _check_bcp47(v)


# ---- facts and outcomes -----------------------------------------------------------------------------------


class WireFact(Strict):
    fact_id: Id
    pack_id: Id
    value: FactValue
    status: Literal["verified", "demo"]
    is_demo: bool
    source_id: Id
    source_name: str | None = None
    source_language: LanguageTag | None = None  # BCP-47 of the publisher; omitted when unknown
    url: str
    quote: str
    retrieved_at: str
    jurisdiction: Id
    basis: dict[str, Any] | None = None

    @model_serializer(mode="wrap")
    def _omit_unknown_source_language(self, handler: Any) -> dict[str, Any]:
        d = handler(self)
        if d.get("source_language") is None:
            d.pop("source_language", None)
        return d

    @model_validator(mode="after")
    def _demo_label(self) -> "WireFact":
        if self.is_demo != (self.status == "demo"):
            raise ValueError("is_demo must equal (status == demo)")
        return self


class OFact(Strict):
    type: Literal["fact"] = "fact"
    fact: WireFact


class ONotApplicable(Strict):
    type: Literal["not_applicable"] = "not_applicable"
    fact_id: Id
    reason: StringKey
    desk_id: Id


class ODeferred(Strict):
    """Not applicable here; another pack's fact answers instead."""

    type: Literal["deferred"] = "deferred"
    fact_id: Id
    reason: StringKey
    defer_to: FactRef
    desk_id: Id


class OUnsourced(Strict):
    """No source exists: the card names the desk."""

    type: Literal["unsourced"] = "unsourced"
    fact_id: Id
    desk_id: Id


class OUnavailable(Strict):
    """A source exists but could not be reached (timeout, outage)."""

    type: Literal["unavailable"] = "unavailable"
    fact_id: Id
    desk_id: Id


FactOutcome = Annotated[Union[OFact, ONotApplicable, ODeferred, OUnsourced, OUnavailable],
                        Field(discriminator="type")]


class Handoff(Strict):
    """A desk handoff. `contact` lists only `<desk-id>.{name,phone,url,address,hours,languages}` ledger facts
    that passed verification; their values are in the response's `facts` map."""

    desk_id: Id
    reason: StringKey
    contact: list[FactRef] = Field(default_factory=list)


class Claim(Strict):
    """Reviewed copy (a StringKey) filled with ledger facts. No free text."""

    copy_key: StringKey
    fact_refs: list[FactRef] = Field(min_length=1)
    desk_id: Id | None = None


class WeekItem(Strict):
    card_id: Id
    date: str | None = None
    claims: list[Claim]


class Envelope(Strict):
    request_id: RequestId
    language: LanguageTag
    facts: dict[str, FactOutcome] = Field(default_factory=dict)
    handoffs: list[Handoff] = Field(default_factory=list)
    has_demo: bool = False
    dropped_claims: int = Field(default=0, ge=0)

    @model_validator(mode="after")
    def _consistent(self) -> "Envelope":
        for key, outcome in self.facts.items():
            fid = outcome.fact.fact_id if isinstance(outcome, OFact) else outcome.fact_id
            if key != fid:
                raise ValueError(f"facts key {key!r} does not match its outcome's fact_id {fid!r}")
        demo = any(isinstance(o, OFact) and o.fact.is_demo for o in self.facts.values())
        if demo != self.has_demo:
            raise ValueError("has_demo must be true exactly when a fact is demo")
        return self


class HouseholdWeekResponse(Envelope):
    pack_ids: list[Id]
    items: list[WeekItem]


class NextStep(Strict):
    card_id: Id
    claims: list[Claim]


class PersonNextStepsResponse(Envelope):
    person_id: Id
    steps: list[NextStep] = Field(max_length=3)
    origin_comparison: list[Claim] = Field(default_factory=list)


class NotImplementedBody(Strict):
    detail: str = "not implemented"
    route: str


# Public model surface: keep the /v1 models, shared value union, and intent contract
# importable from one module for FastAPI integrations and contract consumers.
from .intent import (  # noqa: E402  (intent imports only shared values)
    AAnswerOnboarding, ABack, ACallDesk, AChoose, AConfirm, ADeletePerson, AHome, ANavigate,
    ANextStep, AOpenMap, APreviousStep, AReadAloud, ARepeatLast, ASavePerson, ASetMode, ASetPin,
    ASetSurfaceLanguage, ASetThinkIn, AStopSpeaking, AUndo, AppAction, Clarification, ClarifyOption,
    Destination, Grounding, IntentResolution, RouteContext, Utterance,
)

# Demo endpoint models (FM-MYAD-DEMO-DESK) live in demo_models.py, which subclasses Envelope from this module.
# They are re-exported lazily (PEP 562) so importing either module first never hits a circular import.
_DEMO_EXPORTS = frozenset({
    "DemoErrorBody", "DeskTranslateRequest", "DeskTranslateResponse", "FeeAnswerLine", "FeeAsk", "FeeCheckRequest",
    "FeeCheckResponse", "HandoffDrop", "HandoffReadBack", "HandoffSentence", "HandoffSheetRequest",
    "HandoffSheetResponse", "LiveConstraints", "LiveTokenRequest", "LiveTokenResponse",
})


def __getattr__(name: str) -> Any:
    if name in _DEMO_EXPORTS:
        from . import demo_models

        return getattr(demo_models, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
