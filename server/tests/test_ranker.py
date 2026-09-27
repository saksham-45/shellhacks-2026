from __future__ import annotations

import importlib.util
import logging

import pytest

from myad_server.ask.ranker import StubRanker, select_ranker
from myad_server.ask.retrieval import Candidate

try:
    HAS_GOOGLE = (
        importlib.util.find_spec("google.adk") is not None
        and importlib.util.find_spec("google.genai") is not None
    )
except ModuleNotFoundError:
    HAS_GOOGLE = False


def candidates() -> list[Candidate]:
    return [
        Candidate("card-a", 0.8, 0.8, "en"),
        Candidate("card-b", 0.7, 0.7, "en"),
    ]


def test_offline_ranker_never_constructs_gemini(monkeypatch):
    from myad_server.ask import gemini_ranker

    def fail_constructor(*args, **kwargs):
        raise AssertionError("TEST-ONLY Gemini constructor must not run offline")

    monkeypatch.setattr(gemini_ranker.GeminiRanker, "__init__", fail_constructor)
    monkeypatch.setenv("MYAD_OFFLINE", "1")
    monkeypatch.setenv("GEMINI_API_KEY", "TEST-ONLY dummy key")
    from myad_server.settings import Settings
    assert isinstance(select_ranker(offline=Settings.from_env().offline), StubRanker)


def test_select_ranker_returns_stub_without_key(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    assert isinstance(select_ranker(), StubRanker)


@pytest.mark.skipif(not HAS_GOOGLE, reason="optional live extra is not installed")
def test_gemini_ranker_falls_back_to_stub_on_client_error(monkeypatch):
    from myad_server.ask.gemini_ranker import GeminiRanker

    class Models:
        def generate_content(self, **kwargs):
            raise RuntimeError("test-only model failure")

    class Client:
        models = Models()

    monkeypatch.setenv("GEMINI_API_KEY", "test-only-key")
    ranker = GeminiRanker(client=Client())
    assert ranker.rank(candidates(), "test-only utterance").card_id == "card-a"


@pytest.mark.skipif(not HAS_GOOGLE, reason="optional live extra is not installed")
def test_non_candidate_answer_is_rejected(monkeypatch):
    from myad_server.ask.gemini_ranker import GeminiRanker

    class Response:
        text = '"not-a-candidate"'

    class Models:
        def generate_content(self, **kwargs):
            return Response()

    class Client:
        models = Models()

    monkeypatch.setenv("GEMINI_API_KEY", "test-only-key")
    ranker = GeminiRanker(client=Client())
    assert ranker.rank(candidates(), "test-only utterance").card_id == "card-a"


@pytest.mark.skipif(not HAS_GOOGLE, reason="optional live extra is not installed")
def test_enum_schema_is_exactly_candidates_plus_none(monkeypatch):
    from myad_server.ask.gemini_ranker import GeminiRanker

    captured = {}

    class Response:
        text = '"none"'

    class Models:
        def generate_content(self, **kwargs):
            captured.update(kwargs)
            return Response()

    class Client:
        models = Models()

    monkeypatch.setenv("GEMINI_API_KEY", "test-only-key")
    assert GeminiRanker(client=Client()).rank(candidates(), "test-only utterance") is None
    assert captured["config"]["response_schema"]["enum"] == ["card-a", "card-b", "none"]


def test_gemini_fallback_utterance_never_appears_in_logs(caplog):
    from myad_server.ask.gemini_ranker import GeminiRanker

    sentinel = "TEST-ONLY unique ranker sentinel 7c31"

    class Models:
        def generate_content(self, **kwargs):
            raise RuntimeError("TEST-ONLY model failure")

    ranker = object.__new__(GeminiRanker)
    ranker._fallback = StubRanker()
    ranker._api_key = "test-only-key"
    ranker._client = type("Client", (), {"models": Models()})()
    with caplog.at_level(logging.DEBUG):
        result = ranker.rank(candidates(), sentinel)
    assert result.card_id == "card-a"
    assert all(sentinel not in record.getMessage() for record in caplog.records)
