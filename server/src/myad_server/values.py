"""Shared wire value types: BCP-47 tags, StringKey, FactRef, and the ten-case FactValue.

ARCHITECTURE.md §13.z is the contract: FactValue has exactly ten cases (text, code, codes, phone, date,
money, quantity, weekdays, place, flag). There is no number, url, or verbatim case, and "none recorded" is
an outcome, never a sentinel value. JSON is tagged with a `type` discriminator and snake_case keys.
"""
from __future__ import annotations

import re
from datetime import date as Date
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Any, Literal, Union

from pydantic import BaseModel, ConfigDict, Field, PlainSerializer, field_validator, model_serializer, model_validator

BCP47 = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{1,8})*$")
FACT_ID = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$")
PACK_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
CURRENCY = re.compile(r"^[A-Z]{3}$")


def _check_bcp47(v: str) -> str:
    if not BCP47.match(v):
        raise ValueError(f"not a plain BCP-47 language tag: {v!r}")
    return v


LanguageTag = Annotated[str, Field(min_length=2, max_length=35)]
"""A plain BCP-47 string ("es", "en", "ht", "hi"); validated where it is used."""


class Strict(BaseModel):
    """Wire models reject unknown keys, so a golden file that drifts fails loudly."""

    model_config = ConfigDict(extra="forbid", frozen=True)


class SurfaceLanguage(StrEnum):
    es = "es"
    en = "en"
    ht = "ht"


class Mode(StrEnum):
    resident = "resident"
    tourist = "tourist"


class Weekday(StrEnum):
    sunday = "sunday"
    monday = "monday"
    tuesday = "tuesday"
    wednesday = "wednesday"
    thursday = "thursday"
    friday = "friday"
    saturday = "saturday"


class StringKey(Strict):
    """A reference to reviewed copy (ADCore StringKey): the phone looks `key` up in `table`."""

    key: str = Field(min_length=1)
    table: str = Field(min_length=1)


class FactRef(Strict):
    """Wire JSON {"pack_id", "fact_id"} (ARCHITECTURE.md §13.z)."""

    pack_id: str
    fact_id: str

    @model_validator(mode="after")
    def _prefixed(self) -> "FactRef":
        if not PACK_ID.match(self.pack_id):
            raise ValueError(f"bad pack_id {self.pack_id!r}")
        if not FACT_ID.match(self.fact_id) or not self.fact_id.startswith(self.pack_id + "."):
            raise ValueError(f"fact_id {self.fact_id!r} must be dotted and start with pack_id {self.pack_id!r}")
        return self

    @classmethod
    def of(cls, fact_id: str) -> "FactRef":
        """The pack id is the fact id's first segment (ARCHITECTURE.md §7)."""
        return cls(pack_id=fact_id.split(".", 1)[0], fact_id=fact_id)


def _decimal_json(d: Decimal) -> int | float:
    return int(d) if d == d.to_integral_value() else float(d)


JsonDecimal = Annotated[Decimal, PlainSerializer(_decimal_json, return_type=Union[int, float], when_used="json")]


class TextValue(Strict):
    type: Literal["text"] = "text"
    text: str = Field(min_length=1)
    language: LanguageTag

    @field_validator("language")
    @classmethod
    def _lang(cls, v: str) -> str:
        return _check_bcp47(v)


class CodeValue(Strict):
    """Never translated: folio, district id, grade span, member and route names."""

    type: Literal["code"] = "code"
    code: str = Field(min_length=1)


class CodesValue(Strict):
    type: Literal["codes"] = "codes"
    codes: list[Annotated[str, Field(min_length=1)]] = Field(min_length=1)


class PhoneValue(Strict):
    type: Literal["phone"] = "phone"
    digits: str = Field(pattern=r"^\+?[0-9]{3,15}$")


class DateValue(Strict):
    type: Literal["date"] = "date"
    date: Date


class MoneyValue(Strict):
    type: Literal["money"] = "money"
    amount: JsonDecimal
    currency: str = Field(pattern=CURRENCY.pattern)


class QuantityValue(Strict):
    """Year built is quantity(1984, unit "year")."""

    type: Literal["quantity"] = "quantity"
    amount: JsonDecimal
    unit: str = Field(min_length=1)


class WeekdaysValue(Strict):
    type: Literal["weekdays"] = "weekdays"
    days: list[Weekday] = Field(min_length=1, max_length=7)

    @field_validator("days")
    @classmethod
    def _unique(cls, v: list[Weekday]) -> list[Weekday]:
        if len(set(v)) != len(v):
            raise ValueError("weekdays repeat")
        return v


class Coordinate(Strict):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class Place(Strict):
    """ADCore Place: the name is a proper noun, never translated."""

    name: str = Field(min_length=1)
    coordinate: Coordinate
    address: str | None = None
    language: LanguageTag | None = None  # BCP-47 of name and address; omitted when unknown

    @model_serializer(mode="wrap")
    def _omit_unknown_language(self, handler: Any) -> dict[str, Any]:
        d = handler(self)
        if d.get("language") is None:
            d.pop("language", None)
        return d


class PlaceValue(Strict):
    type: Literal["place"] = "place"
    place: Place


class FlagValue(Strict):
    type: Literal["flag"] = "flag"
    value: bool


FactValue = Annotated[
    Union[TextValue, CodeValue, CodesValue, PhoneValue, DateValue, MoneyValue, QuantityValue, WeekdaysValue,
          PlaceValue, FlagValue],
    Field(discriminator="type"),
]

VALUE_TYPES: frozenset[str] = frozenset(
    {"text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag"}
)
ValueType = Literal["text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag"]


def values_equal(a: Any, b: Any) -> bool:
    """Semantic equality: weekdays and codes compare as sets, decimals numerically."""
    if a is None or b is None or a.type != b.type:
        return False
    if a.type == "weekdays":
        return set(a.days) == set(b.days)
    if a.type == "codes":
        return sorted(a.codes) == sorted(b.codes)
    return a.model_dump() == b.model_dump()
