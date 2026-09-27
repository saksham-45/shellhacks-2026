"""python -m research.onboarding propose --place "County, ST" [--city NAME] [--out DIR]
   python -m research.onboarding compare --run DIR --plan PLAN.md"""
from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
EX_USAGE, EX_SOFTWARE = 64, 70


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="python -m research.onboarding")
    sub = p.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("propose", help="discover official sources for a place and write a proposed pack")
    pr.add_argument("--place", required=True, help='"Miami-Dade County, FL" or "Miami, FL"')
    pr.add_argument("--city", help="also resolve this incorporated place inside the county")
    pr.add_argument("--out", type=Path, help="output dir (default research/onboarding/runs/<region id>)")
    pr.add_argument("--budget", type=int, default=800, help="max HTTP requests")
    pr.add_argument("--min-interval", type=float, default=0.5, help="seconds between requests to one host")
    pr.add_argument("--timeout", type=float, default=30.0)
    pr.add_argument("--fresh", action="store_true", help="ignore responses already recorded in <out>/.cache/http")
    pr.add_argument("--no-probe", action="store_true", help="do not probe common ArcGIS paths on official hosts")
    pr.add_argument("--only", action="append", help="run only these discoverers (by name; repeatable)")
    pr.add_argument("--replay", type=Path, help="replay recorded HTTP fixtures (tests)")
    pr.add_argument("--record", type=Path, help="record raw HTTP responses here (default <out>/.cache/http)")
    re_ = sub.add_parser("reemit", help="rebuild the proposal files from a run's findings.json (no network)")
    re_.add_argument("--run", type=Path, required=True)
    cp = sub.add_parser("compare", help="compare a run with the endpoints listed in a plan markdown")
    cp.add_argument("--run", type=Path, required=True)
    cp.add_argument("--plan", type=Path, required=True)
    cp.add_argument("--json", type=Path)
    return p


def cmd_propose(a: argparse.Namespace) -> int:
    from research.freshness.net import Fetcher, now_iso

    from .discover import Context, default_discoverers, run_all
    from .emit import emit
    from .resolve import ResolveError, resolve

    started = now_iso()
    rec = a.record
    f0 = Fetcher(timeout=a.timeout, min_interval=a.min_interval, budget=a.budget, replay_dir=a.replay)
    try:
        chain = resolve(a.place, f0, a.city)
    except ResolveError as e:
        print(f"error: {e}", file=sys.stderr)
        return EX_USAGE
    out = a.out or HERE / "runs" / chain.region_id
    if rec is None and a.replay is None:
        rec = out / ".cache" / "http"
    fetcher = Fetcher(timeout=a.timeout, min_interval=a.min_interval, budget=a.budget, replay_dir=a.replay, record_dir=rec,
                      reuse_recorded=not a.fresh)
    if rec is not None:  # re-resolve through the recording fetcher so replays are complete
        chain = resolve(a.place, fetcher, a.city)
    else:
        fetcher.log.extend(f0.log)
    ctx = Context(chain=chain, fetcher=fetcher, options={"no_probe": a.no_probe})
    ds = default_discoverers()
    if a.only:
        ds = [d for d in ds if d.name in a.only]
    try:
        run_all(ctx, ds)
    finally:
        fetcher.close()
    paths = emit(ctx, out, a.place, started)
    counts: dict[str, int] = {}
    for f in ctx.findings:
        counts[f.kind] = counts.get(f.kind, 0) + 1
    print(json.dumps({"region": chain.region_id, "chain": [j.pack_id for j in chain.levels], "findings": counts,
                      "gaps": len(ctx.gaps), "requests": len(fetcher.log), "outputs": {k: str(v) for k, v in paths.items()}}, indent=2))
    return 0


def cmd_reemit(a: argparse.Namespace) -> int:
    from .emit import emit, load_context

    ctx = load_context(a.run)
    paths = emit(ctx, a.run, ctx.options.get("place") or "", ctx.options.get("started_at") or "")
    print(json.dumps({k: str(v) for k, v in paths.items()}, indent=2))
    return 0


def cmd_compare(a: argparse.Namespace) -> int:
    from .compare import compare, render

    c = compare(a.run, a.plan)
    print(render(c))
    if a.json:
        a.json.write_text(json.dumps(c, indent=2) + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    try:
        a = build_parser().parse_args(argv)
    except SystemExit as e:
        return EX_USAGE if e.code else 0
    try:
        return {"propose": cmd_propose, "reemit": cmd_reemit, "compare": cmd_compare}[a.cmd](a)
    except Exception:
        traceback.print_exc()
        return EX_SOFTWARE
