"""python -m research.freshness check [--due-only] [--source ID] [--report PATH]"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESEARCH = HERE.parent
DEFAULT_REPORT_DIR = Path("/home/box/agent-data/grok-ship/reports")
EX_USAGE, EX_SOFTWARE = 64, 70


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python -m research.freshness", description="Freshness checks for the research ledger.")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="re-check sources and facts")
    c.add_argument("--due-only", action="store_true", help="only sources whose check_every has elapsed")
    c.add_argument("--source", action="append", metavar="ID", help="check only this source (repeatable; ignores due)")
    c.add_argument("--report", type=Path, help="Markdown report path (JSON summary is written next to it)")
    c.add_argument("--json", type=Path, help="JSON summary path (default: report path with .json)")
    c.add_argument("--ledger", type=Path, default=RESEARCH, help="research/ dir holding sources.yaml and facts/")
    c.add_argument("--cache", type=Path, default=HERE / ".cache", help="state + page cache dir")
    c.add_argument("--proposals", type=Path, default=HERE / "proposals")
    c.add_argument("--pins", type=Path, default=HERE / "pins.yaml")
    c.add_argument("--no-write-ledger", action="store_true", help="never flip fact status in facts/*.json")
    c.add_argument("--replay", type=Path, help="replay recorded HTTP fixtures (tests)")
    c.add_argument("--record", type=Path, help="record HTTP responses into this dir")
    c.add_argument("--timeout", type=float, default=20.0)
    c.add_argument("--unreachable-threshold", type=int, default=3,
                   help="consecutive unreachable runs before a stale proposal is written (status is never flipped for this)")
    c.add_argument("--min-interval", type=float, default=1.0, help="seconds between requests to one host")
    s = sub.add_parser("status", help="print state summary (no network)")
    s.add_argument("--cache", type=Path, default=HERE / ".cache")
    return p


def cmd_check(a: argparse.Namespace) -> int:
    from .checks import Context, run_check
    from .ledger import Ledger
    from .net import Fetcher
    from .pins import load_pins
    from .report import write_proposals, write_report
    from .state import State

    if not (a.ledger / "sources.yaml").exists():
        print(f"error: {a.ledger / 'sources.yaml'} not found", file=sys.stderr)
        return EX_USAGE
    ledger = Ledger.load(a.ledger)
    state = State.load(a.cache / "state.json")
    pins = load_pins(a.pins) if a.pins.exists() else []
    fetcher = Fetcher(timeout=a.timeout, min_interval=a.min_interval, replay_dir=a.replay, record_dir=a.record)
    ctx = Context(fetcher=fetcher, state=state, cache_dir=a.cache, pins=pins, unreachable_threshold=a.unreachable_threshold)
    args = {"due_only": a.due_only, "source": a.source, "write_ledger": not a.no_write_ledger}
    try:
        run = run_check(ledger, ctx, due_only=a.due_only, only=a.source, write_ledger=not a.no_write_ledger, args=args)
    finally:
        fetcher.close()
        state.save()
    report = a.report or DEFAULT_REPORT_DIR / f"FM-MYAD-RES-freshness-{dt.date.today().isoformat()}.md"
    md, js = write_report(run, report, a.json)
    props = write_proposals(run, a.proposals)
    print(json.dumps({"counts": run.counts(), "exit_code": run.exit_code(), "report": str(md), "json": str(js),
                      "proposals": len(props), "marked_stale": run.marked_stale, "not_due": len(run.not_due),
                      "problems": len(run.problems)}, indent=2))
    return run.exit_code()


def cmd_status(a: argparse.Namespace) -> int:
    from .state import State

    st = State.load(a.cache / "state.json")
    for sid, s in sorted(st.data["sources"].items()):
        print(f"{sid:40} {s.get('last_checked', '-'):26} {s.get('outcome', '-')}")
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        a = build_parser().parse_args(argv)
    except SystemExit as e:
        return EX_USAGE if e.code else 0
    try:
        return {"check": cmd_check, "status": cmd_status}[a.cmd](a)
    except Exception:
        traceback.print_exc()
        return EX_SOFTWARE
