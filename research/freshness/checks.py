"""Per-source checks, one checker per extraction method, plus the lookup checker."""
from __future__ import annotations

import datetime as dt
import hashlib
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Literal

from .ledger import Fact, Ledger
from .net import Fetched, Fetcher, now_iso
from .pins import GeocodeFailed, Pin, resolve_pin
from .schedule import is_due
from .state import State
from .text import normalize, find_quote, to_text
from .values import find_value, pick, values_equal

# value-changed = content drifted (the number/text moved); quote-missing = the quoted sentence is gone (reworded,
# moved, or removed); schema-drift = a lookup layer/API changed shape; source-unreachable = transient, retried next run.
Outcome = Literal["unchanged", "value-changed", "quote-missing", "schema-drift", "source-unreachable", "moved", "skipped"]
DRIFT = ("value-changed", "quote-missing", "schema-drift")
SEVERITY = {"source-unreachable": 5, "value-changed": 4, "quote-missing": 4, "schema-drift": 4, "moved": 3, "unchanged": 1, "skipped": 0}
DEFAULT_UNREACHABLE_THRESHOLD = 3
_NUMS = re.compile(r"\$?\d[\d,]*(?:\.\d+)?%?")
CHECKABLE_STATUSES = {"verified", "stale"}
# project sources.yaml `kind` -> extraction method (an explicit `extraction` key wins)
KIND_TO_EXTRACTION = {"html": "html-quote", "pdf": "pdf-quote", "gis-layer": "arcgis-query", "api": "api-json",
                      "dataset": "api-json", "gtfs": "download"}


def extraction_of(source: dict[str, Any]) -> str:
    return source.get("extraction") or KIND_TO_EXTRACTION.get(str(source.get("kind", "")).lower(), "manual")


@dataclass
class FactResult:
    fact_id: str
    source_id: str | None
    kind: str
    status_before: str
    outcome: Outcome
    detail: str
    snippet: str | None = None
    similarity: float | None = None
    observed: Any = None
    recorded: Any = None
    checked_url: str | None = None
    final_url: str | None = None
    consecutive_unreachable: int = 0
    propose_stale: bool = False


@dataclass
class SourceResult:
    source_id: str
    url: str
    extraction: str
    final_url: str | None = None
    http_status: int | None = None
    error: str | None = None
    content_sha256: str | None = None
    content_sha256_text: str | None = None
    content_changed: bool | None = None
    moved: bool = False
    facts: list[FactResult] = field(default_factory=list)
    checked_at: str = field(default_factory=now_iso)

    @property
    def outcome(self) -> str:
        if self.error and not any(f.outcome != "source-unreachable" for f in self.facts if f.outcome != "skipped"):
            return "source-unreachable"
        worst = max((f.outcome for f in self.facts), key=lambda o: SEVERITY[o], default="unchanged")
        if worst in ("unchanged", "skipped") and self.moved:
            return "moved"
        return worst if worst != "skipped" else "unchanged"


@dataclass
class Context:
    fetcher: Fetcher
    state: State
    cache_dir: Path
    pins: list[dict[str, Any]]
    unreachable_threshold: int = DEFAULT_UNREACHABLE_THRESHOLD
    now: dt.datetime = field(default_factory=lambda: dt.datetime.now(dt.timezone.utc))
    _pages: dict[str, Fetched] = field(default_factory=dict)
    _texts: dict[str, str] = field(default_factory=dict)
    _pin: Pin | None = None
    _pin_error: str | None = None

    def fetch(self, url: str, params: dict[str, Any] | None = None) -> Fetched:
        key = url + ("?" + repr(sorted(params.items())) if params else "")
        if key not in self._pages:
            self._pages[key] = self.fetcher.get(url, params)
        return self._pages[key]

    def text_of(self, r: Fetched, hint: str | None) -> str:
        if r.url not in self._texts:
            self._texts[r.url] = to_text(r.content, r.content_type, hint)
        return self._texts[r.url]

    def pin(self, pin_id: str | None = None) -> Pin | None:
        if pin_id is None and self._pin is not None:
            return self._pin
        choices = [p for p in self.pins if (p["id"] == pin_id if pin_id else p.get("default"))] or self.pins[:1]
        if not choices:
            self._pin_error = "no pins configured"
            return None
        try:
            p = resolve_pin(choices[0], self.fetcher, self.state, now=self.now)
        except GeocodeFailed as e:
            self._pin_error = str(e)
            return None
        if pin_id is None:
            self._pin = p
        return p


# --------------------------------------------------------------------------- helpers

def _fr(f: Fact, sid: str | None, outcome: Outcome, detail: str, **kw: Any) -> FactResult:
    return FactResult(f.id, sid, f.kind, f.status, outcome, detail, **kw)


def _unreachable(f: Fact, sid: str | None, r: Fetched) -> FactResult:
    return _fr(f, sid, "source-unreachable", f"fetch failed: {r.error or r.status}", checked_url=r.url)


def _json(r: Fetched) -> tuple[Any, str | None]:
    try:
        return r.json(), None
    except ValueError:
        return None, "response is not JSON"


_LAYER_TAIL = re.compile(r"/(MapServer|FeatureServer)/\d+/?$", re.I)


def layer_url(endpoint: str, layer_id: Any) -> str:
    e = endpoint.rstrip("/")
    if e.endswith("/query"):
        e = e[: -len("/query")]
    if layer_id is None or layer_id == "" or _LAYER_TAIL.search(e):
        return e
    return f"{e}/{layer_id}"


# --------------------------------------------------------------------------- static checkers

def check_quote(f: Fact, source: dict[str, Any], ctx: Context, hint: str) -> FactResult:
    sid = source["id"]
    url = f.get("url") or source.get("url")
    r = ctx.fetch(url)
    if not r.ok:
        return _unreachable(f, sid, r)
    quote = f.get("quote") or ""
    if not quote:
        return _fr(f, sid, "skipped", "fact has no quote to re-find", checked_url=url)
    try:
        text = ctx.text_of(r, hint)
    except RuntimeError as e:
        return _fr(f, sid, "source-unreachable", f"could not extract text: {e}", checked_url=url)
    m = find_quote(text, quote)
    moved = r.moved
    if m.found:
        detail = "quote found" + (" after case/punctuation folding" if m.how == "folded" else "")
        if moved:
            return _fr(f, sid, "moved", f"{detail}; URL redirects to {r.final_url}", checked_url=url, final_url=r.final_url)
        return _fr(f, sid, "unchanged", detail, checked_url=url, final_url=r.final_url)
    if m.snippet and (m.similarity or 0) >= 0.75:
        # The passage is recognisably there but not verbatim. Quotes stitched from PDF tables often reflow, so
        # only figures of the quote that are absent from the whole page count as a change (extra figures don't).
        qn = set(_NUMS.findall(quote))
        page_nums = set(_NUMS.findall(normalize(text)))
        gone = sorted(n for n in qn if n not in page_nums)
        if gone:
            new = sorted(set(_NUMS.findall(m.snippet)) - qn)
            return _fr(f, sid, "value-changed", f"the quoted passage is still there but these figures are no longer on the page: {gone}; "
                       f"figures near it now: {new[:12]}", snippet=m.snippet, similarity=m.similarity, recorded=quote,
                       checked_url=url, final_url=r.final_url)
        detail = f"quote matched loosely (similarity {m.similarity}; text reflowed, every figure of the quote still on the page)"
        if moved:
            return _fr(f, sid, "moved", f"{detail}; URL redirects to {r.final_url}", checked_url=url, final_url=r.final_url)
        return _fr(f, sid, "unchanged", detail, snippet=m.snippet, similarity=m.similarity, checked_url=url, final_url=r.final_url)
    return _fr(f, sid, "quote-missing", "quote no longer found in the fetched text", snippet=m.snippet, similarity=m.similarity,
               recorded=quote, checked_url=url, final_url=r.final_url)


_RESERVED = {"url", "endpoint", "layer", "layer_id", "service", "params", "field", "json_path", "geometry_note", "notes"}


def check_value(f: Fact, source: dict[str, Any], ctx: Context) -> FactResult:
    sid = source["id"]
    q = f.get("query") or {}
    url = q.get("url") or f.get("url") or source.get("url")
    if not q.get("url") and q.get("endpoint"):
        url = layer_url(q["endpoint"], q.get("layer_id", q.get("layer"))) + "/query"
    params = dict(q.get("params") or {k: v for k, v in q.items() if k not in _RESERVED})
    if params and "f" not in params and "f=" not in url:
        params["f"] = "json"
    r = ctx.fetch(url, {k: str(v) for k, v in params.items()} or None)
    if not r.ok:
        return _unreachable(f, sid, r)
    data, err = _json(r)
    if err:
        return _fr(f, sid, "schema-drift", err, checked_url=r.url)
    if isinstance(data, dict) and "error" in data:
        return _fr(f, sid, "schema-drift", f"service error: {data['error']}", checked_url=r.url)
    recorded = f.get("value")
    observed: Any = None
    if q.get("json_path"):
        try:
            observed = pick(data, q["json_path"])
        except (KeyError, IndexError, ValueError):
            return _fr(f, sid, "schema-drift", f"json_path {q['json_path']} not in response", checked_url=r.url, recorded=recorded)
        same = values_equal(recorded, observed, f.get("value_type"))
    elif q.get("field"):
        feats = (data or {}).get("features") or []
        vals = []
        for feat in feats:
            attrs = feat.get("attributes") or feat.get("properties") or {}
            low = {k.lower(): v for k, v in attrs.items()}
            if q["field"].lower() in low:
                vals.append(low[q["field"].lower()])
        if not vals:
            return _fr(f, sid, "schema-drift", f"field {q['field']} returned no values", checked_url=r.url, recorded=recorded)
        observed = vals[0] if len(vals) == 1 else vals
        same = any(values_equal(recorded, v, f.get("value_type")) for v in vals)
    else:
        path = find_value(data, recorded)
        same = path is not None
        observed = f"found at {path}" if same else None
    moved = r.moved
    if same:
        if moved:
            return _fr(f, sid, "moved", f"value unchanged; URL redirects to {r.final_url}", observed=observed, checked_url=r.url, final_url=r.final_url)
        return _fr(f, sid, "unchanged", "value matches", observed=observed, recorded=recorded, checked_url=r.url)
    return _fr(f, sid, "value-changed", "recorded value not found / changed", observed=observed, recorded=recorded, checked_url=r.url)


# --------------------------------------------------------------------------- lookup checker

def check_lookup(f: Fact, sid: str | None, ctx: Context) -> FactResult:
    lk = f.get("lookup") or {}
    endpoint, fields = lk.get("endpoint"), [str(x) for x in (lk.get("fields") or [])]
    if not endpoint:
        return _fr(f, sid, "schema-drift", "lookup block has no endpoint")
    lurl = layer_url(endpoint, lk.get("layer_id"))
    is_arcgis = bool(re.search(r"/(MapServer|FeatureServer)", lurl, re.I))
    meta_r = ctx.fetch(lurl, {"f": "json"})
    if not meta_r.ok:
        return _unreachable(f, sid, meta_r)
    meta, err = _json(meta_r)
    if err:
        return _fr(f, sid, "schema-drift", f"layer metadata: {err}", checked_url=meta_r.url)
    if isinstance(meta, dict) and "error" in meta:
        return _fr(f, sid, "schema-drift", f"layer gone or changed: {meta['error']}", checked_url=meta_r.url)
    problems: list[str] = []
    notes: list[str] = []
    if is_arcgis:
        have = {str(x.get("name", "")).lower() for x in (meta.get("fields") or [])}
        missing = [x for x in fields if x.lower() not in have]
        if missing:
            problems.append(f"missing fields: {', '.join(missing)}")
        name = meta.get("name")
        key = lurl.lower()
        prev = ctx.state.layer(key).get("name")
        if prev and name and prev != name:
            problems.append(f"layer renamed: {prev!r} -> {name!r}")
        ctx.state.record_layer(key, name=name, fields=sorted(have), seen_at=now_iso(), geometry=meta.get("geometryType"))
    else:
        from .values import leaves
        keys = {p.split(".")[-1].lower() for p, _ in leaves(meta)}
        missing = [x for x in fields if x.lower() not in keys]
        if missing:
            problems.append(f"missing fields in API response: {', '.join(missing)}")
    observed: Any = None
    if is_arcgis and not problems:
        pin = ctx.pin((lk.get("params") or {}).get("pin"))
        if pin is None:
            notes.append(f"sample query not run: demo pin could not be geocoded ({ctx._pin_error})")
        else:
            params = {
                "geometry": f"{pin.x},{pin.y}", "geometryType": "esriGeometryPoint", "inSR": "4326",
                "spatialRel": "esriSpatialRelIntersects", "outFields": ",".join(fields) or "*",
                "returnGeometry": "false", "f": "json",
            }
            for k, v in (lk.get("params") or {}).items():
                if k != "pin":
                    params[k] = str(v)
            qr = ctx.fetch(lurl + "/query", params)
            if not qr.ok:
                return _unreachable(f, sid, qr)
            data, err = _json(qr)
            if err or (isinstance(data, dict) and "error" in data):
                problems.append(f"sample query failed: {err or data.get('error')}")
            else:
                feats = data.get("features") or []
                observed = {"pin": pin.id, "geocoder": pin.provider, "features": len(feats),
                            "first": (feats[0].get("attributes") if feats else None)}
                notes.append(f"sample query at pin '{pin.id}' ({pin.provider}) answered with {len(feats)} feature(s)")
                if feats:
                    got = {k.lower() for k in (feats[0].get("attributes") or {})}
                    miss = [x for x in fields if x.lower() not in got]
                    if miss:
                        problems.append(f"sample feature lacks fields: {', '.join(miss)}")
    if problems:
        return _fr(f, sid, "schema-drift", "; ".join(problems + notes), observed=observed, checked_url=meta_r.url)
    if meta_r.moved:
        return _fr(f, sid, "moved", f"layer answers but redirects to {meta_r.final_url}; " + "; ".join(notes),
                   observed=observed, checked_url=meta_r.url, final_url=meta_r.final_url)
    return _fr(f, sid, "unchanged", "layer answers, fields present" + ("; " + "; ".join(notes) if notes else ""),
               observed=observed, checked_url=meta_r.url)


# --------------------------------------------------------------------------- per source

CHECKERS: dict[str, Callable[[Fact, dict[str, Any], Context], FactResult]] = {
    "html-quote": lambda f, s, c: check_quote(f, s, c, "html"),
    "pdf-quote": lambda f, s, c: check_quote(f, s, c, "pdf"),
    "arcgis-query": check_value,
    "api-json": check_value,
}


def check_fact(f: Fact, source: dict[str, Any], ctx: Context) -> FactResult:
    sid = source.get("id")
    if f.kind == "lookup" and f.get("lookup"):
        return check_lookup(f, sid, ctx)
    if f.status not in CHECKABLE_STATUSES:
        return _fr(f, sid, "skipped", f"status {f.status or '?'}: nothing recorded to re-check")
    method = extraction_of(source)
    if f.get("query") and method in ("html-quote", "pdf-quote", "manual"):
        method = "arcgis-query"
    checker = CHECKERS.get(method)
    if method == "download":
        r = ctx.fetch(f.get("url") or source.get("url"))
        if not r.ok:
            return _unreachable(f, sid, r)
        return _fr(f, sid, "skipped", "download answers; values inside a feed need a feed-specific checker", checked_url=r.url)
    if checker is None:
        return _fr(f, sid, "skipped", f"extraction {method}: human check")
    return checker(f, source, ctx)


def check_source(source: dict[str, Any], facts: list[Fact], ctx: Context) -> SourceResult:
    url = source.get("url", "")
    res = SourceResult(source_id=source["id"], url=url, extraction=extraction_of(source))
    prev = ctx.state.source(source["id"])
    if url:
        r = ctx.fetch(url)
        res.final_url, res.http_status, res.error, res.moved = r.final_url, r.status, r.error, r.moved
        if r.ok:
            res.content_sha256 = r.sha256
            try:
                text = ctx.text_of(r, {"pdf-quote": "pdf", "html-quote": "html"}.get(res.extraction))
            except RuntimeError:
                text = r.text
            res.content_sha256_text = hashlib.sha256(text.encode()).hexdigest()
            if prev.get("content_sha256_text"):
                res.content_changed = prev["content_sha256_text"] != res.content_sha256_text
            pages = ctx.cache_dir / "pages"
            pages.mkdir(parents=True, exist_ok=True)
            (pages / f"{source['id']}.txt").write_text(text[:2_000_000], encoding="utf-8")
    for f in facts:
        try:
            res.facts.append(check_fact(f, source, ctx))
        except Exception as e:  # one broken fact must not stop the run
            res.facts.append(_fr(f, source.get("id"), "skipped", f"checker error: {type(e).__name__}: {e}"))
    ctx.state.record_source(
        source["id"], last_checked=res.checked_at, url=url, final_url=res.final_url, http_status=res.http_status,
        error=res.error, content_sha256=res.content_sha256, content_sha256_text=res.content_sha256_text,
        outcome=res.outcome,
    )
    for fr in res.facts:
        track_unreachable(ctx, fr, res.checked_at)
    ctx.state.save()
    return res


def track_unreachable(ctx: Context, fr: FactResult, when: str) -> None:
    """Unreachable is transient: count consecutive failures; propose stale only at the threshold."""
    prev = ctx.state.data["facts"].get(fr.fact_id, {})
    n = int(prev.get("consecutive_unreachable", 0)) + 1 if fr.outcome == "source-unreachable" else 0
    fr.consecutive_unreachable = n
    fr.propose_stale = fr.outcome == "source-unreachable" and n >= ctx.unreachable_threshold and fr.status_before == "verified"
    ctx.state.record_fact(fr.fact_id, last_checked=when, outcome=fr.outcome, consecutive_unreachable=n,
                          **({"last_reachable": when} if fr.outcome not in ("source-unreachable", "skipped") else {}))


# --------------------------------------------------------------------------- run

@dataclass
class Run:
    started_at: str
    finished_at: str | None
    ledger_root: str
    args: dict[str, Any]
    results: list[SourceResult] = field(default_factory=list)
    not_due: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    orphans: list[FactResult] = field(default_factory=list)
    marked_stale: list[str] = field(default_factory=list)
    pin: dict[str, Any] | None = None
    pin_error: str | None = None

    def fact_results(self) -> list[FactResult]:
        return [f for s in self.results for f in s.facts] + self.orphans

    def counts(self) -> dict[str, int]:
        out: dict[str, int] = {}
        for f in self.fact_results():
            out[f.outcome] = out.get(f.outcome, 0) + 1
        return out

    def exit_code(self) -> int:
        c = self.counts()
        code = 0
        if any(c.get(k) for k in DRIFT):
            code |= 1
        if c.get("source-unreachable") or any(s.outcome == "source-unreachable" for s in self.results):
            code |= 2
        if c.get("moved") or any(s.moved for s in self.results):
            code |= 4
        if any(f.propose_stale for f in self.fact_results()):
            code |= 8
        return code

    def to_json(self) -> dict[str, Any]:
        return {
            "started_at": self.started_at, "finished_at": self.finished_at, "ledger_root": self.ledger_root,
            "args": self.args, "counts": self.counts(), "exit_code": self.exit_code(),
            "not_due": self.not_due, "problems": self.problems, "marked_stale": self.marked_stale,
            "pin": self.pin, "pin_error": self.pin_error,
            "sources": [{**{k: v for k, v in asdict(s).items() if k != "facts"}, "outcome": s.outcome,
                         "facts": [asdict(f) for f in s.facts]} for s in self.results],
            "orphans": [asdict(f) for f in self.orphans],
        }


def run_check(ledger: Ledger, ctx: Context, *, due_only: bool = False, only: list[str] | None = None,
              write_ledger: bool = True, args: dict[str, Any] | None = None) -> Run:
    run = Run(started_at=now_iso(), finished_at=None, ledger_root=str(ledger.root), args=args or {})
    run.problems.extend(ledger.problems)
    by_source = ledger.facts_by_source()
    for sid, facts in by_source.items():
        if sid is None or sid not in ledger.sources:
            for f in facts:
                if f.kind == "lookup" and f.get("lookup") and (not only):
                    run.orphans.append(check_lookup(f, sid, ctx))
                elif sid is not None and sid != "":
                    run.problems.append(f"fact {f.id}: source_id {sid!r} not in sources.yaml")
                    run.orphans.append(_fr(f, sid, "skipped", "source_id not in sources.yaml"))
                else:  # unsourced/demo facts legitimately have no source yet
                    run.orphans.append(_fr(f, None, "skipped", f"no source_id (status {f.status})"))
    if only:
        unknown = [s for s in only if s not in ledger.sources]
        run.problems.extend(f"--source {s}: not in sources.yaml" for s in unknown)
    for sid, source in ledger.sources.items():
        if only and sid not in only:
            continue
        facts = by_source.get(sid, [])
        if due_only and not only:
            intervals = [source.get("check_every", "")] + [f.get("check_every", "") for f in facts]
            if not is_due(intervals, ctx.state.source(sid).get("last_checked"), ctx.now):
                run.not_due.append(sid)
                continue
        run.results.append(check_source(source, facts, ctx))
    for fr in run.orphans:
        track_unreachable(ctx, fr, run.started_at)
    ctx.state.save()
    # drift flips verified -> stale (value untouched). Unreachable never does; it only gets a proposal at the threshold.
    stale = {f.fact_id for f in run.fact_results() if f.outcome in DRIFT and f.status_before == "verified"}
    if write_ledger and stale:
        run.marked_stale = ledger.mark_stale(stale)
    if ctx._pin is not None:
        run.pin = asdict(ctx._pin)
    run.pin_error = ctx._pin_error
    run.finished_at = now_iso()
    return run
