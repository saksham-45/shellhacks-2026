"""Start-up and network rules (REVIEW r3 B2, M10).

B2: MYAD_OFFLINE=1 wins over MYAD_LIVE=1. The Regions runtime here is a TEST-ONLY stand-in with the real
runtime's signature (answer/resolve with an optional `transport`, default transport chosen from MYAD_LIVE
per call, exactly like regionpacks/runtime.py); the real regionpacks code is never imported. Its "live"
transport calls socket.create_connection, which the tests replace with a recorder that raises.

M10: a broken ledger aborts start-up with a clear error, testable through the create_app factory.
"""
from __future__ import annotations

import shutil
import socket
import sys
import textwrap
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from myad_server.app import create_app
from myad_server.harness import FixtureOnlyRuntime, Harness, HarnessStartupError, build_runtime, harness_factory
from myad_server.settings import Settings

from conftest import FIXTURES, PROJECT_ROOT

FID = "us-fl-miamidade.test.trash-days"
PIN = {"address": "1 TEST-ONLY Way, Fictiontown", "lat": 25.0, "lon": -80.0}

_FAKE_TRANSPORT = '''
"""TEST-ONLY stand-in for Regions' transport module (same class names and `live` flags)."""
import socket


class FixtureTransport:
    live = False

    def fetch(self, what):
        return "fixture:" + what


class LiveTransport:
    live = True

    def fetch(self, what):
        socket.create_connection(("regions.example.invalid", 443), timeout=1)
        return "live:" + what
'''

_FAKE_RUNTIME = '''
"""TEST-ONLY stand-in for regionpacks/runtime.py: same entry points, same MYAD_LIVE rule."""
import os

from myad_regions.transport import FixtureTransport, LiveTransport

FID = "us-fl-miamidade.test.trash-days"
SCHOOL = "us-fl-miamidade.test.school"


def _default_transport():
    return LiveTransport() if os.environ.get("MYAD_LIVE") == "1" else FixtureTransport()


def resolve(pin, timeout_s=20.0, transport=None):
    (transport or _default_transport()).fetch("county-locator")
    return ["us", "us-fl", "us-fl-miamidade"]


def answer(pin, fact_ids=None, topics=None, timeout_s=20.0, transport=None):
    t = transport or _default_transport()
    try:
        t.fetch("county-locator")
    except OSError:
        return [{"fact_id": f, "ledger_id": f, "pack": "us-fl-miamidade", "status": "unavailable",
                 "is_demo": False, "desk": "us-fl-miamidade.test-desk", "jurisdiction": "us-fl-miamidade"}
                for f in (fact_ids or [])]
    base = {"pack": "us-fl-miamidade", "status": "ok", "is_demo": True, "fact_status": "demo",
            "source_id": "us-fl-miamidade.test-source", "url": "https://example.invalid/test-only",
            "retrieved_at": "2026-09-25T12:00:00-04:00", "quote": "TEST-ONLY fictional adapter result.",
            "jurisdiction": "us-fl-miamidade", "desk": "us-fl-miamidade.test-desk"}
    rows = {FID: dict(base, fact_id=FID, ledger_id=FID + ".demo.pin-test1",
                      value={"type": "weekdays", "days": ["tuesday", "friday"]})}
    return [rows[f] for f in (fact_ids or []) if f in rows]
'''


@pytest.fixture
def fake_root(tmp_path):
    """A TEST-ONLY project root: fixture research + cards, and a fake regionpacks runtime."""
    shutil.copytree(FIXTURES / "research", tmp_path / "research")
    shutil.copy(FIXTURES / "cards.json", tmp_path / "cards.json")
    packs = tmp_path / "server" / "regionpacks"
    (packs / "myad_regions").mkdir(parents=True)
    (packs / "myad_regions" / "__init__.py").write_text("")
    (packs / "myad_regions" / "transport.py").write_text(textwrap.dedent(_FAKE_TRANSPORT))
    (packs / "runtime.py").write_text(textwrap.dedent(_FAKE_RUNTIME))

    def ours(name: str) -> bool:
        return name in ("myad_regions", "myad_regions_runtime") or name.startswith("myad_regions.")

    # Another test may have imported Regions' real package under the same name: set it aside so the
    # fake is what load_runtime and the fixture-transport import see, then put everything back.
    saved_path = list(sys.path)
    saved_modules = {name: mod for name, mod in sys.modules.items() if ours(name)}
    for name in saved_modules:
        del sys.modules[name]
    yield tmp_path
    sys.path[:] = saved_path
    for name in [m for m in sys.modules if ours(m)]:
        del sys.modules[name]
    sys.modules.update(saved_modules)


def _env(root: Path, **extra) -> dict[str, str]:
    return {"MYAD_ROOT": str(root), "MYAD_CARDS_BUNDLE": str(root / "cards.json"), **extra}


@pytest.fixture
def attempts(monkeypatch):
    seen: list = []

    def record(address, *args, **kwargs):
        seen.append(address)
        raise OSError("TEST-ONLY: network blocked")

    monkeypatch.setattr(socket, "create_connection", record)
    return seen


def test_offline_wins_over_live_on_every_route(fake_root, attempts, monkeypatch):
    monkeypatch.setenv("MYAD_LIVE", "1")                 # what Regions itself reads per call
    monkeypatch.setenv("MYAD_OFFLINE", "1")
    monkeypatch.setenv("GEMINI_API_KEY", "TEST-ONLY-not-a-key")
    env = _env(fake_root, MYAD_OFFLINE="1", MYAD_LIVE="1", GEMINI_API_KEY="TEST-ONLY-not-a-key")
    settings = Settings.from_env(env)
    assert settings.offline and settings.live and not settings.regions_live
    h = Harness.from_settings(settings)
    assert isinstance(h.runtime, FixtureOnlyRuntime)
    with TestClient(create_app(lambda: h)) as c:
        week = c.post("/v1/household-week", json={"pin": PIN, "surface_language": "en", "mode": "resident"})
        person = c.post("/v1/person-next-steps", json={
            "person": {"person_id": "p-test-only", "stage": 7, "mode": "resident", "goal": "study"},
            "pin": PIN, "surface_language": "en"})
        ask = c.post("/v1/ask", json={"utterance": {"text": "when is trash day", "language": "en"},
                                      "mode": "resident"})
    assert (week.status_code, person.status_code, ask.status_code) == (200, 200, 200)
    assert attempts == [], f"MYAD_OFFLINE=1 but the server tried to connect to {attempts}"
    # The address lookup still ran, on fixtures: the demo trash day came back and was labelled demo.
    body = week.json()
    assert body["facts"][FID]["type"] == "fact" and body["has_demo"] is True


def test_control_live_without_offline_does_reach_the_live_transport(fake_root, attempts, monkeypatch):
    # Proves the recorder can see an attempt: with MYAD_OFFLINE unset, MYAD_LIVE=1 is honoured.
    monkeypatch.setenv("MYAD_LIVE", "1")
    monkeypatch.delenv("MYAD_OFFLINE", raising=False)
    h = Harness.from_settings(Settings.from_env(_env(fake_root, MYAD_LIVE="1")))
    assert not isinstance(h.runtime, FixtureOnlyRuntime)
    with TestClient(create_app(lambda: h)) as c:
        r = c.post("/v1/household-week", json={"pin": PIN, "surface_language": "en", "mode": "resident"})
    assert r.status_code == 200
    assert attempts, "control: the live transport should have been tried"
    assert r.json()["facts"][FID]["type"] == "unavailable"


def test_offline_without_a_fixture_transport_builds_no_address_lookup(tmp_path):
    class NoTransportParam:  # a runtime whose fixture mode cannot be forced
        @staticmethod
        def answer(pin, fact_ids=None, topics=None, timeout_s=20.0):
            raise AssertionError("must never be called offline")

        @staticmethod
        def resolve(pin):
            raise AssertionError("must never be called offline")

    settings = Settings.from_env({"MYAD_ROOT": str(tmp_path), "MYAD_OFFLINE": "1", "MYAD_LIVE": "1"})
    assert build_runtime(settings, loader=lambda _dir: NoTransportParam()) is None


def test_fixture_only_runtime_refuses_a_live_transport():
    class Live:
        live = True

    rt = FixtureOnlyRuntime(object(), Live)
    with pytest.raises(RuntimeError):
        rt.answer({"address": "TEST-ONLY"})


# ---- M10 --------------------------------------------------------------------------------------------------


def test_broken_ledger_aborts_startup_through_the_factory(fake_root):
    (fake_root / "research" / "facts" / "test.json").write_text('[{"id": "BROKEN"}]')
    app = create_app(harness_factory(_env(fake_root, MYAD_OFFLINE="1")))
    with pytest.raises(HarnessStartupError) as err:
        with TestClient(app):
            pass
    message = str(err.value)
    assert "ledger" in message and str(fake_root / "research" / "facts") in message
    assert "BROKEN" in message or "status" in message


def test_missing_ledger_folder_aborts_startup(tmp_path):
    shutil.copy(FIXTURES / "cards.json", tmp_path / "cards.json")
    with pytest.raises(HarnessStartupError, match="no ledger fact files"):
        Harness.from_settings(Settings.from_env(_env(tmp_path, MYAD_OFFLINE="1")))


def test_broken_bundle_aborts_startup(fake_root):
    (fake_root / "cards.json").write_text('{"version": 1, "cards": [{"id": "x"}]}')
    with pytest.raises(HarnessStartupError, match="card bundle"):
        Harness.from_settings(Settings.from_env(_env(fake_root, MYAD_OFFLINE="1")))


def test_unloadable_optional_runtime_does_not_abort_startup(fake_root):
    (fake_root / "server" / "regionpacks" / "runtime.py").write_text("raise ImportError('TEST-ONLY')\n")
    h = Harness.from_settings(Settings.from_env(_env(fake_root, MYAD_OFFLINE="1")))
    assert h.runtime is None


def test_real_project_starts_offline_with_fixture_regions():
    # The shipped ledger, bundle and policy must pass start-up validation (no regionpacks import here).
    h = Harness.from_settings(Settings.from_env({"MYAD_ROOT": str(PROJECT_ROOT), "MYAD_OFFLINE": "1"}),
                              runtime_loader=lambda _dir: None)
    assert h.deps.ledger.facts and h.runtime is None
