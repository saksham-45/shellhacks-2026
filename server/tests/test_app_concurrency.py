from __future__ import annotations

import asyncio
import sys
import time
from types import SimpleNamespace

import httpx

from myad_server.app import create_app, main


class SlowRanker:
    def __init__(self):
        self.calls = 0

    def rank(self, candidates, utterance=None):
        self.calls += 1
        time.sleep(1.0)
        return candidates[0] if candidates else None


def test_concurrent_ask_requests_do_not_block_on_sync_ranker(make_harness):
    harness = make_harness()
    slow_ranker = SlowRanker()
    harness.ranker = slow_ranker
    app = create_app(harness_factory=lambda: harness)
    body = {
        "utterance": {"text": "when is trash day", "language": "en"},
        "stage": 1,
        "mode": "resident",
    }

    async def run_requests():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            started = time.perf_counter()
            responses = await asyncio.gather(
                client.post("/v1/ask", json=body),
                client.post("/v1/ask", json=body),
            )
            elapsed = time.perf_counter() - started
        return responses, elapsed

    responses, elapsed = asyncio.run(run_requests())
    assert elapsed < 1.8
    assert slow_ranker.calls == 2
    assert [response.status_code for response in responses] == [200, 200]


def test_main_disables_uvicorn_access_log(monkeypatch):
    calls = []
    monkeypatch.setitem(sys.modules, "uvicorn", SimpleNamespace(run=lambda *args, **kwargs: calls.append((args, kwargs))))

    main()

    assert calls == [(
        ("myad_server.app:app",),
        {"host": "0.0.0.0", "port": 8080, "access_log": False},
    )]
