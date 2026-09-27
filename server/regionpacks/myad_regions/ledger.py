"""Read-only view of myAD Research's fact ledger (research/facts/*.json) for static region facts.

Fee and payment-rule facts (license fees, USCIS payment rules, deposit law, taxi rules) are not pin lookups: their
values live only in Research's verified ledger. Regions never types a price or a rule into code or fixtures. A
fact the ledger lacks, or has with any status other than "verified", is answered as unsourced with the desk.

Typing follows the server's ledger rules (server/src/myad_server/ledger.py coerce_value): money and quantity need
a unit, text needs value_language, and nothing is guessed.
"""
from __future__ import annotations

import json
import os
import re
from functools import lru_cache
from pathlib import Path
from types import MappingProxyType
from typing import Mapping

import yaml

from .types import validate_value

LEDGER_ENV = "MYAD_LEDGER_DIR"
DEFAULT_DIR = Path(__file__).resolve().parents[3] / "research" / "facts"


def ledger_dir() -> Path:
    return Path(os.environ.get(LEDGER_ENV) or DEFAULT_DIR)


@lru_cache(maxsize=4)
def _load(path: str) -> Mapping[str, dict]:
    rows: dict[str, dict] = {}
    d = Path(path)
    for f in sorted(d.glob("*.json")) if d.is_dir() else []:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue  # a half-written ledger file never turns into an answer
        for row in data if isinstance(data, list) else data.get("facts", []) if isinstance(data, dict) else []:
            if isinstance(row, dict) and isinstance(row.get("id"), str):
                rows[row["id"]] = row
    return MappingProxyType(rows)


def ledger() -> Mapping[str, dict]:
    return _load(str(ledger_dir()))


@lru_cache(maxsize=4)
def _load_sources(path: str) -> Mapping[str, dict]:
    try:
        data = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError):
        return MappingProxyType({})
    items = data.get("sources") if isinstance(data, dict) else data
    return MappingProxyType({s["id"]: s for s in items or () if isinstance(s, dict) and isinstance(s.get("id"), str)})


def ledger_sources() -> Mapping[str, dict]:
    """Research's source registry (research/sources.yaml, next to the facts folder), keyed by source id."""
    return _load_sources(str(ledger_dir().parent / "sources.yaml"))


def clear_cache() -> None:
    _load.cache_clear()
    _load_sources.cache_clear()


def typed_value(row: dict) -> dict | None:
    """The FactValue for a ledger row, or None when the row cannot be typed without guessing."""
    v, vt = row.get("value"), row.get("value_type")
    if v is None:
        return None
    if isinstance(v, dict) and "type" in v:
        out = v
    elif vt == "code" and isinstance(v, (str, int)) and not isinstance(v, bool):
        out = {"type": "code", "code": str(v)}
    elif vt == "text" and isinstance(v, str) and row.get("value_language"):
        out = {"type": "text", "text": v, "language": row["value_language"]}
    elif vt == "date" and isinstance(v, str):
        out = {"type": "date", "date": v}
    elif vt == "flag" and isinstance(v, bool):
        out = {"type": "flag", "value": v}
    elif vt in ("money", "quantity") and row.get("unit") and not isinstance(v, bool):
        try:
            amount = float(v) if isinstance(v, str) else v
        except ValueError:
            return None
        if not isinstance(amount, (int, float)):
            return None
        out = {"type": vt, "amount": amount, ("currency" if vt == "money" else "unit"): row["unit"]}
    elif vt == "phone" and isinstance(v, str):
        out = {"type": "phone", "digits": re.sub(r"[\s().\-]", "", v)}
    else:
        return None
    return None if validate_value(out) else out


def verified(fact_id: str) -> tuple[dict, dict] | None:
    """(row, value) when the ledger has this fact verified, with a url, retrieved_at and a typeable value."""
    row = ledger().get(fact_id)
    if not row or row.get("status") != "verified" or not row.get("url") or not row.get("retrieved_at"):
        return None
    if not row.get("source_id"):
        return None
    value = typed_value(row)
    return (row, value) if value is not None else None
