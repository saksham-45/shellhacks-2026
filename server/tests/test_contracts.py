"""Golden files: contracts/v1/*.json (ours) and contracts/intent/*.json (Lead's). Every file must decode
into the pydantic models and re-encode to the same JSON, so server and phone cannot drift."""
import json
from pathlib import Path

import pytest
from pydantic import BaseModel, TypeAdapter

from myad_server.intent import SERVER_ACTION_TYPES, AppAction, AskRequest, Clarification, Destination, Grounding
from myad_server.intent import IntentResolution, RouteContext, Utterance
from myad_server.models import (
    DemoErrorBody,
    DeskTranslateRequest,
    DeskTranslateResponse,
    FeeCheckRequest,
    FeeCheckResponse,
    HandoffSheetRequest,
    HandoffSheetResponse,
    HouseholdWeekRequest,
    HouseholdWeekResponse,
    LiveTokenRequest,
    LiveTokenResponse,
    PersonNextStepsRequest,
    PersonNextStepsResponse,
)

CONTRACTS = Path(__file__).resolve().parents[2] / "contracts"
V1 = sorted((CONTRACTS / "v1").glob("*.json"))
INTENT = sorted((CONTRACTS / "intent").glob("*.json"))

V1_MODELS = {
    ("ask", "request"): AskRequest,
    ("ask", "response"): IntentResolution,
    ("household_week", "request"): HouseholdWeekRequest,
    ("household_week", "response"): HouseholdWeekResponse,
    ("person_next_steps", "request"): PersonNextStepsRequest,
    ("person_next_steps", "response"): PersonNextStepsResponse,
}

# Demo endpoints (FM-MYAD-DEMO-DESK; server/DEMO-ENDPOINTS.md). Their goldens live one level down in
# contracts/v1/demo/ so the phone's top-level v1 golden set (ADAgentsClient pins it) is unchanged until the
# iOS side adopts these routes.
V1_DEMO = sorted((CONTRACTS / "v1" / "demo").glob("*.json"))
V1_DEMO_MODELS = {
    ("fee_check", "request"): FeeCheckRequest,
    ("fee_check", "response"): FeeCheckResponse,
    ("handoff_sheet", "request"): HandoffSheetRequest,
    ("handoff_sheet", "response"): HandoffSheetResponse,
    ("desk_translate", "request"): DeskTranslateRequest,
    ("desk_translate", "response"): DeskTranslateResponse,
    ("live_token", "request"): LiveTokenRequest,
    ("live_token", "response"): LiveTokenResponse,
    ("demo_error", "response"): DemoErrorBody,
}


def _round_trip(model, data):
    if isinstance(model, type) and issubclass(model, BaseModel):
        return model.model_validate(data).model_dump(mode="json", exclude_unset=True)
    ta = TypeAdapter(model)
    return ta.dump_python(ta.validate_python(data), mode="json")


def test_v1_golden_files_exist():
    assert V1, "contracts/v1/*.json is missing"
    assert {tuple(p.name.split(".")[:2]) for p in V1} == set(V1_MODELS)


@pytest.mark.parametrize("path", V1, ids=[p.name for p in V1])
def test_v1_golden_decodes_and_round_trips(path):
    route, kind = path.name.split(".")[:2]
    data = json.loads(path.read_text(encoding="utf-8"))
    assert _round_trip(V1_MODELS[(route, kind)], data) == data


def test_v1_demo_golden_files_exist():
    assert {tuple(p.name.split(".")[:2]) for p in V1_DEMO} == set(V1_DEMO_MODELS)


@pytest.mark.parametrize("path", V1_DEMO, ids=[p.name for p in V1_DEMO])
def test_v1_demo_golden_decodes_and_round_trips(path):
    route, kind = path.name.split(".")[:2]
    data = json.loads(path.read_text(encoding="utf-8"))
    assert _round_trip(V1_DEMO_MODELS[(route, kind)], data) == data


# ---- Lead's intent golden files ------------------------------------------------------------------------
# Naming is Lead's (Q21 open). A file maps to a model by its name prefix; a file may hold one example, a
# list of examples, or {"examples": [...]}.
INTENT_PREFIXES = [
    ("intent_resolution", IntentResolution), ("resolution", IntentResolution), ("utterance", Utterance),
    ("route_context", RouteContext), ("app_action", AppAction), ("action", AppAction),
    ("destination", Destination), ("grounding", Grounding), ("clarification", Clarification),
    ("ask_request", AskRequest),
]


def _intent_model(path: Path):
    name = path.stem.lower()
    for prefix, model in INTENT_PREFIXES:
        if name.startswith(prefix):
            return model
    return None


def _examples(data):
    if isinstance(data, dict) and isinstance(data.get("examples"), list):
        return data["examples"]
    return data if isinstance(data, list) else [data]


def test_intent_golden_files_present_or_skip():
    if not INTENT:
        pytest.skip("contracts/intent/*.json golden files (Lead) have not landed yet; the decode test runs "
                    "automatically when they do")


@pytest.mark.parametrize("path", INTENT, ids=[p.name for p in INTENT])
def test_intent_golden_decodes_and_round_trips(path):
    raw = json.loads(path.read_text(encoding="utf-8"))
    if path.name == "command_keys.json":
        assert isinstance(raw, dict) and isinstance(raw.get("command_keys"), list)
        assert all(isinstance(key, str) and key for key in raw["command_keys"])
        return
    model = _intent_model(path)
    assert model is not None, (f"{path.name}: no model for this golden file name; add its prefix to "
                               f"INTENT_PREFIXES (known: {[p for p, _ in INTENT_PREFIXES]})")
    # Lead's intent goldens wrap the wire value with human-readable metadata; metadata is
    # deliberately outside the decoded model and must not leak into the wire object.
    payload = raw.get("value") if isinstance(raw, dict) and "value" in raw else raw
    for example in _examples(payload):
        assert _round_trip(model, example) == example, path.name


def test_command_keys_cover_every_leave_app_action_we_emit(command_keys):
    assert command_keys, "contracts/intent/command_keys.json missing or empty"
    keys = json.loads((CONTRACTS / "intent" / "command_keys.json").read_text())["command_keys"]
    assert len(keys) == len(set(keys))
    # The server only emits navigate (no command key: it is the router's own) plus these two.
    assert (SERVER_ACTION_TYPES - {"navigate"}) <= set(keys)
