import json

import pytest
from pydantic import TypeAdapter, ValidationError

from myad_server.values import VALUE_TYPES, FactRef, FactValue, values_equal

TA = TypeAdapter(FactValue)

TEN = [
    {"type": "text", "text": "TEST", "language": "ht"},
    {"type": "code", "code": "00-0000-000-0000"},
    {"type": "codes", "codes": ["TEST-A", "TEST-B"]},
    {"type": "phone", "digits": "5550100"},
    {"type": "date", "date": "2026-09-29"},
    {"type": "money", "amount": 12.5, "currency": "USD"},
    {"type": "quantity", "amount": 1900, "unit": "year"},
    {"type": "weekdays", "days": ["tuesday", "friday"]},
    {"type": "place", "place": {"name": "Test School", "coordinate": {"latitude": 0.0, "longitude": 0.0},
                                "address": None}},
    {"type": "flag", "value": True},
]


def test_exactly_ten_value_types():
    assert VALUE_TYPES == {v["type"] for v in TEN}
    assert len(VALUE_TYPES) == 10


@pytest.mark.parametrize("raw", TEN, ids=[v["type"] for v in TEN])
def test_each_case_round_trips_as_tagged_json(raw):
    value = TA.validate_python(raw)
    assert json.loads(TA.dump_json(value)) == raw


@pytest.mark.parametrize("raw", [
    {"type": "number", "value": "3", "unit": None},
    {"type": "url", "url": "https://example.invalid"},
    {"type": "verbatim", "text": "x"},
    {"type": "text", "text": "x", "language": "Spanish"},
    {"type": "phone", "digits": "call us"},
    {"type": "money", "amount": 1, "currency": "usd"},
    {"type": "weekdays", "days": ["tuesday", "tuesday"]},
    {"type": "weekdays", "days": ["funday"]},
    {"type": "flag", "value": True, "extra": 1},
])
def test_rejects_non_contract_values(raw):
    with pytest.raises(ValidationError):
        TA.validate_python(raw)


def test_money_amount_is_a_json_number_not_a_string():
    v = TA.validate_python({"type": "money", "amount": "12.50", "currency": "USD"})
    assert json.loads(TA.dump_json(v))["amount"] == 12.5


def test_values_equal_is_semantic():
    a = TA.validate_python({"type": "weekdays", "days": ["friday", "tuesday"]})
    b = TA.validate_python({"type": "weekdays", "days": ["tuesday", "friday"]})
    assert values_equal(a, b)
    assert not values_equal(a, TA.validate_python({"type": "weekdays", "days": ["monday"]}))
    assert values_equal(TA.validate_python({"type": "quantity", "amount": "1984", "unit": "year"}),
                        TA.validate_python({"type": "quantity", "amount": 1984.0, "unit": "year"}))
    assert not values_equal(None, a)


def test_factref_wire_keys_and_prefix_rule():
    ref = FactRef.of("us-fl-miami.test.trash-day")
    assert ref.model_dump() == {"pack_id": "us-fl-miami", "fact_id": "us-fl-miami.test.trash-day"}
    with pytest.raises(ValidationError):
        FactRef(pack_id="us-fl-miami", fact_id="us-fl-miamidade.test.x")
    with pytest.raises(ValidationError):
        FactRef.model_validate({"pack": "us", "fact": "us.test.x"})


def test_place_and_source_language_tags_optional():
    from myad_server.adapter import AdapterResult
    from myad_server.values import Place

    p = Place.model_validate({"name": "Miami-Dade County", "coordinate": {"latitude": 25.7, "longitude": -80.4}, "language": "en"})
    assert p.language == "en"
    assert Place.model_validate({"name": "X", "coordinate": {"latitude": 0, "longitude": 0}}).language is None
    r = AdapterResult.model_validate({"fact_id": "f", "pack_id": "p", "status": "ok", "publisher_language": "en"})
    assert r.source_language == "en"
