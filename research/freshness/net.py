"""The one HTTP client for research/: polite, retrying, logged, and replayable in tests.

Replay/record format (a directory):
  index.json = {"<METHOD> <url>": {"status": int, "headers": {...}, "final_url": str,
                                   "redirects": [str], "body": "<file name>"}}
  bodies/<file name> = raw bytes
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import random
import re
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import httpx

DEFAULT_UA = (
    "myAmericanDream-research/0.1 (+https://github.com/saksham-45/shellhacks-2026; "
    "freshness and region onboarding; polite, low volume)"
)

WAF_MARKERS = ("Request Rejected", "The requested URL was rejected")


class NetworkDisabled(RuntimeError):
    """Raised in replay mode when a request has no recorded fixture."""


class BudgetExceeded(RuntimeError):
    pass


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


SECRET_PARAMS = re.compile(r"([?&](?:key|api_key|apikey|token|access_token|app_token)=)[^&#]*", re.I)


def redact(url: str) -> str:
    """Never let a key from the environment reach a log, fixture, report, or finding."""
    return SECRET_PARAMS.sub(r"\1REDACTED", url)


def request_key(method: str, url: str, params: dict[str, Any] | None = None) -> str:
    u = httpx.URL(url, params=params) if params else httpx.URL(url)
    return f"{method.upper()} {u}"


@dataclass
class Fetched:
    url: str
    final_url: str
    status: int | None
    content: bytes = b""
    headers: dict[str, str] = field(default_factory=dict)
    redirects: list[str] = field(default_factory=list)
    error: str | None = None
    elapsed_ms: int = 0
    retrieved_at: str = field(default_factory=now_iso)

    @property
    def ok(self) -> bool:
        return self.error is None and self.status is not None and 200 <= self.status < 300

    @property
    def content_type(self) -> str:
        return self.headers.get("content-type", "").lower()

    @property
    def text(self) -> str:
        return self.content.decode("utf-8", errors="replace")

    def json(self) -> Any:
        return json.loads(self.content.decode("utf-8", errors="replace"))

    @property
    def moved(self) -> bool:
        return is_meaningful_move(self.url, self.final_url)

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.content).hexdigest()


def _norm_for_move(url: str) -> str:
    p = urlsplit(url)
    host = p.netloc.lower()
    path = p.path.rstrip("/") or "/"
    return f"{host}{path}?{p.query}"


def is_meaningful_move(original: str, final: str) -> bool:
    """A redirect counts as a move unless it only adds https or a trailing slash."""
    if not final or original == final:
        return False
    return _norm_for_move(original) != _norm_for_move(final)


def looks_like_waf_block(content: bytes, content_type: str) -> bool:
    if "html" not in content_type and not content[:200].lstrip().startswith(b"<"):
        return False
    head = content[:4000].decode("utf-8", errors="replace")
    return any(m in head for m in WAF_MARKERS) and len(content) < 4000


class Fetcher:
    def __init__(
        self,
        *,
        user_agent: str = DEFAULT_UA,
        timeout: float = 20.0,
        retries: int = 3,
        backoff: float = 1.0,
        min_interval: float = 1.0,
        budget: int | None = None,
        replay_dir: str | os.PathLike | None = None,
        record_dir: str | os.PathLike | None = None,
        max_bytes: int = 60_000_000,
        reuse_recorded: bool = False,
    ) -> None:
        self.reuse_recorded = reuse_recorded
        self.user_agent = user_agent
        self.timeout = timeout
        self.retries = retries
        self.backoff = backoff
        self.min_interval = min_interval
        self.budget = budget
        self.max_bytes = max_bytes
        self.replay_dir = Path(replay_dir) if replay_dir else None
        self.record_dir = Path(record_dir) if record_dir else None
        self.log: list[dict[str, Any]] = []
        self._count = 0
        self._last_hit: dict[str, float] = {}
        self._lock = threading.Lock()
        self._index: dict[str, Any] = {}
        if self.replay_dir:
            idx = self.replay_dir / "index.json"
            self._index = json.loads(idx.read_text()) if idx.exists() else {}
        if self.record_dir:
            (self.record_dir / "bodies").mkdir(parents=True, exist_ok=True)
            idx = self.record_dir / "index.json"
            self._rec_index = json.loads(idx.read_text()) if idx.exists() else {}
        self._client: httpx.Client | None = None

    # -- public ---------------------------------------------------------
    def get(self, url: str, params: dict[str, Any] | None = None, *, max_bytes: int | None = None,
            retries: int | None = None) -> Fetched:
        return self._request("GET", url, params, max_bytes=max_bytes, retries=retries)

    def head(self, url: str) -> Fetched:
        return self._request("HEAD", url, None)

    def close(self) -> None:
        if self._client is not None:
            self._client.close()
            self._client = None

    def __enter__(self) -> "Fetcher":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- internals ------------------------------------------------------
    def _client_obj(self) -> httpx.Client:
        if self._client is None:
            self._client = httpx.Client(
                headers={"User-Agent": self.user_agent, "Accept": "*/*"},
                timeout=self.timeout,
                follow_redirects=True,
            )
        return self._client

    def _space(self, url: str) -> None:
        host = urlsplit(url).netloc
        with self._lock:
            last = self._last_hit.get(host, 0.0)
            wait = self.min_interval - (time.monotonic() - last)
            if wait > 0:
                time.sleep(wait)
            self._last_hit[host] = time.monotonic()

    def _request(self, method: str, url: str, params: dict[str, Any] | None, *, max_bytes: int | None = None,
                 retries: int | None = None) -> Fetched:
        full_url = request_key(method, url, params).split(" ", 1)[1]
        key = redact(request_key(method, url, params))
        if self.replay_dir is not None:
            return self._replay(key, full_url)
        if self.reuse_recorded and self.record_dir is not None and key in self._rec_index:
            saved, self.replay_dir, self._index = (self.replay_dir, self._index), self.record_dir, self._rec_index
            try:
                return self._replay(key, full_url)
            finally:
                self.replay_dir, self._index = saved
        if os.environ.get("MYAD_NO_NETWORK") == "1":
            raise NetworkDisabled(f"network disabled (MYAD_NO_NETWORK=1): {key}")
        if self.budget is not None and self._count >= self.budget:
            raise BudgetExceeded(f"request budget {self.budget} exhausted at {key}")
        self._count += 1
        limit = max_bytes or self.max_bytes
        attempt = 0
        result: Fetched
        while True:
            attempt += 1
            self._space(full_url)
            t0 = time.monotonic()
            try:
                with self._client_obj().stream(method, full_url) as r:
                    chunks, total, truncated = [], 0, False
                    if method != "HEAD":
                        for chunk in r.iter_bytes():
                            chunks.append(chunk)
                            total += len(chunk)
                            if total >= limit:
                                truncated = True
                                break
                    body = b"".join(chunks)
                    headers = {k.lower(): v for k, v in r.headers.items()}
                    if truncated:
                        headers["x-myad-truncated"] = str(limit)
                    result = Fetched(
                        url=full_url,
                        final_url=str(r.url),
                        status=r.status_code,
                        content=body,
                        headers=headers,
                        redirects=[str(h.url) for h in r.history],
                        elapsed_ms=int((time.monotonic() - t0) * 1000),
                    )
            except (httpx.TimeoutException, httpx.TransportError) as e:
                result = Fetched(url=full_url, final_url=full_url, status=None,
                                 error=f"{type(e).__name__}: {e}",
                                 elapsed_ms=int((time.monotonic() - t0) * 1000))
            retryable = result.status is None or result.status in (429, 500, 502, 503, 504)
            if retryable and attempt < (retries or self.retries):
                delay = self.backoff * (2 ** (attempt - 1)) + random.uniform(0, 0.25)
                ra = result.headers.get("retry-after")
                if ra and ra.isdigit():
                    delay = max(delay, min(int(ra), 60))
                time.sleep(delay)
                continue
            break
        if result.error is None and looks_like_waf_block(result.content, result.content_type):
            result.error = "blocked: the host returned a firewall 'Request Rejected' page"
        if result.error is None and result.status is not None and result.status >= 400:
            result.error = f"HTTP {result.status}"
        result.url, result.final_url = redact(result.url), redact(result.final_url)
        result.redirects = [redact(u) for u in result.redirects]
        self._log(method, result, attempt)
        if self.record_dir is not None:
            self._record(key, result)
        return result

    def _log(self, method: str, r: Fetched, attempts: int) -> None:
        self.log.append({
            "method": method, "url": r.url, "final_url": r.final_url, "status": r.status,
            "bytes": len(r.content), "error": r.error, "attempts": attempts,
            "elapsed_ms": r.elapsed_ms, "retrieved_at": r.retrieved_at,
            "sha256": r.sha256 if r.content else None,
        })

    def _replay(self, key: str, full_url: str) -> Fetched:
        full_url = redact(full_url)
        entry = self._index.get(key)
        if entry is None:
            raise NetworkDisabled(f"no recorded fixture for {key}")
        body = b""
        if entry.get("body"):
            body = (self.replay_dir / "bodies" / entry["body"]).read_bytes()
        r = Fetched(url=full_url, final_url=entry.get("final_url") or full_url,
                    status=entry.get("status"), content=body,
                    headers={k.lower(): v for k, v in (entry.get("headers") or {}).items()},
                    redirects=entry.get("redirects") or [], error=entry.get("error"),
                    retrieved_at=entry.get("retrieved_at") or now_iso())
        if r.error is None and looks_like_waf_block(r.content, r.content_type):
            r.error = "blocked: the host returned a firewall 'Request Rejected' page"
        if r.error is None and r.status is not None and r.status >= 400:
            r.error = f"HTTP {r.status}"
        self._log(key.split(" ", 1)[0], r, 1)
        return r

    def _record(self, key: str, r: Fetched) -> None:
        name = hashlib.sha1(key.encode()).hexdigest()[:16] + ".bin"
        (self.record_dir / "bodies" / name).write_bytes(r.content)
        keep = {k: v for k, v in r.headers.items() if k in ("content-type", "x-myad-truncated", "content-length", "last-modified", "etag")}
        self._rec_index[key] = {"status": r.status, "headers": keep, "final_url": r.final_url,
                                "redirects": r.redirects, "body": name, "error": r.error,
                                "retrieved_at": r.retrieved_at}
        (self.record_dir / "index.json").write_text(json.dumps(self._rec_index, indent=1, sort_keys=True))
