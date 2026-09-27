"""Loads data/fee_purposes.yaml (vocabulary and reviewed copy only; no fees, phones or addresses)."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

from .text import compile_pattern

_PATH = Path(__file__).resolve().parents[1] / "data" / "fee_purposes.yaml"
LANGS = ("en", "es", "ht")
COPY_KEYS = ("official_fee", "addon", "official_rule", "quoted_in_english", "no_official_fee",
             "private_no_verdict", "not_shown_tourist", "desk_fallback", "desk_none")


@dataclass(frozen=True)
class PurposeRule:
    key: str
    all_of: tuple[re.Pattern[str], ...]

    def matches(self, normalized: str) -> bool:
        return all(p.search(normalized) for p in self.all_of)


@dataclass(frozen=True)
class FeeVocab:
    purposes: tuple[PurposeRule, ...]
    private_groups: frozenset[str]
    addons: dict[str, tuple[str, ...]]
    immigration_desk: str | None
    payee: dict[str, re.Pattern[str]]
    method: tuple[tuple[str, re.Pattern[str]], ...]
    copy: dict[str, dict[str, str]] = field(default_factory=dict)

    def text(self, key: str, language: str) -> str:
        table = self.copy[key]
        return table.get(language) or table["en"]


def _load(path: Path) -> FeeVocab:
    data: Any = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a mapping")
    purposes = tuple(
        PurposeRule(str(p["key"]), tuple(compile_pattern(x) for x in p["all_of"])) for p in data["purposes"]
    )
    copy = {k: {str(lk): str(lv) for lk, lv in v.items()} for k, v in data["copy"].items()}
    missing = [f"{k}.{lang}" for k in COPY_KEYS for lang in LANGS if lang not in copy.get(k, {})]
    if missing:
        raise ValueError(f"{path}: copy missing {missing}")
    return FeeVocab(
        purposes=purposes,
        private_groups=frozenset(data.get("private_groups") or ()),
        addons={str(k): tuple(v) for k, v in (data.get("addons") or {}).items()},
        immigration_desk=data.get("immigration_desk"),
        payee={k: compile_pattern(v) for k, v in data["payee"].items()},
        method=tuple((k, compile_pattern(v)) for k, v in data["method"].items()),
        copy=copy,
    )


@lru_cache(maxsize=4)
def load_vocab(path: Path = _PATH) -> FeeVocab:
    return _load(path)
