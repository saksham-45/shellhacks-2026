"""Fact ledger loader: research/facts/*.json (each a JSON array) plus research/sources.yaml.

Start-up validation fails loudly (LedgerError lists every problem) on the invariants the verifier relies on
(ARCHITECTURE.md §7, §13.x; agents-ARCH §13):
- ids are dotted, lowercase, unique, and start with a pack id; status is one of the four;
- verified/stale facts carry source_id (registered in sources.yaml), an http(s) url, a quote, an ISO 8601
  retrieved_at with an offset, and an ISO 8601 check_every;
- `kind: lookup` facts have value null, a value_type from the ten FactValue cases, a jurisdiction, a desk,
  and a lookup block {endpoint, layer_id?, fields, method, question}; they are never status demo;
- demo-pin ids `<lookup id>.demo.<pin-slug>` have status demo, name an existing lookup fact, and carry a
  value of that fact's value_type;
- a value_type, when present, matches the typed value; topics, when present, are in the topic vocabulary.
Facts whose value cannot be typed load with `typed_value=None` (a warning); the verifier never shows them.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError

from .topics import unknown_topics
from .values import FACT_ID, VALUE_TYPES, FactValue

FactStatus = Literal["verified", "stale", "unsourced", "demo"]
DEMO_ID = re.compile(r"^(?P<base>[a-z0-9-]+(\.[a-z0-9-]+)+)\.demo\.(?P<pin>pin-[a-z0-9-]+)$")
DURATION = re.compile(r"^P(?:(?P<y>\d+)Y)?(?:(?P<mo>\d+)M)?(?:(?P<w>\d+)W)?(?:(?P<d>\d+)D)?"
                      r"(?:T(?:(?P<h>\d+)H)?(?:(?P<mi>\d+)M)?(?:(?P<s>\d+)S)?)?$")
DESK_CONTACT_FIELDS = ("name", "phone", "url", "address", "hours", "languages")

_VALUE = TypeAdapter(FactValue)


class LedgerError(ValueError):
    def __init__(self, problems: list[str]):
        super().__init__(f"{len(problems)} ledger problem(s):\n" + "\n".join(problems))
        self.problems = problems


class LookupSpec(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True)
    endpoint: str = Field(min_length=1)
    layer_id: str | int | None = None
    fields: list[str] = Field(min_length=1)
    method: str = Field(min_length=1)
    question: str = Field(min_length=1)


class RawFact(BaseModel):
    """One ledger row as Research writes it. Unknown extra keys are kept but ignored."""

    model_config = ConfigDict(extra="allow", frozen=True)
    id: str
    claim: str | None = None
    value: Any = None
    unit: str | None = None
    jurisdiction: str | None = None
    source_id: str | None = None
    url: str | None = None
    quote: str | None = None
    retrieved_at: str | None = None
    check_every: str | None = None
    status: FactStatus
    kind: Literal["static", "lookup"] = "static"
    value_type: str | None = None
    value_language: str | None = None
    desk: str | None = None
    lookup: LookupSpec | None = None
    topics: list[str] = Field(default_factory=list)
    plan_value: Any = None
    plan_ref: str | None = None
    correction_note: str | None = None


@dataclass(frozen=True)
class Source:
    id: str
    publisher: str | None
    url: str | None
    publisher_language: str | None = None


@dataclass(frozen=True)
class LedgerFact:
    raw: RawFact
    typed_value: Any  # a FactValue model, or None

    @property
    def id(self) -> str:
        return self.raw.id

    @property
    def pack_id(self) -> str:
        return self.raw.id.split(".", 1)[0]

    @property
    def status(self) -> str:
        return self.raw.status

    @property
    def is_lookup(self) -> bool:
        return self.raw.kind == "lookup"

    @property
    def demo_base(self) -> str | None:
        m = DEMO_ID.match(self.raw.id)
        return m.group("base") if m else None


@dataclass
class Ledger:
    facts: dict[str, LedgerFact] = field(default_factory=dict)
    sources: dict[str, Source] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    @classmethod
    def load(cls, root: Path | str, *, topics: frozenset[str] | None = None) -> "Ledger":
        """Load and validate the research ledger rooted at the project directory.

        Validation is deliberately performed once at startup; request handlers only use the
        immutable-ish indexed result and never read ledger files.
        """
        project = Path(root)
        if topics is None:
            topic_path = project / "research" / "topics.yaml"
            if topic_path.is_file():
                from .topics import load_topics
                topics = load_topics(topic_path)
        return load_ledger(project / "research" / "facts", project / "research" / "sources.yaml", topics)

    def get(self, fact_id: str) -> LedgerFact | None:
        return self.facts.get(fact_id)

    def source_name(self, source_id: str | None) -> str | None:
        s = self.sources.get(source_id or "")
        return s.publisher if s else None

    def source_language(self, source_id: str | None) -> str | None:
        s = self.sources.get(source_id or "")
        return s.publisher_language if s else None

    def desk_contact_ids(self, desk_id: str) -> list[str]:
        """`<desk-id>.{name,phone,url,address,hours,languages}` ids present in the ledger, in that order."""
        return [f"{desk_id}.{f}" for f in DESK_CONTACT_FIELDS if f"{desk_id}.{f}" in self.facts]

    def has_desk(self, desk_id: str) -> bool:
        return bool(self.desk_contact_ids(desk_id))

    def desk_facts(self, desk_id: str) -> list[LedgerFact]:
        """Return only the allowed desk contact facts, in stable display order."""
        return [self.facts[fid] for fid in self.desk_contact_ids(desk_id)]

    def lookup_for(self, adapter_fact_id: str) -> LedgerFact | None:
        """Resolve an adapter result id to its ledger lookup.

        Ranked results use ``<lookup>.<n>`` and subfields use
        ``<lookup>.<n>.<field>``; district/member ids remain exact ledger ids.
        """
        exact = self.facts.get(adapter_fact_id)
        if exact is not None and exact.is_lookup:
            return exact
        parts = adapter_fact_id.split(".")
        if len(parts) >= 2 and parts[-1].isdigit() and 1 <= int(parts[-1]) <= 9:
            return self.facts.get(".".join(parts[:-1]))
        if len(parts) >= 3 and parts[-2].isdigit() and 1 <= int(parts[-2]) <= 9:
            return self.facts.get(".".join(parts[:-2]))
        return None


def parse_duration(text: str) -> timedelta | None:
    m = DURATION.match(text or "")
    if not m or text in ("P", "PT"):
        return None
    g = {k: int(v) if v else 0 for k, v in m.groupdict().items()}
    return timedelta(days=g["y"] * 365 + g["mo"] * 30 + g["w"] * 7 + g["d"], hours=g["h"], minutes=g["mi"],
                     seconds=g["s"])


def parse_instant(text: str | None) -> datetime | None:
    """ISO 8601 with an offset (a bare date is accepted as midnight UTC-less and treated as naive)."""
    if not text:
        return None
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def is_stale(fact: LedgerFact, now: datetime) -> bool:
    """Status stale, or verified but past retrieved_at + check_every."""
    if fact.status == "stale":
        return True
    if fact.status != "verified":
        return False
    at, every = parse_instant(fact.raw.retrieved_at), parse_duration(fact.raw.check_every or "")
    if at is None or every is None:
        return True
    if at.tzinfo is None:
        at = at.replace(tzinfo=now.tzinfo)
    return now > at + every


_SEPARATORS = re.compile(r"[\s().\-]")


def coerce_value(raw: RawFact) -> tuple[Any, str | None]:
    """Type a ledger value. Returns (FactValue model or None, problem or None). Never guesses a language,
    currency, or unit the row does not state."""
    v, vt = raw.value, raw.value_type
    if v is None:
        return None, None
    try:
        if isinstance(v, dict) and "type" in v:
            return _VALUE.validate_python(v), None
        if vt is None:
            return None, "scalar value without value_type"
        if vt == "phone" and isinstance(v, str):
            return _VALUE.validate_python({"type": "phone", "digits": _SEPARATORS.sub("", v)}), None
        if vt == "code" and isinstance(v, (str, int)):
            return _VALUE.validate_python({"type": "code", "code": str(v)}), None
        if vt == "codes" and isinstance(v, list):
            return _VALUE.validate_python({"type": "codes", "codes": [str(x) for x in v]}), None
        if vt == "text" and isinstance(v, str):
            if not raw.value_language:
                return None, "text value needs value_language (or a typed value)"
            return _VALUE.validate_python({"type": "text", "text": v, "language": raw.value_language}), None
        if vt == "date" and isinstance(v, str):
            return _VALUE.validate_python({"type": "date", "date": v}), None
        if vt in ("money", "quantity") and isinstance(v, (int, float, str)) and not isinstance(v, bool):
            if not raw.unit:
                return None, f"{vt} value needs unit"
            key = "currency" if vt == "money" else "unit"
            return _VALUE.validate_python({"type": vt, "amount": str(v), key: raw.unit}), None
        if vt == "weekdays":
            days = v if isinstance(v, list) else re.split(r"[\s,]+", str(v).strip())
            return _VALUE.validate_python({"type": "weekdays", "days": [str(d).lower() for d in days if d]}), None
        if vt == "flag" and isinstance(v, bool):
            return _VALUE.validate_python({"type": "flag", "value": v}), None
    except ValidationError as e:
        return None, f"value does not type as {vt}: {e.errors()[0]['msg']}"
    return None, f"value cannot be typed as {vt}"


def _validate_row(f: LedgerFact, sources: dict[str, Source], topics: frozenset[str] | None) -> list[str]:
    r, p = f.raw, []
    fid = r.id
    if not FACT_ID.match(fid):
        p.append(f"{fid}: id must be dotted lowercase <pack>.<topic>...")
    if not r.claim:
        p.append(f"{fid}: claim is required")
    if not r.jurisdiction:
        p.append(f"{fid}: jurisdiction is required")
    if r.kind == "static" and r.value is None and r.status != "unsourced":
        p.append(f"{fid}: static fact needs a value unless status is unsourced")
    if r.value_type is not None and r.value_type not in VALUE_TYPES:
        p.append(f"{fid}: value_type {r.value_type!r} is not one of the ten FactValue cases")
    if f.typed_value is not None and r.value_type is not None and f.typed_value.type != r.value_type:
        p.append(f"{fid}: value is {f.typed_value.type} but value_type says {r.value_type}")
    if r.status in ("verified", "stale"):
        if not r.source_id:
            p.append(f"{fid}: {r.status} fact without source_id")
        elif sources and r.source_id not in sources:
            p.append(f"{fid}: source_id {r.source_id!r} is not in sources.yaml")
        elif not sources:
            p.append(f"{fid}: source_id {r.source_id!r} but sources.yaml lists no sources")
        if not (r.url or "").startswith(("https://", "http://")):
            p.append(f"{fid}: {r.status} fact without an http(s) url")
        if not (r.quote or "").strip():
            p.append(f"{fid}: {r.status} fact without a quote")
        at = parse_instant(r.retrieved_at)
        if at is None or at.utcoffset() is None:
            p.append(f"{fid}: retrieved_at must be ISO 8601 with an offset")
        if parse_duration(r.check_every or "") is None:
            p.append(f"{fid}: check_every must be an ISO 8601 duration")
    elif r.status == "demo" and r.source_id and sources and r.source_id not in sources:
        p.append(f"{fid}: source_id {r.source_id!r} is not in sources.yaml")
    if r.kind == "lookup":
        if r.value is not None:
            p.append(f"{fid}: lookup fact must have value null")
        if r.value_type not in VALUE_TYPES:
            p.append(f"{fid}: lookup fact needs value_type (one of the ten FactValue cases)")
        if not r.jurisdiction:
            p.append(f"{fid}: lookup fact needs jurisdiction")
        if not r.desk:
            p.append(f"{fid}: lookup fact needs desk")
        if r.lookup is None:
            p.append(f"{fid}: lookup fact needs a lookup block")
        if r.status == "demo":
            p.append(f"{fid}: a lookup fact is never status demo (demo values use <id>.demo.<pin>)")
    m = DEMO_ID.match(fid)
    if m and r.status != "demo":
        p.append(f"{fid}: a .demo.<pin> id must have status demo")
    if ".demo." in fid and not m:
        p.append(f"{fid}: demo ids look like <lookup id>.demo.pin-<slug>")
    if r.status == "demo" and f.typed_value is None:
        p.append(f"{fid}: demo fact needs a typed value")
    bad = unknown_topics(r.topics, topics)
    if bad:
        p.append(f"{fid}: unknown topics {bad} (research/topics.yaml)")
    return p


def load_sources(path: Path) -> dict[str, Source]:
    if not path.is_file():
        return {}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    rows = data.get("sources") or []
    if not isinstance(rows, list):
        raise LedgerError([f"{path}: `sources` must be a list"])
    out: dict[str, Source] = {}
    for row in rows:
        if not isinstance(row, dict) or not row.get("id"):
            raise LedgerError([f"{path}: source entry without id: {row!r}"])
        out[str(row["id"])] = Source(str(row["id"]), row.get("publisher"), row.get("url"), row.get("publisher_language"))
    return out


def load_ledger(facts_dir: Path, sources_path: Path, topics: frozenset[str] | None = None) -> Ledger:
    # A missing or empty facts folder is a broken ledger (wrong MYAD_ROOT, bad deploy), never an empty
    # one: an empty ledger would silently turn every answer into a desk (REVIEW r3 M10).
    fact_files = sorted(facts_dir.glob("*.json")) if facts_dir.is_dir() else []
    if not fact_files:
        raise LedgerError([f"{facts_dir}: no ledger fact files (*.json) found"])
    sources = load_sources(sources_path)
    problems: list[str] = []
    ledger = Ledger(sources=sources)
    for path in fact_files:
        try:
            rows = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            problems.append(f"{path.name}: not JSON ({e.msg})")
            continue
        if not isinstance(rows, list):
            problems.append(f"{path.name}: must be a JSON array of facts")
            continue
        for i, row in enumerate(rows):
            try:
                raw = RawFact.model_validate(row)
            except ValidationError as e:
                rid = row.get("id") if isinstance(row, dict) else None
                problems.append(f"{path.name}[{i}] {rid!r}: {e.errors()[0]['loc']} {e.errors()[0]['msg']}")
                continue
            if raw.id in ledger.facts:
                problems.append(f"{raw.id}: duplicate id ({path.name})")
                continue
            typed, why = coerce_value(raw)
            if why:
                ledger.warnings.append(f"{raw.id}: {why}")
            ledger.facts[raw.id] = LedgerFact(raw, typed)
    for f in ledger.facts.values():
        problems += _validate_row(f, sources, topics)
        base = f.demo_base
        if base is not None:
            parent = ledger.facts.get(base)
            if parent is None or not parent.is_lookup:
                problems.append(f"{f.id}: demo value names {base!r}, which is not a lookup fact")
            elif f.typed_value is not None and f.typed_value.type != parent.raw.value_type:
                problems.append(f"{f.id}: demo value is {f.typed_value.type}, lookup says {parent.raw.value_type}")
    if problems:
        raise LedgerError(problems)
    return ledger
