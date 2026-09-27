"""Swappable transports. Fixtures by default; live HTTP only when env MYAD_LIVE=1.

No shared mutable clients: LiveTransport opens a fresh urllib request per call, and the fixture index is
built once and read-only. Error messages never contain the URL, address, or coordinates (ARCHITECTURE.md
§13.z logging rule); the URL travels only in the result's `url` field.
"""
from __future__ import annotations

import json
import os
import socket
import time
import urllib.error
import urllib.request
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Mapping, Protocol

from .types import Raw, Request, now_iso

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
USER_AGENT = "myAmericanDream-regions/0.1 (+public data lookups)"
MAX_TIMEOUT_S = 20.0


class Deadline:
    """A per-call time budget (monotonic). One per call; never shared between calls."""

    def __init__(self, timeout_s: float):
        self.budget = max(0.0, min(float(timeout_s), MAX_TIMEOUT_S))
        self.end = time.monotonic() + self.budget

    def remaining(self) -> float:
        return max(0.0, self.end - time.monotonic())

    def expired(self) -> bool:
        return self.remaining() <= 0.0


class Transport(Protocol):
    live: bool

    def fetch(self, req: Request, deadline: Deadline) -> Raw: ...


def timeout_raw(req: Request) -> Raw:
    return Raw(req, None, b"", now_iso(), error="timed out (call budget spent)", unreachable=True)


@lru_cache(maxsize=4)
def _fixture_index(root: str) -> Mapping[str, tuple[str, str]]:
    """request_url -> (body path, retrieved_at), from every *.meta.json under root."""
    idx: dict[str, tuple[str, str]] = {}
    for meta_path in sorted(Path(root).rglob("*.meta.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        body = meta_path.with_name(meta_path.name[: -len(".meta.json")] + ".json")
        idx[meta["request_url"]] = (str(body), meta["retrieved_at"])
    return MappingProxyType(idx)


class FixtureTransport:
    """Answers only exact request URLs that were saved with their retrieved_at. A missing URL is unavailable."""
    live = False

    def __init__(self, root: Path = FIXTURES):
        self.root = str(root)

    def fetch(self, req: Request, deadline: Deadline) -> Raw:
        if deadline.expired():
            return timeout_raw(req)
        hit = _fixture_index(self.root).get(req.url)
        if hit is None:
            return Raw(req, None, b"", now_iso(), error="no saved response for this request (fixture mode)",
                       unreachable=True)
        body_path, retrieved_at = hit
        return Raw(req, 200, Path(body_path).read_bytes(), retrieved_at)


class LiveTransport:
    """GET with a timeout capped by the call's remaining budget. Used only when MYAD_LIVE=1."""
    live = True

    def fetch(self, req: Request, deadline: Deadline) -> Raw:
        remaining = deadline.remaining()
        if remaining <= 0:
            return timeout_raw(req)
        r = urllib.request.Request(req.url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=min(remaining, MAX_TIMEOUT_S)) as resp:
                body = resp.read()
                return Raw(req, resp.status, body, now_iso())
        except urllib.error.HTTPError as e:
            return Raw(req, e.code, b"", now_iso(), error=f"HTTP {e.code}", unreachable=True)
        except (socket.timeout, TimeoutError):
            return Raw(req, None, b"", now_iso(), error="timed out", unreachable=True)
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            return Raw(req, None, b"", now_iso(), error=f"unreachable ({type(reason).__name__})", unreachable=True)


def default_transport() -> Transport:
    """Read per call (no module state): live only when MYAD_LIVE=1."""
    return LiveTransport() if os.environ.get("MYAD_LIVE") == "1" else FixtureTransport()
