"""Markdown report, JSON summary, and proposal files for human/agent review."""
from __future__ import annotations

import json
import re
from dataclasses import asdict
from pathlib import Path

from .checks import FactResult, Run

EXIT_HELP = ("0 clean; bit 1 drift (value changed, quote missing, or schema drift); bit 2 source unreachable this run; bit 4 moved; "
             "bit 8 unreachable for the configured number of consecutive runs (stale proposed); 64 usage/config; 70 internal")
SECTIONS = (
    ("Content drifted: value changed (needs review)", ("value-changed",)),
    ("Quote no longer found (needs review)", ("quote-missing",)),
    ("Schema drift in lookups (needs review)", ("schema-drift",)),
    ("Moved (redirects; review the URL)", ("moved",)),
    ("Source unreachable this run (transient; retried next run; fact status unchanged)", ("source-unreachable",)),
)


def _cell(s: object, n: int = 160) -> str:
    t = re.sub(r"\s+", " ", str(s if s is not None else "")).replace("|", "\\|")
    return t if len(t) <= n else t[: n - 1] + "…"


def render_markdown(run: Run) -> str:
    c = run.counts()
    L = [f"# FM-MYAD-RES freshness check — {run.started_at[:10]}", ""]
    L.append(f"Started {run.started_at}, finished {run.finished_at}. Ledger: `{run.ledger_root}`.")
    L.append(f"Arguments: `{json.dumps(run.args, sort_keys=True)}`. Exit code **{run.exit_code()}** ({EXIT_HELP}).")
    L.append("")
    L.append("| outcome | facts |")
    L.append("| --- | --- |")
    for k in ("unchanged", "value-changed", "quote-missing", "schema-drift", "moved", "source-unreachable", "skipped"):
        L.append(f"| {k} | {c.get(k, 0)} |")
    L.append("")
    L.append(f"Sources checked: {len(run.results)}. Not due (skipped by --due-only): {len(run.not_due)}.")
    if run.marked_stale:
        L.append(f"Marked stale in the ledger (status only, drift outcomes): {', '.join(run.marked_stale)}.")
    else:
        L.append("No fact status was changed in the ledger this run.")
    thr = [f.fact_id for f in run.fact_results() if f.propose_stale]
    if thr:
        L.append(f"Unreachable threshold reached, stale **proposed** (not applied): {', '.join(thr)}.")
    if run.pin:
        L.append(f"Demo pin for lookup samples: `{run.pin['address']}` -> {run.pin['y']:.6f}, {run.pin['x']:.6f} "
                 f"via **{run.pin['provider']}** ({'official' if run.pin['official'] else 'secondary, official geocoder did not answer'}).")
    if run.pin_error:
        L.append(f"Demo pin geocoding problem: {run.pin_error}")
    if run.problems:
        L += ["", "## Ledger/config problems", ""] + [f"- {_cell(p, 300)}" for p in run.problems]
    L += ["", "## Sources", "", "| source | extraction | HTTP | outcome | page changed | facts | note |", "| --- | --- | --- | --- | --- | --- | --- |"]
    for s in run.results:
        changed = {True: "yes", False: "no", None: "first run" if s.content_sha256 else "-"}[s.content_changed]
        note = s.error or (f"redirects to {s.final_url}" if s.moved else "")
        L.append(f"| `{s.source_id}` | {s.extraction} | {s.http_status or '-'} | {s.outcome} | {changed} | {len(s.facts)} | {_cell(note)} |")
    frs = run.fact_results()
    for title, keys in SECTIONS:
        items = [f for f in frs if f.outcome in keys]
        if not items:
            continue
        L += ["", f"## {title}", ""]
        for f in items:
            extra = ""
            if f.outcome == "source-unreachable":
                extra = f" — consecutive failures: {f.consecutive_unreachable}" + (" — **stale proposed**" if f.propose_stale else "")
            L.append(f"- **{f.fact_id}** (source `{f.source_id}`, {f.kind}): {_cell(f.detail, 400)}{extra}")
            if f.recorded is not None and f.outcome in ("value-changed", "quote-missing"):
                L.append(f"  - recorded: {_cell(f.recorded, 300)}")
            if f.snippet:
                L.append(f"  - best match now ({f.similarity}): {_cell(f.snippet, 400)}")
            if f.observed is not None and f.outcome not in ("value-changed", "quote-missing"):
                L.append(f"  - observed: {_cell(json.dumps(f.observed, ensure_ascii=False), 300)}")
            elif f.observed is not None:
                L.append(f"  - observed: {_cell(f.observed, 300)}")
            if f.checked_url:
                L.append(f"  - checked: {f.checked_url}")
    ok = [f for f in frs if f.outcome == "unchanged"]
    if ok:
        L += ["", "## Unchanged", ""] + [f"- {f.fact_id}: {_cell(f.detail, 200)}" for f in ok]
    sk = [f for f in frs if f.outcome == "skipped"]
    if sk:
        L += ["", "## Skipped", ""] + [f"- {f.fact_id}: {_cell(f.detail, 200)}" for f in sk]
    if run.not_due:
        L += ["", "## Not due", "", ", ".join(f"`{s}`" for s in run.not_due)]
    L += ["", "Values are never rewritten by this check. Drift proposals are in `research/freshness/proposals/`.", ""]
    return "\n".join(L)


def write_report(run: Run, md_path: Path, json_path: Path | None = None) -> tuple[Path, Path]:
    md_path = Path(md_path)
    json_path = Path(json_path) if json_path else md_path.with_suffix(".json")
    md_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.write_text(render_markdown(run), encoding="utf-8")
    json_path.write_text(json.dumps(run.to_json(), indent=2, ensure_ascii=False, default=str) + "\n", encoding="utf-8")
    return md_path, json_path


def write_proposals(run: Run, out_dir: Path) -> list[Path]:
    """One JSON per fact needing review. Never contains a replacement value, only observations."""
    written: list[Path] = []
    day = run.started_at[:10]
    for f in run.fact_results():
        if f.outcome not in ("value-changed", "quote-missing", "schema-drift", "moved") and not f.propose_stale:
            continue
        d = Path(out_dir) / day
        d.mkdir(parents=True, exist_ok=True)
        action = {
            "value-changed": "The quoted passage now shows different figures. Re-read the source; if the fact changed, update value+quote+retrieved_at by hand and add correction_note.",
            "quote-missing": "The quoted sentence is gone. Find where the fact now lives (or whether it was removed); update quote/url by hand, or mark unsourced.",
            "source-unreachable": "The source failed on consecutive runs up to the threshold. Check it by hand. If it has really gone away, mark the fact stale; if it is only down, leave it (the app shows unavailable(desk) for a source that exists but can't be reached). Nothing was changed automatically.",
            "schema-drift": "The layer/API changed shape. Update lookup.endpoint/layer_id/fields and the adapter that uses it.",
            "moved": "The URL redirects. Confirm the new URL is the same official page, then update url in sources.yaml / the fact.",
        }[f.outcome]
        p = d / f"{re.sub(r'[^A-Za-z0-9._-]', '_', f.fact_id)}.json"
        p.write_text(json.dumps({"fact_id": f.fact_id, "outcome": f.outcome, "action": action, "result": asdict(f),
                                 "run_started_at": run.started_at, "auto_applied": False}, indent=2, ensure_ascii=False, default=str) + "\n",
                     encoding="utf-8")
        written.append(p)
    return written


def summarize(fr: FactResult) -> str:
    return f"{fr.fact_id}: {fr.outcome}"
