"""Compare recorded ledger values with values observed in a JSON response."""
from __future__ import annotations

import math
import re
from typing import Any, Iterator

_NUM = re.compile(r"^[\s$€£]*(-?[\d,]*\.?\d+)\s*%?\s*$")


def as_number(v: Any) -> float | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        m = _NUM.match(v)
        if m:
            try:
                return float(m.group(1).replace(",", ""))
            except ValueError:
                return None
    return None


def _s(v: Any) -> str:
    return re.sub(r"\s+", " ", str(v)).strip().casefold()


DAYS = {"monday": 0, "mon": 0, "m": 0, "tuesday": 1, "tue": 1, "tues": 1, "wednesday": 2, "wed": 2, "thursday": 3, "thu": 3,
        "thurs": 3, "friday": 4, "fri": 4, "saturday": 5, "sat": 5, "sunday": 6, "sun": 6,
        "lunes": 0, "martes": 1, "miercoles": 2, "miércoles": 2, "jueves": 3, "viernes": 4, "sabado": 5, "sábado": 5, "domingo": 6}


def _weekdays(v: Any) -> frozenset[int] | None:
    items = v if isinstance(v, (list, tuple)) else re.split(r"[\s,;/&]+|\band\b|\by\b", str(v))
    out = set()
    for it in items:
        t = str(it).strip().lower().rstrip(".")
        if not t:
            continue
        if t not in DAYS:
            return None
        out.add(DAYS[t])
    return frozenset(out) if out else None


def _typed_equal(recorded: Any, observed: Any, value_type: str) -> bool | None:
    """Comparison by the ledger's value_type (text, code, codes, phone, date, money, quantity, weekdays, place, flag).
    Returns None when the type gives no special rule."""
    vt = value_type.lower()
    if vt == "phone":
        dr, do = re.sub(r"\D", "", str(recorded))[-10:], re.sub(r"\D", "", str(observed))[-10:]
        return bool(dr) and dr == do if len(dr) > 3 else _s(recorded) == _s(observed)
    if vt == "weekdays":
        a, b = _weekdays(recorded), _weekdays(observed)
        return a == b if a is not None and b is not None else None
    if vt == "codes":
        split = lambda v: {_s(x) for x in (v if isinstance(v, (list, tuple)) else re.split(r"[,;\s]+", str(v))) if str(x).strip()}  # noqa: E731
        return split(recorded) == split(observed)
    if vt == "code":
        return _s(recorded).upper() == _s(observed).upper()
    if vt == "flag":
        truth = {"true": True, "yes": True, "y": True, "1": True, "false": False, "no": False, "n": False, "0": False}
        a, b = truth.get(_s(recorded)), truth.get(_s(observed))
        return a == b if a is not None and b is not None else None
    if vt == "date":
        import datetime as _dt
        def d(v: Any):
            for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%B %d, %Y", "%b %d, %Y"):
                try:
                    return _dt.datetime.strptime(str(v).strip()[:len(fmt) + 10], fmt).date()
                except ValueError:
                    continue
            return None
        a, b = d(recorded), d(observed)
        return a == b if a and b else None
    if vt in ("text", "place"):
        return _s(recorded) == _s(observed)
    return None  # money / quantity use the numeric rule below


def values_equal(recorded: Any, observed: Any, value_type: str | None = None) -> bool:
    if value_type:
        t = _typed_equal(recorded, observed, value_type)
        if t is not None:
            return t
    if isinstance(recorded, (list, tuple)) and isinstance(observed, (list, tuple)):
        return len(recorded) == len(observed) and all(values_equal(a, b) for a, b in zip(recorded, observed))
    if isinstance(recorded, dict) and isinstance(observed, dict):
        return recorded.keys() == observed.keys() and all(values_equal(recorded[k], observed[k]) for k in recorded)
    a, b = as_number(recorded), as_number(observed)
    if a is not None and b is not None:
        return math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-9)
    if recorded is None or observed is None:
        return recorded is None and observed is None
    return _s(recorded) == _s(observed)


def pick(obj: Any, path: str) -> Any:
    """Dotted path with integer indexes: 'features.0.attributes.WEEKDAYS'. KeyError if absent."""
    cur = obj
    for part in [p for p in path.split(".") if p != ""]:
        if isinstance(cur, list):
            cur = cur[int(part)]
        elif isinstance(cur, dict):
            if part in cur:
                cur = cur[part]
            else:
                low = {str(k).lower(): k for k in cur}
                if part.lower() not in low:
                    raise KeyError(path)
                cur = cur[low[part.lower()]]
        else:
            raise KeyError(path)
    return cur


def leaves(obj: Any, prefix: str = "") -> Iterator[tuple[str, Any]]:
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, f"{prefix}.{k}" if prefix else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, f"{prefix}.{i}" if prefix else str(i))
    else:
        yield prefix, obj


def find_value(obj: Any, recorded: Any) -> str | None:
    """Path of the first leaf equal to the recorded value, or None."""
    if isinstance(recorded, (list, dict)):
        return "" if values_equal(recorded, obj) else None
    for path, v in leaves(obj):
        if values_equal(recorded, v):
            return path
    return None
