from fastapi.testclient import TestClient

from myad_server.app import app

client = TestClient(app)
PIN = {"address": "0 Example Way, Exampletown (TEST FIXTURE)", "lat": 0.0, "lon": 0.0}


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_household_week_endpoint_is_typed():
    body = {"pin": PIN, "surface_language": "es", "mode": "resident"}
    r = client.post("/v1/household-week", json=body)
    assert r.status_code == 200
    assert {"request_id", "language", "facts", "handoffs", "has_demo", "dropped_claims", "pack_ids", "items"} <= set(r.json())


def test_person_next_steps_endpoint_is_typed():
    body = {
        "person": {"person_id": "p1", "stage": 8, "mode": "resident", "goal": "study"},
        "surface_language": "en",
    }
    response = client.post("/v1/person-next-steps", json=body)
    assert response.status_code == 200
    assert {"request_id", "language", "facts", "handoffs", "has_demo", "dropped_claims", "person_id", "steps", "origin_comparison"} == set(response.json())


def test_ask_resolves_instead_of_returning_stub():
    body = {"utterance": {"text": "¿y el peaje?", "language": "es"}, "stage": 1, "mode": "resident"}
    r = client.post("/v1/ask", json=body)
    assert r.status_code == 200
    assert set(r.json()) == {"action", "grounding", "confidence", "clarification", "reply_language"}


def test_request_validation_still_runs():
    assert client.post("/v1/ask", json={"text": "x"}).status_code == 422
