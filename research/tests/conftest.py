"""Test setup: import path, markers, and a tiny replay-fixture builder. Unit tests never touch the network."""
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]  # directory that contains research/
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def pytest_addoption(parser):
    parser.addoption("--run-live", action="store_true", default=False, help="run tests marked live (network)")


def pytest_configure(config):
    config.addinivalue_line("markers", "live: hits real endpoints; needs --run-live")


def pytest_collection_modifyitems(config, items):
    if config.getoption("--run-live"):
        return
    skip = pytest.mark.skip(reason="live test: pass --run-live")
    for item in items:
        if "live" in item.keywords:
            item.add_marker(skip)


@pytest.fixture(autouse=True)
def _no_network(request, monkeypatch):
    if "live" not in request.keywords:
        monkeypatch.setenv("MYAD_NO_NETWORK", "1")


def make_replay(dirpath: Path, responses: dict[str, dict]) -> Path:
    """responses: {"GET <url>": {"status": 200, "body": bytes|str|dict, "content_type": ..., "final_url": ...}}"""
    (dirpath / "bodies").mkdir(parents=True, exist_ok=True)
    index = {}
    for key, spec in responses.items():
        body = spec.get("body", b"")
        ctype = spec.get("content_type")
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
            ctype = ctype or "application/json"
        elif isinstance(body, str):
            body = body.encode()
        name = hashlib.sha1(key.encode()).hexdigest()[:16] + ".bin"
        (dirpath / "bodies" / name).write_bytes(body)
        index[key] = {"status": spec.get("status", 200), "headers": {"content-type": ctype or "text/html"},
                      "final_url": spec.get("final_url") or key.split(" ", 1)[1], "redirects": spec.get("redirects", []),
                      "body": name, "error": spec.get("error"), "retrieved_at": "2026-09-25T17:00:00-04:00"}
    (dirpath / "index.json").write_text(json.dumps(index, indent=1))
    return dirpath


@pytest.fixture
def replay_builder(tmp_path):
    return lambda responses: make_replay(tmp_path / "http", responses)
