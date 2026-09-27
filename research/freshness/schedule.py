"""check_every parsing and due decisions."""
from __future__ import annotations

import datetime as dt
import re

_RX = re.compile(r"^\s*(\d+)\s*([dwmy])\s*$", re.I)
_ISO = re.compile(r"^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$", re.I)
_DAYS = {"d": 1, "w": 7, "m": 30, "y": 365}
_WORDS = {"daily": "1d", "weekly": "7d", "monthly": "30d", "quarterly": "90d", "yearly": "365d", "annually": "365d"}


def parse_interval(s: str | None) -> dt.timedelta:
    """ISO 8601 durations (P7D, P2W, P1M, P1Y, PT12H; M = 30 days, Y = 365 days), the short
    form '7d' '2w' '3m' '1y', and words like 'weekly'."""
    if not s:
        raise ValueError("empty check_every")
    s = _WORDS.get(s.strip().lower(), s.strip())
    iso = _ISO.match(s)
    if iso and s.upper() != "P" and s.upper() != "PT":
        y, mo, w, d, h, mi, se = (int(x) if x else 0 for x in iso.groups())
        td = dt.timedelta(days=y * 365 + mo * 30 + w * 7 + d, hours=h, minutes=mi, seconds=se)
        if td.total_seconds() <= 0:
            raise ValueError(f"zero check_every: {s!r}")
        return td
    m = _RX.match(s)
    if not m:
        raise ValueError(f"bad check_every: {s!r}")
    return dt.timedelta(days=int(m.group(1)) * _DAYS[m.group(2).lower()])


def parse_ts(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        d = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)


def is_due(intervals: list[str], last_checked: str | None, now: dt.datetime) -> bool:
    """Due when never checked or when the shortest valid interval has elapsed."""
    last = parse_ts(last_checked)
    if last is None:
        return True
    valid = []
    for s in intervals:
        try:
            valid.append(parse_interval(s))
        except ValueError:
            continue
    if not valid:
        return True
    return now - last >= min(valid)
