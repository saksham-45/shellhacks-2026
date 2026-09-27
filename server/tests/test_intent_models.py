import pytest
from pydantic import ValidationError

from myad_server.intent import AskRequest, Clarification, IntentResolution, Utterance

NAV = {"type": "navigate", "destination": {"type": "card", "card_id": "test-card", "person_id": None}}


def _opt(i, action=NAV):
    return {"id": f"opt-{i}", "label": {"key": f"card.c{i}.title", "table": "Cards"}, "action": action}


def test_card_destination_encodes_like_the_contract_example():
    r = IntentResolution.model_validate({"action": NAV, "confidence": 0.8, "reply_language": "es"})
    assert r.model_dump(mode="json")["action"] == NAV


@pytest.mark.parametrize("n", [0, 1, 4])
def test_clarification_needs_two_or_three_options(n):
    with pytest.raises(ValidationError):
        Clarification.model_validate({"question": {"key": "q", "table": "ADAgentsClient"},
                                      "options": [_opt(i) for i in range(n)]})


def test_clarification_option_ids_unique():
    with pytest.raises(ValidationError):
        Clarification.model_validate({"question": {"key": "q", "table": "T"}, "options": [_opt(1), _opt(1)]})


@pytest.mark.parametrize("action", [
    {"type": "back"}, {"type": "home"}, {"type": "read_aloud", "target": {"type": "screen"}},
    {"type": "read_aloud", "target": {"type": "card", "card_id": "c"}}, {"type": "stop_speaking"},
    {"type": "repeat_last"}, {"type": "next_step"}, {"type": "previous_step"},
    {"type": "call_desk", "desk_id": "test.desk"},
    {"type": "open_map", "target": {"type": "desk", "desk_id": "test.desk"}},
    {"type": "open_map", "target": {"type": "place", "fact": {"pack_id": "us", "fact_id": "us.test.place"}}},
    {"type": "set_surface_language", "language": "ht"}, {"type": "set_think_in", "language": "hi"},
    {"type": "answer_onboarding", "answer": {"type": "goal", "goal": "work"}},
    {"type": "choose", "option_id": "opt-1"}, {"type": "set_pin", "pin_id": "pin-test1"},
    {"type": "set_mode", "mode": "tourist"}, {"type": "confirm", "value": True},
    {"type": "navigate", "destination": {"type": "cards", "filter": {"desk": None, "mode": None, "stage": 3, "subject": None}}},
    {"type": "navigate", "destination": {"type": "stage", "person_id": "p1", "stage": 10}},
    {"type": "navigate", "destination": {"type": "onboarding", "step": "origin_and_language"}},
])
def test_every_action_shape_round_trips(action):
    r = IntentResolution.model_validate({"action": action, "confidence": 1.0, "reply_language": "en"})
    assert r.model_dump(mode="json")["action"] == action


@pytest.mark.parametrize("bad", [
    {"confidence": 1.2}, {"confidence": -0.1}, {"reply_language": "Spanish"}, {"answer": "free-form prose"},
])
def test_resolution_rejects_out_of_contract(bad):
    body = {"confidence": 0.5, "reply_language": "es", **bad}
    with pytest.raises(ValidationError):
        IntentResolution.model_validate(body)


BASE = {"utterance": {"text": "hola", "language": "es"}, "stage": 1, "mode": "resident"}


@pytest.mark.parametrize("extra", [
    {"papers": {"status_word": "TEST"}}, {"status_word": "TEST"}, {"pin": {"address": "x"}},
    {"household": {}}, {"people": []}, {"pack_ids": ["us"]},
])
def test_ask_request_rejects_anything_beyond_the_contract(extra):
    with pytest.raises(ValidationError):
        AskRequest.model_validate({**BASE, **extra})


def test_route_context_has_no_pack_ids():
    with pytest.raises(ValidationError):
        Utterance.model_validate({"text": "x", "language": "es", "context": {"pack_ids": ["us"]}})


def test_ask_request_accepts_the_contract():
    r = AskRequest.model_validate({**BASE, "utterance": {"text": "hola", "language": "ht",
                                                         "context": {"destination": {"type": "household"},
                                                                     "person_id": "p1", "card_id": None}}})
    assert r.stage == 1 and r.utterance.language == "ht"
