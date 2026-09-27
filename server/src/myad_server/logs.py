"""Logging policy (ARCHITECTURE.md §13.z): log ONLY request_id, route, status, latency and counts. Never
utterance text, addresses, coordinates, or request/response bodies. Third-party loggers that can print
model requests or responses are silenced."""
from __future__ import annotations

import logging

ACCESS = logging.getLogger("myad.access")
_QUIET = ("google_adk", "google.adk", "google_genai", "google.genai", "httpx", "httpcore", "a2a")


def configure_logging() -> None:
    for name in _QUIET:
        logging.getLogger(name).setLevel(logging.CRITICAL + 1)


def log_request(request_id: str, route: str, status: int, latency_ms: float, counts: dict[str, int]) -> None:
    safe_counts = {str(k): int(v) for k, v in counts.items() if isinstance(v, (int, bool))}
    ACCESS.info("request_id=%s route=%s status=%d latency_ms=%.1f counts=%s", request_id, route, status,
                latency_ms, ",".join(f"{k}:{v}" for k, v in sorted(safe_counts.items())))
