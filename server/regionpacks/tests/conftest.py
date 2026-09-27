import os
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from myad_regions.pins import DEMO_PINS  # noqa: E402
from myad_regions.transport import FixtureTransport  # noqa: E402

LIVE = os.environ.get("MYAD_LIVE") == "1"


@pytest.fixture(autouse=True)
def _offline_by_default(monkeypatch):
    """Default tests never touch the network, whatever the caller's environment says."""
    if not LIVE:
        monkeypatch.delenv("MYAD_LIVE", raising=False)


@pytest.fixture(scope="session")
def fx():
    return FixtureTransport()


@pytest.fixture(scope="session")
def pin_a():
    return DEMO_PINS["pin-sw137"]


@pytest.fixture(scope="session")
def pin_b():
    return DEMO_PINS["pin-nw1st"]


@pytest.fixture(scope="session")
def answers(fx):
    import runtime
    return {pid: {r["fact_id"]: r for r in runtime.answer(p, transport=fx)} for pid, p in DEMO_PINS.items()}
