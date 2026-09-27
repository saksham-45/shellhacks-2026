"""Shared helpers for the demo endpoint tests (TEST-ONLY fixtures under fixtures/demo; offline)."""
from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from fastapi.testclient import TestClient

from datetime import datetime, timedelta, timezone

NOW = datetime(2026, 9, 25, 17, 0, tzinfo=timezone(timedelta(hours=-4)))  # same instant as conftest.NOW

DEMO = Path(__file__).resolve().parent / "fixtures" / "demo"


def demo_ledger():
    from myad_server.ledger import load_ledger

    return load_ledger(DEMO / "research" / "facts", DEMO / "research" / "sources.yaml")


def demo_catalog():
    from myad_server.demo.fee_catalog import FeeCatalog

    return FeeCatalog.from_manifests(DEMO / "packs")


def make_client(make_harness, *, ledger=None, catalog=None, **services: Any) -> TestClient:
    from myad_server.app import create_app
    from myad_server.demo.services import DemoServices

    led = demo_ledger() if ledger is None else ledger
    cat = demo_catalog() if catalog is None else catalog

    def factory(_h):
        return DemoServices(ledger=led, catalog=cat, now=lambda: NOW, **services)

    return TestClient(create_app(make_harness, demo_factory=factory))


class FakeInteractions:
    """Records every create() call; returns `output_text` (or raises)."""

    def __init__(self, output: Any = None, exc: Exception | None = None):
        self.output, self.exc, self.calls = output, exc, []

    def create(self, **kwargs: Any) -> Any:
        self.calls.append(kwargs)
        if self.exc is not None:
            raise self.exc
        text = self.output if isinstance(self.output, str) or self.output is None else json.dumps(self.output)
        return SimpleNamespace(output_text=text)


class FakeAuthTokens:
    def __init__(self, name: str = "auth_tokens/TEST-ONLY-ephemeral", exc: Exception | None = None):
        self.name, self.exc, self.calls = name, exc, []

    def create(self, *, config: dict[str, Any]) -> Any:
        self.calls.append(config)
        if self.exc is not None:
            raise self.exc
        return SimpleNamespace(name=self.name)


class FakeGenaiClient:
    def __init__(self, output: Any = None, exc: Exception | None = None, token_exc: Exception | None = None):
        self.interactions = FakeInteractions(output, exc)
        self.auth_tokens = FakeAuthTokens(exc=token_exc)


def go_live(monkeypatch, fake: FakeGenaiClient, key: str = "TEST-ONLY-NOT-A-KEY") -> list[tuple]:
    """Pretend a key exists and the network is allowed; every client is the fake. Returns build calls."""
    from myad_server.demo import genai as G

    calls: list[tuple] = []

    def build(*args):
        calls.append(args)
        return fake

    monkeypatch.setenv("GEMINI_API_KEY", key)
    monkeypatch.setenv("MYAD_OFFLINE", "0")
    monkeypatch.setattr(G, "build_client", build)
    return calls
