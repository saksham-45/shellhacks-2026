"""Shared test setup (myAD Agents). Offline and keyless by construction:
- model keys are removed from the environment and MYAD_OFFLINE=1 is set before anything is imported;
- every non-UNIX socket connect / DNS lookup raises, so a test that tries the network fails loudly;
- fixtures load only the FAKE data under tests/fixtures (never research/ or regionpacks/).
"""
from __future__ import annotations

import os
import socket
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

for _key in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_CLOUD_PROJECT"):
    os.environ.pop(_key, None)
os.environ["MYAD_OFFLINE"] = "1"
os.environ["MYAD_LIVE"] = "0"


class NetworkBlocked(RuntimeError):
    pass


_real_connect = socket.socket.connect
_real_connect_ex = socket.socket.connect_ex


def _guard(sock: socket.socket) -> None:
    if sock.family != getattr(socket, "AF_UNIX", object()):
        raise NetworkBlocked("network access is blocked in server tests")


def _connect(self, address):  # type: ignore[no-untyped-def]
    _guard(self)
    return _real_connect(self, address)


def _connect_ex(self, address):  # type: ignore[no-untyped-def]
    _guard(self)
    return _real_connect_ex(self, address)


def _no_dns(*args, **kwargs):  # type: ignore[no-untyped-def]
    raise NetworkBlocked("DNS lookups are blocked in server tests")


socket.socket.connect = _connect  # type: ignore[method-assign]
socket.socket.connect_ex = _connect_ex  # type: ignore[method-assign]
socket.create_connection = lambda *a, **k: _no_dns()  # type: ignore[assignment]
socket.getaddrinfo = _no_dns  # type: ignore[assignment]

FIXTURES = Path(__file__).resolve().parent / "fixtures"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 9, 25, 17, 0, tzinfo=timezone(timedelta(hours=-4)))


@pytest.fixture(scope="session")
def topics():
    from myad_server.topics import load_topics

    return load_topics(FIXTURES / "research" / "topics.yaml")


@pytest.fixture(scope="session")
def ledger(topics):
    from myad_server.ledger import load_ledger

    return load_ledger(FIXTURES / "research" / "facts", FIXTURES / "research" / "sources.yaml", topics)


@pytest.fixture(scope="session")
def bundle(topics):
    from myad_server.cards import load_bundle

    return load_bundle(FIXTURES / "cards.json", topics)


@pytest.fixture(scope="session")
def command_keys():
    from myad_server.harness import load_command_keys

    return load_command_keys(PROJECT_ROOT / "contracts" / "intent" / "command_keys.json")


@pytest.fixture
def make_harness(bundle, ledger, topics, command_keys):
    from myad_server.ask.chooser import RetrievalChooser
    from myad_server.harness import Harness

    def build(chooser=None):
        return Harness.build(bundle=bundle, ledger=ledger, chooser=chooser or RetrievalChooser(),
                             command_keys=command_keys or frozenset({"call_desk", "open_map"}), topics=topics,
                             now=lambda: NOW)

    return build
