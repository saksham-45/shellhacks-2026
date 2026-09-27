"""Intent contract (ARCHITECTURE.md §13.2): Destination, AppAction, Grounding, Clarification, Utterance,
IntentResolution. Mirrors Lead's ADRouter types; tagged JSON (`type`), snake_case keys, string ids.

`POST /v1/ask` returns ONLY an IntentResolution: never free-form prose. The phone applies the thresholds
(>= 0.75 act, 0.40-0.75 clarify, < 0.40 desk); the server only reports a confidence.
"""
from __future__ import annotations

from typing import Annotated, Any, Literal, Union

from pydantic import Field, field_validator, model_validator

from .values import FactRef, LanguageTag, Mode, StringKey, Strict, SurfaceLanguage, _check_bcp47

Id = Annotated[str, Field(min_length=1, max_length=200)]
StageNumber = Annotated[int, Field(ge=1, le=10)]

# ---- Destination -------------------------------------------------------------------------------------


class CardFilter(Strict):
    """ADCore CardFilter: every field only narrows."""

    desk: Id | None = None
    mode: Mode | None = None
    stage: StageNumber | None = None
    subject: Literal["household", "person"] | None = None


class DHousehold(Strict):
    type: Literal["household"] = "household"


class DPerson(Strict):
    type: Literal["person"] = "person"
    person_id: Id


class DEditPerson(Strict):
    type: Literal["edit_person"] = "edit_person"
    person_id: Id


class DAddPerson(Strict):
    type: Literal["add_person"] = "add_person"


class DOnboarding(Strict):
    type: Literal["onboarding"] = "onboarding"
    step: Literal["pin", "people", "origin_and_language", "goal"]


class DStage(Strict):
    type: Literal["stage"] = "stage"
    person_id: Id
    stage: StageNumber


class DCard(Strict):
    type: Literal["card"] = "card"
    card_id: Id
    person_id: Id | None = None


class DCards(Strict):
    type: Literal["cards"] = "cards"
    filter: CardFilter


class DDesk(Strict):
    type: Literal["desk"] = "desk"
    desk_id: Id


class DPin(Strict):
    type: Literal["pin"] = "pin"


class DSettings(Strict):
    type: Literal["settings"] = "settings"


class DLanguage(Strict):
    type: Literal["language"] = "language"


class DVoice(Strict):
    type: Literal["voice"] = "voice"


Destination = Annotated[
    Union[DHousehold, DPerson, DEditPerson, DAddPerson, DOnboarding, DStage, DCard, DCards, DDesk, DPin, DSettings, DLanguage,
          DVoice],
    Field(discriminator="type"),
]

# ---- AppAction ---------------------------------------------------------------------------------------


class RScreen(Strict):
    type: Literal["screen"] = "screen"


class RCard(Strict):
    type: Literal["card"] = "card"
    card_id: Id


class RStep(Strict):
    type: Literal["step"] = "step"


ReadTarget = Annotated[Union[RScreen, RCard, RStep], Field(discriminator="type")]


class MDesk(Strict):
    type: Literal["desk"] = "desk"
    desk_id: Id


class MPlace(Strict):
    """The fact's value must be a `place` (checked by the verifier and the router)."""

    type: Literal["place"] = "place"
    fact: FactRef


MapTarget = Annotated[Union[MDesk, MPlace], Field(discriminator="type")]


class ANavigate(Strict):
    type: Literal["navigate"] = "navigate"
    destination: Destination


class ABack(Strict):
    type: Literal["back"] = "back"


class AHome(Strict):
    type: Literal["home"] = "home"


class AReadAloud(Strict):
    type: Literal["read_aloud"] = "read_aloud"
    target: ReadTarget


class AStopSpeaking(Strict):
    type: Literal["stop_speaking"] = "stop_speaking"


class ARepeatLast(Strict):
    type: Literal["repeat_last"] = "repeat_last"


class ANextStep(Strict):
    type: Literal["next_step"] = "next_step"


class APreviousStep(Strict):
    type: Literal["previous_step"] = "previous_step"


class ACallDesk(Strict):
    type: Literal["call_desk"] = "call_desk"
    desk_id: Id


class AOpenMap(Strict):
    type: Literal["open_map"] = "open_map"
    target: MapTarget


class ASetSurfaceLanguage(Strict):
    type: Literal["set_surface_language"] = "set_surface_language"
    language: SurfaceLanguage


class ASetThinkIn(Strict):
    type: Literal["set_think_in"] = "set_think_in"
    language: LanguageTag

    @field_validator("language")
    @classmethod
    def _lang(cls, v: str) -> str:
        return _check_bcp47(v)


class ADeletePerson(Strict):
    type: Literal["delete_person"] = "delete_person"
    person_id: Id


class PersonOrigin(Strict):
    country_code: str | None = None


class PersonDraft(Strict):
    person_id: Id | None = None
    display_name: str = Field(min_length=1)
    age: int | None = Field(default=None, ge=0, le=120)
    origin: PersonOrigin | None = None
    think_in: LanguageTag | None = None
    surface_language: SurfaceLanguage | None = None
    goal: str | None = None
    mode: Mode | None = None
    stage: StageNumber | None = None
    status_word: str | None = None


class ASavePerson(Strict):
    type: Literal["save_person"] = "save_person"
    person: PersonDraft


class AUndo(Strict):
    type: Literal["undo"] = "undo"


class AAnswerOnboarding(Strict):
    """Household's OnboardingAnswer, carried opaquely (the server never produces one)."""

    type: Literal["answer_onboarding"] = "answer_onboarding"
    answer: dict[str, Any]

    @field_validator("answer")
    @classmethod
    def _tagged(cls, v: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(v.get("type"), str):
            raise ValueError("onboarding answer needs a string `type`")
        return v


class AChoose(Strict):
    type: Literal["choose"] = "choose"
    option_id: Id


class ASetPin(Strict):
    type: Literal["set_pin"] = "set_pin"
    pin_id: Id


class ASetMode(Strict):
    type: Literal["set_mode"] = "set_mode"
    mode: Mode


class AConfirm(Strict):
    type: Literal["confirm"] = "confirm"
    value: bool


AppAction = Annotated[
    Union[ANavigate, ABack, AHome, AReadAloud, AStopSpeaking, ARepeatLast, ANextStep, APreviousStep, ACallDesk,
          AOpenMap, ASetSurfaceLanguage, ASetThinkIn, AAnswerOnboarding, AChoose, ASetPin, ASetMode, AConfirm,
          ADeletePerson, ASavePerson, AUndo],
    Field(discriminator="type"),
]

# ---- Grounding, clarification, resolution --------------------------------------------------------------


class GCard(Strict):
    type: Literal["card"] = "card"
    card_id: Id
    facts: list[FactRef]


class GDesk(Strict):
    type: Literal["desk"] = "desk"
    desk_id: Id
    reason: StringKey


Grounding = Annotated[Union[GCard, GDesk], Field(discriminator="type")]


class ClarifyOption(Strict):
    id: Id
    label: StringKey
    action: AppAction


class Clarification(Strict):
    """Exactly one question with 2 or 3 options; the question is a StringKey, never model prose."""

    question: StringKey
    options: list[ClarifyOption] = Field(min_length=2, max_length=3)

    @model_validator(mode="after")
    def _unique_ids(self) -> "Clarification":
        ids = [o.id for o in self.options]
        if len(set(ids)) != len(ids):
            raise ValueError("clarify option ids repeat")
        return self


class RouteContext(Strict):
    """Ids only (contracts/intent/utterance.with_context.json): current destination, active person and
    that person's stage and mode, visible card or desk, the ids of a pending clarification, and whether a
    confirmation is pending. No pack ids (§13.z: they reveal where the household lives)."""

    awaiting_confirmation: bool = False
    card_id: Id | None = None
    choice_ids: list[Id] = Field(default_factory=list, max_length=3)
    desk_id: Id | None = None
    destination: Destination | None = None
    mode: Mode | None = None
    person_id: Id | None = None
    stage: StageNumber | None = None


class Utterance(Strict):
    text: str = Field(min_length=1, max_length=500)
    language: LanguageTag
    context: RouteContext = RouteContext()

    @field_validator("language")
    @classmethod
    def _lang(cls, v: str) -> str:
        return _check_bcp47(v)


class AskRequest(Strict):
    """The /v1/ask body: utterance plus active-person stage and mode.

    The request deliberately carries no pin, papers, status word, pack ids, or other person's data.
    Stage and mode are top-level fields in the /v1 golden contract; route context remains ids-only.
    """

    request_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9-]{8,64}$")] | None = None
    utterance: Utterance
    stage: StageNumber | None = None
    mode: Mode


class IntentResolution(Strict):
    action: AppAction | None = None
    grounding: Grounding | None = None
    confidence: float = Field(ge=0.0, le=1.0)
    clarification: Clarification | None = None
    reply_language: LanguageTag

    @field_validator("reply_language")
    @classmethod
    def _lang(cls, v: str) -> str:
        return _check_bcp47(v)


# Actions the server may emit from /v1/ask. Everything else (back, home, read_aloud, ...) belongs to the
# on-device CommandMatcher.
SERVER_ACTION_TYPES = frozenset({"navigate", "call_desk", "open_map"})
