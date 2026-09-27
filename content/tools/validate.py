#!/usr/bin/env python3
"""Validate the myAmericanDream card registry.

Run from anywhere:
    python3 content/tools/validate.py [--content DIR] [--ledger DIR] [--require-ledger]

Checks (every failure is printed; exit code 1 if any):
  * cards, lenses, desks.yaml, and facts-requested.yaml match their JSON Schemas
    (content/schema/*.json, read by the small subset interpreter below);
  * file name equals id; ids are unique;
  * es, en, and ht are present and non-empty for every string, with the same
    {fact:<id>} placeholders and the same number of body paragraphs;
  * card fact_refs equal the placeholders in title/summary/body plus paragraph_facts;
    every placeholder sits in its paragraph's paragraph_facts;
  * every fact_ref exists in facts-requested.yaml; every requested fact is used;
    used_by, card, and desk in that file are truthful; value_type is an ADCore
    FactValue case (quantity/money carry a unit); lookup facts carry a question,
    static facts do not;
  * status-date hold: no month name, date pattern, or year / relative time phrase near a status
    word (TPS, expire, vence, ekspire, Medicaid, CHIP, ...) in any copy or utterance; held
    dates (facts with verified_only: true, value_type date, a note saying unverified) appear
    only in a card's verified_only_refs; a card mentioning TPS ends at an accredited legal-aid
    desk, one mentioning Medicaid/CHIP routes to the benefits desk;
  * a desk is scoped to the card's region pack or a parent of it; country cards cite only
    us/us-fl facts; a card citing a City of Miami fact also cites the municipality answer
    and the county's own fact for the same question (a figure applies only inside the
    jurisdiction of its ledger fact);
  * is_immigration is true whenever a card cites an immigration fact or desk;
    tourist-mode cards are never immigration cards, cite no immigration fact or desk,
    use no immigration wording, and show in stage 1 or 10 (tourist mode hides 2-9);
  * immigration cards and cards citing papers facts are never household scope;
  * no copy holds a digit, price, percent, or spelled-out rule value outside a
    {fact:...} placeholder (heuristic; document, visa-class, and road names allowed);
  * stage cards show exactly one stage and name existing hero cards; lens ids are the
    ADCore OriginLens cases (camelCase) and equal the file name and origin_lens; lens links
    hold in both directions and each attached card gets one origin line; a lens names a real
    desk (never an immigration desk for the tourist lens) and needs_review matches its
    translation_status;
  * `immigration` (the key tools/build_content_bundle.py reads) appears only where
    is_immigration differs from the bundle default (privacy_scope == person-papers), and then
    equals is_immigration;
  * copy never calls a notary a lawyer;
  * utterances exist in es/en/ht (3-8 each), hold no number, phone, price, or placeholder,
    and no utterance points at two cards; actions use the contracts/intent wire shapes:
    call_desk {desk_id} at a desk with a phone fact, open_map {target: {type: desk, desk_id}}
    at a desk with an address fact, or {target: {type: place, fact: {pack_id, fact_id}}}
    for a place fact the card cites;
  * every desk is used, and its fact_refs are exactly <desk-id>.<field> for its contact
    fields, with matching kind and value_type;
  * topics: when research/topics.yaml exists, every tag must be in it; otherwise tags
    outside the seed list warn if requested in topics-requested.yaml and fail if not.

With --ledger DIR the validator also reads research/facts (JSON: a list, one object, or
{"facts": [...]}) and reports how many requested facts the ledger already covers. It also
fails "inline-quote-placeholder" when a {fact:<id>} inline in card or lens copy has a ledger
value that is a string of more than 12 words (a quote renders English inside es/ht; cite such
facts in paragraph_facts only).
Missing facts are warnings unless --require-ledger is given.

Dependencies: Python 3.12 standard library plus PyYAML.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

LANGS = ("en", "es", "ht")
REGION_ORDER = ("us", "us-fl", "us-fl-miamidade", "us-fl-miami")

PLACEHOLDER_RE = re.compile(r"\{fact:([^{}\s]+)\}")
ANY_BRACE_RE = re.compile(r"\{[^{}]*\}")

# Document, visa-class, and road names are identifiers, not values. They may appear inline.
ALLOWED_IDENTIFIERS = re.compile(r"\b(?:I-94|I-20|DS-2019|F-1|M-1|J-1|I-\d{2,3}|SR \d{2,3}|US-\d{1,2})\b")

# Spelled-out rule values: a number word next to a unit. Heuristic by design.
# Words that double as articles ("one", "una", "yon") are left out on purpose.
NUMBER_WORDS = {
    "en": r"(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|ninety|hundred|thousand|dozen|half)",
    "es": r"(?:uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|quince|veinte|treinta|cuarenta|cincuenta|sesenta|noventa|cien|ciento|mil|media|medio)",
    "ht": r"(?:de|twa|kat|senk|sis|sèt|uit|nèf|dis|onz|douz|kenz|ven|trant|karant|senkant|swasant|san|mil|mwatye)",
}
UNIT_WORDS = {
    "en": r"(?:days?|weeks?|months?|years?|hours?|minutes?|miles?|percent|dollars?|cents?|times the)",
    "es": r"(?:días?|semanas?|meses|mes|años?|horas?|minutos?|millas?|por ciento|dólares?|centavos?|veces el)",
    "ht": r"(?:jou|semèn|mwa|lane|ane|èdtan|minit|mil|pousan|dola|santim|fwa)",
}
PERCENT_WORDS = re.compile(r"\b(?:percent|por ciento|porciento|pousan)\b", re.IGNORECASE)
SPELLED_VALUE = {
    lang: re.compile(rf"\b{NUMBER_WORDS[lang]}\s+{UNIT_WORDS[lang]}\b", re.IGNORECASE) for lang in LANGS
}

# ADCore OriginLens cases (Sources/ADCore/Household/Origin.swift, server OriginLensName).
LENS_IDS = ("latinAmerica", "haiti", "leftDriving", "internationalStudent", "tourist", "questionnaire")

# A notary public is never a lawyer. A negation must sit between the two words;
# equivalence wording is unsafe even when it contains no bare positive assertion.
NOTARY_RE = re.compile(r"(?i)\bnot(?:ario|arios|ary|aries|è)\b")
LAWYER_RE = re.compile(r"(?i)\b(?:lawyers?|attorneys?|abogad[oa]s?|avoka)\b")
NEGATION_RE = re.compile(r"(?i)\b(?:not|never|cannot|can't|isn't|no|ni|nunca|jamás|pa|p|janm)\b|n't\b")
NOTARY_SAME_RE = re.compile(r"(?i)\b(?:same as|lo mismo que|menm jan ak)\b")


def notary_lawyer_problem(text: str) -> str | None:
    for sentence in re.split(r"(?<=[.!?:;])\s+|\n+", text):
        notary = NOTARY_RE.search(sentence)
        lawyer = LAWYER_RE.search(sentence)
        if notary and lawyer:
            if NOTARY_SAME_RE.search(sentence):
                return f"equates a notary with a lawyer: {sentence.strip()[:80]!r} (a notary public is never a lawyer)"
            first, second = sorted((notary, lawyer), key=lambda m: m.start())
            if not NEGATION_RE.search(sentence[first.end():second.start()]):
                return f"calls a notary a lawyer: {sentence.strip()[:80]!r} (a notary public is never a lawyer)"
    return None


# Immigration wording that must never reach a tourist-mode card.
IMMIGRATION_WORDS = re.compile(
    r"\b(?:USCIS|SEVIS|TPS|asylum|asilo|azil|green card|tarjeta verde|kat vèt|residencia permanente|"
    r"rezidans pèmanan|parole|permiso de permanencia|notary|notario|notè|visa strategy|immigration|inmigración|"
    r"imigrasyon|deport\w*|deportar|depòte|status|estatus|estati|visa|papers|papeles|papye|"
    r"citizenship|ciudadanía|sitwayènte|ICE|I-94|I-20|DS-2019|EAD|work permit|permiso de trabajo|pèmi travay)\b",
    re.IGNORECASE,
)



# --------------------------------------------------------------------------------------
# Minimal JSON Schema (2020-12 subset) interpreter: type, enum, const, required,
# properties, additionalProperties, items, minItems, uniqueItems, minLength, pattern,
# minimum, maximum, anyOf, $ref (same file or sibling file).
# --------------------------------------------------------------------------------------
class SchemaStore:
    def __init__(self, schema_dir: Path):
        self.schema_dir = schema_dir
        self._cache: dict[str, dict] = {}

    def load(self, name: str) -> dict:
        if name not in self._cache:
            self._cache[name] = json.loads((self.schema_dir / name).read_text(encoding="utf-8"))
        return self._cache[name]

    def resolve(self, ref: str, current: str) -> tuple[dict, str]:
        file_part, _, pointer = ref.partition("#")
        doc_name = file_part or current
        node: Any = self.load(doc_name)
        for part in [p for p in pointer.split("/") if p]:
            node = node[part]
        return node, doc_name


_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


def _type_ok(value: Any, expected: str) -> bool:
    if expected in ("integer", "number") and isinstance(value, bool):
        return False
    return isinstance(value, _TYPES[expected])


def schema_errors(value: Any, schema: dict, store: SchemaStore, doc: str, path: str = "$") -> list[str]:
    errs: list[str] = []
    if "$ref" in schema:
        target, target_doc = store.resolve(schema["$ref"], doc)
        return schema_errors(value, target, store, target_doc, path)
    if "anyOf" in schema:
        if not any(not schema_errors(value, sub, store, doc, path) for sub in schema["anyOf"]):
            errs.append(f"{path}: does not match any allowed shape")
        return errs
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(value, t) for t in types):
            return [f"{path}: expected {'/'.join(types)}, got {type(value).__name__}"]
    if "const" in schema and value != schema["const"]:
        errs.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errs.append(f"{path}: {value!r} not one of {schema['enum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value.strip()) < schema["minLength"]:
            errs.append(f"{path}: empty string")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errs.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errs.append(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errs.append(f"{path}: above maximum {schema['maximum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errs.append(f"{path}: needs at least {schema['minItems']} item(s)")
        if schema.get("uniqueItems"):
            seen = [json.dumps(v, sort_keys=True) for v in value]
            if len(seen) != len(set(seen)):
                errs.append(f"{path}: items must be unique")
        if "items" in schema:
            for i, item in enumerate(value):
                errs += schema_errors(item, schema["items"], store, doc, f"{path}[{i}]")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errs.append(f"{path}: missing required field {key!r}")
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key in props:
                errs += schema_errors(sub, props[key], store, doc, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                errs.append(f"{path}: unknown field {key!r}")
            elif isinstance(schema.get("additionalProperties"), dict):
                errs += schema_errors(sub, schema["additionalProperties"], store, doc, f"{path}.{key}")
    return errs


# --------------------------------------------------------------------------------------
# Content model helpers
# --------------------------------------------------------------------------------------
# ADCore FactValue cases (ARCHITECTURE.md 13.z). No number, url, or verbatim.
VALUE_TYPES = ("text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag")
DESK_FIELD_TYPES = {"name": "code", "phone": "phone", "url": "code", "address": "place",
                    "hours": "text", "languages": "codes"}
MUNICIPALITY_FACT = "us-fl-miamidade.gov.municipality"
# Research's seed vocabulary; research/topics.yaml, when present, is the only authority.
SEED_TOPICS = ("trash", "schools", "parcel", "water", "parks", "libraries", "voting", "representatives",
               "transit", "tolls", "rent", "legal-aid", "desk", "immigration", "tps", "license", "municipality")


def region_of(dotted_id: str) -> str:
    return dotted_id.split(".", 1)[0]


REGION_PARENTS = {
    "us": None,
    "us-fl": "us",
    "us-fl-miamidade": "us-fl",
    "us-fl-miami": "us-fl-miamidade",
}


def region_covers(outer: str, inner: str) -> bool:
    """True if `outer` is `inner` or an explicit parent pack of it."""
    if outer not in REGION_PARENTS or inner not in REGION_PARENTS:
        return False
    current = inner
    while current is not None:
        if current == outer:
            return True
        current = REGION_PARENTS[current]
    return False


# Copy that asserts the value a placeholder should supply ("answers in Creole: {fact:...languages}").
# Write "languages the desk answers in: {fact:...}" instead.
ASSERTED_VALUE_RE = re.compile(
    r"(?i)\b(?:in|en|an)\s+(?:creole|criollo|kreyòl|kreyol|spanish|español|espanyòl|panyòl|english|inglés|anglè)\s*:\s*"
    r"\{fact:[^{}]*\.languages\}")


def copy_problems(text: str) -> list[str]:
    """Digit / value heuristic for one localized string (placeholders removed first)."""
    problems = []
    m = ASSERTED_VALUE_RE.search(text)
    if m:
        problems.append(f"copy asserts what the placeholder should supply: {m.group(0)!r}; "
                        "write 'languages ...: {fact:...}'")
    stripped = PLACEHOLDER_RE.sub(" ", text)
    leftover = ANY_BRACE_RE.findall(stripped)
    if leftover:
        problems.append(f"unknown placeholder {leftover[0]!r} (only {{fact:<id>}} is allowed)")
    stripped = ALLOWED_IDENTIFIERS.sub(" ", ANY_BRACE_RE.sub(" ", stripped))
    digits = re.findall(r"\d[\d,.:/-]*", stripped)
    if digits:
        problems.append(f"inline digits {digits[0]!r}; use a {{fact:...}} placeholder")
    if "$" in stripped or "%" in stripped:
        problems.append("inline price or percent sign; use a {fact:...} placeholder")
    return problems


# Firstmate hold on status dates: no month name, no date pattern, and no year or relative time
# phrase near status words, in any language (code-switching included).
MONTH_RE = re.compile(
    r"\b(?:January|February|March|April|June|July|August|September|October|November|December)\b"
    r"|\b(?:Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s*(?=\d|\{fact)"
    r"|\bMay\b(?=\s*(?:\d|\{fact))|\b(?:in|of|since|until|by|before|after|early|late|mid)\s+May\b"
    r"|(?i:\b(?:enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre)\b)"
    r"|(?i:\b(?:janvye|fevriye|avril|jiy[eè]|septanm|okt[oò]b|novanm|desanm)\b)"
    r"|(?i:\bmwa\s+(?:me|jen|out|mas)\b)|(?i:\b(?:me|jen|out|mas)\s+(?=\d|\{fact))")
DATE_RE = re.compile(r"\b\d{1,2}[/.-]\d{1,2}(?:[/.-]\d{2,4})?\b|\b\d{4}-\d{1,2}-\d{1,2}\b")
STATUS_WORDS_RE = re.compile(
    r"(?i)\b(?:TPS|status|estatus|estati|visa|permiso|expir\w*|venc\w*|ekspire\w*|ekspirasyon|re-?regist\w*|reinscri\w*|re-?enskri\w*"
    r"|Medicaid|CHIP|parole|EAD|Ha[iï]t[ií]|Ayiti|Venezuela)\b")
STATUS_HOLD_COPY_RE = re.compile(
    r"(?i)\b(?:leave|depart|bill|Congress|restore|congreso|restaurar|lwa)\b"
    r"|\bsalir\s+del\s+pa[ií]s\b|\bkite\s+peyi\s+a\b"
    r"|\bvalid\s+(?:until|through)\b|\bv[aá]lido\s+hasta\b|\bvalab\s+jiska\b")
YEAR_RE = re.compile(r"\b(?:19|20)\d{2}\b")
RELATIVE_TIME_RE = re.compile(
    r"(?i)\b(?:this|last|next|past)\s+(?:summer|spring|fall|autumn|winter|month|year)\b"
    r"|\b(?:este|el|pr[oó]ximo)\s+(?:verano|invierno|oto[nñ]o|primavera)\b|\b(?:el\s+)?(?:mes|a[nñ]o)\s+(?:pasado|que\s+viene)\b"
    r"|\b(?:ete|ivè|prentan|lotòn|mwa|ane)\s+(?:sa\s+a|pase|pwochen)\b"
    r"|\brecent(?:ly)?\b|\bjust\s+(?:changed|ended|extended)\b|\bhace\s+poco\b|\breciente(?:mente)?\b"
    r"|\bdènyèman\b|\bfenk\s+(?:chanje|fini)\b")
ACCREDITED_DESKS = ("us.accredited-legal-help", "us-fl-miamidade.immigration-legal-aid")
BENEFITS_DESK = "us-fl.dcf-access"


def status_date_problems(text: str) -> list[str]:
    problems = []
    text = PLACEHOLDER_RE.sub("{fact}", text)
    m = MONTH_RE.search(text)
    if m:
        problems.append(f"month name {m.group(0).strip()!r} (status-date hold: no months in copy)")
    m = DATE_RE.search(text)
    if m:
        problems.append(f"date pattern {m.group(0)!r} (status-date hold)")
    for paragraph in re.split(r"\n\s*\n", text):
        if STATUS_WORDS_RE.search(paragraph):
            y = YEAR_RE.search(paragraph)
            if y:
                problems.append(f"year {y.group(0)!r} near a status word (status-date hold)")
            r = RELATIVE_TIME_RE.search(paragraph)
            if r:
                problems.append(f"relative date {r.group(0)!r} near a status word (status-date hold)")
            forbidden = STATUS_HOLD_COPY_RE.search(paragraph)
            if forbidden:
                problems.append(f"status-date hold wording {forbidden.group(0)!r} near a status word")
    return problems


def mentions(loc_or_list, rx) -> bool:
    if isinstance(loc_or_list, dict):
        values = [v for v in loc_or_list.values() if isinstance(v, str)]
    else:
        values = list(loc_or_list)
    return any(rx.search(v) for v in values)


TPS_RE = re.compile(r"\bTPS\b")
MEDICAID_RE = re.compile(r"\b(?:Medicaid|CHIP)\b")

# D8 status vocabulary. Plural forms are optional suffixes. Creole "parol" alone also means
# "word/speech", so ht matches only the exact tokens "parole" and "parol imanitè" (humanitarian
# parole), never a bare "parol".
D8_LOCALIZED_RES = {
    "en": re.compile(r"(?i)\b(?:status(?:es)?|lawful presence|parole[ds]?|parolees?)\b"),
    "es": re.compile(r"(?i)\b(?:estatus|estados? migratorios?|situaci(?:ó|o)n(?:es)? migratorias?|presencia legal"
                     r"|permiso de permanencia|parole)\b"),
    "ht": re.compile(r"(?i)\b(?:estati|prezans legal|parole|parol imanit(?:è|e)|sitiyasyon imigrasyon)\b"),
}
# Status acronyms: case-insensitive and word-bounded in every locale, in copy and in utterances
# (users type "mi tps" / "tps mwen" in lowercase).
D8_STATUS_ACRONYM_RE = re.compile(r"(?i)\b(?:CPT|OPT|DSO|TPS|DACA|EAD)\b")
# Exact-phrase D8 exemptions: tax wording, not immigration status. Only these literal phrases
# are removed before scanning (en "filing status", ht "estati deklarasyon"). The es card says
# "forma de declarar", which holds no D8 word, so es needs no exemption.
D8_EXEMPT_PHRASES_RE = re.compile(r"(?i)\bfiling status\b|\bestati deklarasyon\b")
# The one placeholder exemption: this exact LIHEAP placeholder only. Every other {fact:...}
# placeholder stays in the scanned text, so a fact id such as "...status" still needs the link.
D8_EXEMPT_PLACEHOLDER = "{fact:us-fl.liheap.household-status-requirement}"

# D5 (Haiti-linked cards). Two tiers:
#   * always: future-change, next-step wording;
#   * status context: broad words that also have everyday meanings (restore power, the bus
#     leaves, a ticket window) fail only when the same sentence holds a status word (D8
#     vocabulary, TPS/EAD/..., STATUS_WORDS_RE such as visa/expire/Haiti) or papers/papeles/papye.
#     "leave/salir/kite + the country" fails even without other context.
D5_ALWAYS_RE = re.compile(
    r"(?i)\b(?:(?:can|may|could|might|will|would)\s+change"
    r"|next\s+steps?"
    r"|(?:puede|pueden|podr[ií]a|podr[ií]an)\s+cambiar"
    r"|pr[oó]ximos?\s+pasos?"
    r"|(?:ka|kab|kapab|pral)\s+chanje"
    r"|pwochen\s+etap(?:\s+yo)?)\b"
)
_D5_LEAVE = (r"(?:(?:must|have\s+to|has\s+to|had\s+to|need\s+to|needs\s+to|will\s+have\s+to)\s+leave"
             r"|(?:debe|debes|deben|debemos|deber[aá]n?)\s+salir|(?:tiene|tienes|tienen)\s+que\s+salir|hay\s+que\s+salir"
             r"|(?:dwe|oblije|f[oò]k(?:\s+(?:ou|w|nou|yo|li|m|mwen))?)\s+(?:kite|soti))")
D5_CONTEXT_RE = re.compile(
    r"(?i)\b(?:" + _D5_LEAVE +
    r"|restor(?:e|es|ed|ing|ation)?|restablec\w*|restaur\w*|retabli\w*"
    r"|windows?|ventanas?|fen[eè]t)\b"
)
D5_LEAVE_COUNTRY_RE = re.compile(
    r"(?i)\b" + _D5_LEAVE + r"\s+(?:the\s+|this\s+)?(?:country|U\.?S\.?|United\s+States"
    r"|(?:de\s+|del\s+)?(?:el\s+|este\s+)?pa[ií]s|(?:de\s+)?(?:los\s+)?Estados\s+Unidos|peyi(?:\s+a)?|Etazini)\b"
)
D5_PAPERS_RE = re.compile(r"(?i)\b(?:papers|papeles|papye)\b")
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+|\n+")


def _status_context(sentence: str) -> bool:
    return bool(STATUS_WORDS_RE.search(sentence) or D5_PAPERS_RE.search(sentence)
                or D8_STATUS_ACRONYM_RE.search(sentence)
                or any(rx.search(sentence) for rx in D8_LOCALIZED_RES.values()))


def d5_haiti_problems(text: str) -> list[str]:
    problems = [f"D5: prohibited Haiti wording {m.group(0)!r}" for m in D5_ALWAYS_RE.finditer(text)]
    for sentence in SENTENCE_SPLIT_RE.split(text):
        leave_country = D5_LEAVE_COUNTRY_RE.search(sentence)
        context = _status_context(sentence)
        for m in D5_CONTEXT_RE.finditer(sentence):
            if context or (leave_country and leave_country.start() == m.start()):
                problems.append(f"D5: prohibited Haiti wording {m.group(0)!r} (status context)")
    return problems


def _d8_text(text: str) -> str:
    # Remove only the exact LIHEAP placeholder and the exact tax phrases; every other
    # placeholder (its id text included) is scanned.
    text = text.replace(D8_EXEMPT_PLACEHOLDER, " ")
    return D8_EXEMPT_PHRASES_RE.sub(" ", text)


def _d8_text_used(text: str, lang: str | None = None) -> bool:
    text = _d8_text(text)
    localized = D8_LOCALIZED_RES[lang].search(text) if lang in D8_LOCALIZED_RES else any(
        rx.search(text) for rx in D8_LOCALIZED_RES.values()
    )
    return bool(localized or D8_STATUS_ACRONYM_RE.search(text))


def _localized_copy_values(card: dict):
    for key in ("title", "summary", "body"):
        localized = card.get(key) or {}
        if isinstance(localized, dict):
            for lang in LANGS:
                value = localized.get(lang)
                if isinstance(value, str):
                    yield lang, value
    for action in card.get("actions") or []:
        for key in ("label", "labels"):
            label = action.get(key)
            if isinstance(label, dict):
                for lang in LANGS:
                    value = label.get(lang)
                    if isinstance(value, str):
                        yield lang, value
            elif isinstance(label, str):
                yield None, label
    for lang in LANGS:
        for utterance in (card.get("utterances") or {}).get(lang) or []:
            if isinstance(utterance, str):
                yield lang, utterance


def d8_status_word_used(card: dict) -> bool:
    return any(_d8_text_used(value, lang) for lang, value in _localized_copy_values(card))


def check_haiti_copy(card: dict, where: str, report: Report) -> None:
    for key in ("title", "summary", "body"):
        for lang in LANGS:
            for problem in d5_haiti_problems((card.get(key) or {}).get(lang, "")):
                report.err(f"{where}.{key}.{lang}", problem)
    for action_i, action in enumerate(card.get("actions") or []):
        for label_key in ("label", "labels"):
            label = action.get(label_key)
            if isinstance(label, dict):
                for lang in LANGS:
                    for problem in d5_haiti_problems(label.get(lang, "")):
                        report.err(f"{where}.actions[{action_i}].{label_key}.{lang}", problem)
            elif isinstance(label, str):
                for problem in d5_haiti_problems(label):
                    report.err(f"{where}.actions[{action_i}].{label_key}", problem)
    for lang in LANGS:
        for i, utterance in enumerate((card.get("utterances") or {}).get(lang) or []):
            for problem in d5_haiti_problems(utterance):
                report.err(f"{where}.utterances.{lang}[{i}]", problem)


def spelled_problems(text: str, lang: str) -> list[str]:
    stripped = PLACEHOLDER_RE.sub(" ", text)
    problems = []
    m = SPELLED_VALUE[lang].search(stripped)
    if m:
        problems.append(f"spelled-out value {m.group(0)!r}; use a {{fact:...}} placeholder")
    if PERCENT_WORDS.search(stripped):
        problems.append("the word 'percent' outside a placeholder")
    return problems


def paragraphs(text: str) -> list[str]:
    return [p for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]


def placeholders(text: str) -> list[str]:
    return PLACEHOLDER_RE.findall(text or "")


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    info: list[str] = field(default_factory=list)

    def err(self, where: str, msg: str) -> None:
        self.errors.append(f"{where}: {msg}")

    def warn(self, where: str, msg: str) -> None:
        self.warnings.append(f"{where}: {msg}")


def load_yaml(path: Path, report: Report) -> Any:
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        report.err(str(path), f"YAML parse error: {exc}")
        return None


def check_localized(where: str, loc: dict, report: Report) -> None:
    """Parity, digit heuristic, and identical placeholders across es/en/ht."""
    # The official 988 desk names must speak the hotline number in each language;
    # this is the one intentional inline-number exception to the placeholder heuristic.
    allow_988_number = where == "desks.yaml:us.988.name"
    for lang in LANGS:
        value = loc.get(lang)
        if not isinstance(value, str) or not value.strip():
            report.err(where, f"missing or empty {lang}")
            continue
        problems = copy_problems(value) + spelled_problems(value, lang) + status_date_problems(value)
        for problem in problems:
            if allow_988_number and problem == "inline digits '988'; use a {fact:...} placeholder":
                continue
            report.err(f"{where}.{lang}", problem)
        notary = notary_lawyer_problem(value)
        if notary:
            report.err(f"{where}.{lang}", notary)
    found = {lang: sorted(placeholders(loc.get(lang) or "")) for lang in LANGS}
    if len({tuple(v) for v in found.values()}) > 1:
        report.err(where, f"placeholders differ between languages: {found}")


def localized_placeholders(loc: dict) -> set[str]:
    return {p for lang in LANGS for p in placeholders(loc.get(lang) or "")}


def has_immigration_wording(loc: dict) -> str | None:
    for lang in LANGS:
        if IMMIGRATION_WORDS.search(loc.get(lang) or ""):
            return lang
    return None


# --------------------------------------------------------------------------------------
# Main validation
# --------------------------------------------------------------------------------------
def load_topic_vocab(path: Path | None, report: Report) -> set[str] | None:
    """research/topics.yaml: a list, or {topics: [...]}, of strings or {id|tag|name: ...} maps."""
    if path is None or not path.exists():
        return None
    data = load_yaml(path, report)
    items = data.get("topics", []) if isinstance(data, dict) else (data or [])
    vocab = set()
    for item in items:
        if isinstance(item, str):
            vocab.add(item)
        elif isinstance(item, dict):
            for key in ("id", "tag", "name"):
                if isinstance(item.get(key), str):
                    vocab.add(item[key])
                    break
    return vocab


def validate(content_dir: Path, ledger_dir: Path | None = None, require_ledger: bool = False,
             topics_path: Path | None = None) -> Report:
    report = Report()
    store = SchemaStore(content_dir / "schema")
    if topics_path is None:
        topics_path = content_dir.resolve().parent / "research" / "topics.yaml"
    vocab = load_topic_vocab(topics_path, report)
    requested_topics: dict[str, str] = {}
    tr_path = content_dir / "topics-requested.yaml"
    if tr_path.exists():
        tr = load_yaml(tr_path, report) or {}
        for item in tr.get("requested") or []:
            if not (isinstance(item, dict) and isinstance(item.get("tag"), str) and str(item.get("meaning", "")).strip()):
                report.err("topics-requested.yaml", f"entry needs tag and a one-line meaning: {item!r}")
                continue
            if item["tag"] in SEED_TOPICS:
                report.err("topics-requested.yaml", f"{item['tag']} is already a seed tag")
            requested_topics[item["tag"]] = item["meaning"]
    used_topics: set[str] = set()

    def check_topics(where: str, tags) -> None:
        for tag in tags or []:
            used_topics.add(tag)
            if vocab is not None:
                if tag not in vocab:
                    if tag in requested_topics:
                        report.warn(where, f"topic {tag!r} pending Research (content/topics-requested.yaml)")
                    else:
                        report.err(where, f"topic {tag!r} is not in {topics_path.name} or topics-requested.yaml")
            elif tag not in SEED_TOPICS:
                if tag in requested_topics:
                    report.warn(where, f"topic {tag!r} pending Research (content/topics-requested.yaml)")
                else:
                    report.err(where, f"topic {tag!r} is not a seed tag and not in topics-requested.yaml")

    # facts-requested.yaml ------------------------------------------------------------
    facts_path = content_dir / "facts-requested.yaml"
    facts_doc = load_yaml(facts_path, report) if facts_path.exists() else None
    if facts_doc is None:
        report.err("facts-requested.yaml", "missing or unreadable")
        facts_doc = {"requested": []}
    else:
        for e in schema_errors(facts_doc, store.load("facts-requested.schema.json"), store, "facts-requested.schema.json"):
            report.err("facts-requested.yaml", e)
    facts: dict[str, dict] = {}
    for fact in facts_doc.get("requested") or []:
        if not isinstance(fact, dict):
            continue
        fid = fact.get("id")
        where = f"facts-requested.yaml:{fid}"
        if fid in facts:
            report.err("facts-requested.yaml", f"duplicate fact id {fid}")
        facts[fid] = fact
        if fact.get("value_type") not in VALUE_TYPES:
            report.err(where, f"value_type {fact.get('value_type')!r} is not an ADCore FactValue case {VALUE_TYPES}")
        if fact.get("value_type") in ("quantity", "money") and not fact.get("unit"):
            report.err(where, f"{fact.get('value_type')} fact needs a unit")
        if fact.get("kind") == "lookup" and not fact.get("question"):
            report.err(where, "lookup fact needs a question")
        if fact.get("kind") == "static" and ("question" in fact or "endpoint" in fact):
            report.err(where, "static fact must not carry question/endpoint")
        if fact.get("plan_text") is None and not fact.get("content_added_reason"):
            report.err(where, "no plan_text: give content_added_reason")
        if fact.get("verified_only"):
            if fact.get("value_type") != "date":
                report.err(where, "verified_only facts are status dates: value_type must be date")
            if "unverified" not in str(fact.get("note", "")):
                report.err(where, "verified_only fact needs a note saying it is unverified and which primary source is required")
        check_topics(where, fact.get("topics"))

    uses: dict[str, set[str]] = {}
    related_cards: dict[str, set[str]] = {}

    def use(fid: str, user: str, where: str, region: str | None, card_id: str | None) -> None:
        uses.setdefault(fid, set()).add(user)
        if card_id:
            related_cards.setdefault(fid, set()).add(card_id)
        if fid not in facts:
            report.err(where, f"fact {fid} is not in facts-requested.yaml")
        if region == "country-card" and region_of(fid) not in ("us", "us-fl"):
            report.err(where, f"country card cites local fact {fid}; country cards stay us/us-fl")

    # desks.yaml -----------------------------------------------------------------------
    desks: dict[str, dict] = {}
    desks_path = content_dir / "desks.yaml"
    desks_doc = load_yaml(desks_path, report) if desks_path.exists() else None
    if desks_doc is None:
        report.err("desks.yaml", "missing or unreadable")
    else:
        for e in schema_errors(desks_doc, store.load("desks.schema.json"), store, "desks.schema.json"):
            report.err("desks.yaml", e)
        for desk in desks_doc.get("desks") or []:
            did = desk.get("id")
            if did in desks:
                report.err("desks.yaml", f"duplicate desk id {did}")
            desks[did] = desk
            dwhere = f"desks.yaml:{did}"
            if isinstance(desk.get("name"), dict):
                check_localized(f"{dwhere}.name", desk["name"], report)
                if localized_placeholders(desk["name"]):
                    report.err(dwhere, "desk names hold no placeholders; contact details are <desk-id>.<field> facts")
            expected = [f"{did}.{f}" for f in desk.get("contact_fields") or []]
            if list(desk.get("fact_refs") or []) != expected:
                report.err(dwhere, f"fact_refs must be exactly {expected}")
            for fname in desk.get("contact_fields") or []:
                fact = facts.get(f"{did}.{fname}")
                if fact is None:
                    continue
                if fact.get("kind") != desk.get("contact_kind"):
                    report.err(dwhere, f"{did}.{fname} kind {fact.get('kind')!r} != contact_kind {desk.get('contact_kind')!r}")
                if fact.get("value_type") != DESK_FIELD_TYPES[fname]:
                    report.err(dwhere, f"{did}.{fname} value_type should be {DESK_FIELD_TYPES[fname]}")
            check_topics(dwhere, desk.get("topics"))

    # cards ----------------------------------------------------------------------------
    card_schema = store.load("card.schema.json")
    cards: dict[str, dict] = {}
    for path in sorted((content_dir / "cards").glob("*.yaml")):
        where = f"cards/{path.name}"
        card = load_yaml(path, report)
        if not isinstance(card, dict):
            report.err(where, "not a mapping")
            continue
        schema_errs = schema_errors(card, card_schema, store, "card.schema.json")
        for e in schema_errs:
            report.err(where, e)
        cid = card.get("id")
        if cid != path.stem:
            report.err(where, f"id {cid!r} does not match file name")
        if cid in cards:
            report.err(where, f"duplicate card id {cid}")
        cards[cid] = card
        if not schema_errs:
            check_card(card, where, facts, desks, report, use)
            check_topics(where, card.get("topics"))

    seen_utterances: dict[tuple[str, str], str] = {}
    for cid, card in cards.items():
        for lang in LANGS:
            for u in (card.get("utterances") or {}).get(lang) or []:
                norm = re.sub(r"[^\w]+", " ", u.lower()).strip()
                other = seen_utterances.get((lang, norm))
                if other and other != cid:
                    report.err(f"cards/{cid}.yaml", f"utterance {u!r} ({lang}) also used by card {other}")
                seen_utterances[(lang, norm)] = cid
    used_desks = {c.get("desk") for c in cards.values()} | {
        action_desk(a) for c in cards.values() for a in (c.get("actions") or []) if isinstance(a, dict)}
    for did in desks:
        if did not in used_desks:
            report.err(f"desks.yaml:{did}", "desk is not used by any card")
    for cid, card in cards.items():
        for ref in (card.get("hero_cards") or []) + (card.get("related_cards") or []):
            if ref not in cards:
                report.err(f"cards/{cid}.yaml", f"links to unknown card {ref}")
            elif ref == cid:
                report.err(f"cards/{cid}.yaml", "links to itself")

    # desk contact facts count as used, and relate to every card ending at that desk
    for did, desk in desks.items():
        enders = [cid for cid, c in cards.items() if c.get("desk") == did or any(
            isinstance(a, dict) and (a.get("desk_id") == did or (a.get("target") or {}).get("desk_id") == did)
            for a in c.get("actions") or [])]
        for fid in desk.get("fact_refs") or []:
            use(fid, f"desk:{did}", f"desks.yaml:{did}", region_of(did), None)
            for cid in enders:
                related_cards.setdefault(fid, set()).add(cid)

    # lenses ---------------------------------------------------------------------------
    lens_schema = store.load("lens.schema.json")
    lenses: dict[str, dict] = {}
    for path in sorted((content_dir / "lenses").glob("*.yaml")):
        where = f"lenses/{path.name}"
        lens = load_yaml(path, report)
        if not isinstance(lens, dict):
            report.err(where, "not a mapping")
            continue
        errs = schema_errors(lens, lens_schema, store, "lens.schema.json")
        for e in errs:
            report.err(where, e)
        lid = lens.get("id")
        if lid != path.stem:
            report.err(where, f"id {lid!r} does not match file name")
        lenses[lid] = lens
        if not errs:
            check_lens(lens, where, cards, facts, desks, report, use)
    # D5 covers every card attached by the Haiti lens, including status-word.
    haiti_cards = {cid for cid, card in cards.items()
                   if "haiti" in cid or "haiti" in (card.get("origin_lenses") or [])}
    haiti_lens = lenses.get("haiti")
    if haiti_lens:
        haiti_cards.update(haiti_lens.get("attaches_to") or [])
    for cid in sorted(haiti_cards):
        if cid in cards:
            check_haiti_copy(cards[cid], f"cards/{cid}.yaml", report)

    seen_enum: dict[str, str] = {}
    for lid, lens in lenses.items():
        case = lens.get("origin_lens")
        if case in seen_enum:
            report.err(f"lenses/{lid}.yaml", f"origin_lens {case} already used by {seen_enum[case]}")
        seen_enum[case] = lid
    for cid, card in cards.items():
        for lid in card.get("origin_lenses") or []:
            if lid not in lenses:
                report.err(f"cards/{cid}.yaml", f"unknown origin lens {lid}")
            elif cid not in lenses[lid].get("attaches_to", []) and lenses[lid].get("lens_card") != cid:
                report.err(f"cards/{cid}.yaml", f"lens {lid} does not attach to this card")

    # Tourist cards are visible only at endpoint stages and may relate only to other
    # tourist-visible cards (D1). The target-card check is cross-card, after loading all cards.
    for cid, card in cards.items():
        if "tourist" not in (card.get("modes") or []):
            continue
        bad_stages = sorted(set(card.get("stages") or []) - {1, 10})
        if bad_stages:
            report.err(f"cards/{cid}.yaml", f"tourist-mode card has hidden stages {bad_stages}; only stages 1 and 10 are allowed")
        for ref in card.get("related_cards") or []:
            target = cards.get(ref)
            if target is not None and "tourist" not in (target.get("modes") or []):
                report.err(f"cards/{cid}.yaml", f"tourist-mode card related_cards includes non-tourist card {ref}")

    # every requested fact is used, used_by is truthful, card/desk fields point somewhere real
    for fid, fact in facts.items():
        where = f"facts-requested.yaml:{fid}"
        actual = uses.get(fid, set())
        if not actual:
            report.err(where, "requested but never referenced")
            continue
        if set(fact.get("used_by") or []) != actual:
            report.err(where, f"used_by should be {sorted(actual)}")
        if fact.get("card") not in related_cards.get(fid, set()):
            report.err(where, f"card {fact.get('card')!r} does not show this fact (expected one of {sorted(related_cards.get(fid, set()))})")
        if fact.get("desk") not in desks:
            report.err(where, f"unknown desk {fact.get('desk')!r}")

    if ledger_dir is not None:
        ledger = load_ledger(ledger_dir, report)
        if ledger is not None:
            check_ledger(ledger_dir, facts, report, require_ledger, ledger)
            check_inline_quotes(cards, lenses, ledger, report)

    report.info.append(
        f"{len(cards)} cards, {len(lenses)} lenses, {len(facts)} requested facts "
        f"({sum(1 for f in facts.values() if f.get('kind') == 'lookup')} lookup), {len(desks)} desks"
    )
    return report


def action_desk(action: dict) -> str | None:
    """Desk id of a call_desk or open_map(.desk) action in the contracts/intent wire shape."""
    if action.get("type") == "call_desk":
        return action.get("desk_id")
    target = action.get("target")
    if action.get("type") == "open_map" and isinstance(target, dict) and target.get("type") == "desk":
        return target.get("desk_id")
    return None


def check_card(card: dict, where: str, facts: dict, desks: dict, report: Report, use) -> None:
    cid = card["id"]
    region = card["region_pack"]
    kind = card["kind"]
    tourist = "tourist" in card["modes"]

    for key in ("title", "summary", "body"):
        check_localized(f"{where}.{key}", card[key], report)

    # paragraphs: same count in every language, and parallel editorial traces
    counts = {lang: len(paragraphs(card["body"][lang])) for lang in LANGS}
    if len(set(counts.values())) != 1:
        report.err(f"{where}.body", f"paragraph count differs between languages: {counts}")
    elif counts["en"] != len(card["paragraph_facts"]):
        report.err(where, f"paragraph_facts has {len(card['paragraph_facts'])} lists for {counts['en']} paragraphs")
    else:
        for i, refs in enumerate(card["paragraph_facts"]):
            shown = {p for lang in LANGS for p in placeholders(paragraphs(card["body"][lang])[i])}
            missing = shown - set(refs)
            if missing:
                report.err(f"{where}.body[{i}]", f"placeholders not in paragraph_facts[{i}]: {sorted(missing)}")
    paragraph_when = card.get("paragraph_when")
    if paragraph_when is not None and len(paragraph_when) != counts["en"]:
        report.err(where, f"paragraph_when has {len(paragraph_when)} items for {counts['en']} paragraphs")

    used = set(localized_placeholders(card["title"])) | localized_placeholders(card["summary"])
    used |= localized_placeholders(card["body"])
    for refs in card["paragraph_facts"]:
        used |= set(refs)
    if set(card["fact_refs"]) != used:
        extra = sorted(set(card["fact_refs"]) - used)
        missing = sorted(used - set(card["fact_refs"]))
        report.err(where, f"fact_refs must equal placeholders + paragraph_facts (missing {missing}, extra {extra})")
    for fid in sorted(used):
        use(fid, f"card:{cid}", where, "country-card" if kind == "country" else None, cid)
        if facts.get(fid, {}).get("verified_only"):
            report.err(where, f"{fid} is a held status date: list it in verified_only_refs, never in copy or fact_refs")

    # bundle mirrors (tools/build_content_bundle.py reads `immigration`, defaulting it to
    # privacy_scope == person-papers, and `needs_review`)
    bundle_default = card["privacy_scope"] == "person-papers"
    if "immigration" in card:
        if card["immigration"] != card["is_immigration"]:
            report.err(where, "immigration must equal is_immigration (the bundle compiler reads `immigration`)")
        elif card["is_immigration"] == bundle_default:
            report.err(where, "drop the duplicate `immigration` key: the bundle default (privacy_scope == person-papers) already equals is_immigration")
    elif card["is_immigration"] != bundle_default:
        report.err(where, f"set `immigration: {str(card['is_immigration']).lower()}`: the bundle compiler would default it "
                          f"to {str(bundle_default).lower()} from privacy_scope {card['privacy_scope']}")
    expect_nr = {"en": False, **{l: card["translation_status"].get(l) != "reviewed" for l in ("es", "ht")}}
    if card.get("needs_review") != expect_nr:
        report.err(where, f"needs_review must be {expect_nr} to match translation_status")

    # status-date hold: gated refs, and TPS / Medicaid-CHIP cards route to the right desk
    for fid in card.get("verified_only_refs") or []:
        use(fid, f"card:{cid}", where, None, cid)
        fact = facts.get(fid)
        if fact is not None and not fact.get("verified_only"):
            report.err(where, f"verified_only_refs names {fid}, which is not marked verified_only in facts-requested.yaml")
        if fid in used:
            report.err(where, f"{fid} is in verified_only_refs and also in copy/fact_refs")
    copy_fields = [card["title"], card["summary"], card["body"]] + [card["utterances"][l] for l in LANGS]
    # D8 is deliberately link-required (stricter than the brief's define-or-link rule)
    # so CI remains deterministic across translations.
    if cid != "status-word" and d8_status_word_used(card) and "status-word" not in (card.get("related_cards") or []):
        report.err(where, "D8: status word used without link to status-word")
    actions = card.get("actions") or []
    offered = {action_desk(a) for a in actions} - {None}
    call_desks = {a.get("desk_id") for a in actions if a.get("type") == "call_desk"}
    if card["is_immigration"] and card["desk"] not in ACCREDITED_DESKS and \
            not (set(call_desks) & (set(ACCREDITED_DESKS) | {"us-fl-miamidade.immigration-legal-aid"})):
        report.err(where, "is_immigration card must end at an accredited desk or call one")
    if cid in {"lease-basics", "eviction-clock", "medical-bill"} and card["desk"] != "us-fl-miamidade.legal-aid":
        report.err(where, f"{cid} must end at us-fl-miamidade.legal-aid")
    if cid == "health-coverage-changes":
        if card["desk"] != BENEFITS_DESK:
            report.err(where, f"health-coverage-changes must end at {BENEFITS_DESK}")
        for required in ("us-fl.dcf-access", "us-fl.kidcare"):
            if required not in call_desks:
                report.err(where, f"health-coverage-changes must call_desk {required}")
    if any(mentions(f, TPS_RE) for f in copy_fields) and card["desk"] not in ACCREDITED_DESKS:
        report.err(where, f"card mentions TPS: desk must be an accredited legal-aid desk {ACCREDITED_DESKS}")
    if any(mentions(f, MEDICAID_RE) for f in copy_fields) and BENEFITS_DESK not in ({card["desk"]} | offered):
        report.err(where, f"card mentions Medicaid/CHIP: route to the benefits desk {BENEFITS_DESK}")

    # jurisdiction: municipality conditions belong to the paragraph that cites the fact;
    # a card-wide municipality fact is not enough. County rent/trash facts marked as
    # unincorporated-only receive the analogous condition.
    def unincorporated_only(fid: str) -> bool:
        fact = facts.get(fid) or {}
        text = " ".join(str(fact.get(k, "")) for k in ("need", "hint", "note"))
        return bool(re.search(r"(?i)unincorporated|county collection area only", text))

    city_facts = sorted(f for f in used if region_of(f) == "us-fl-miami")
    if city_facts:
        for f in city_facts:
            topic_key = f.split(".")[1]
            if not any(g.startswith(f"us-fl-miamidade.{topic_key}.") for g in used):
                report.err(where, f"cites {f} without a county us-fl-miamidade.{topic_key}.* counterpart")
    for i, refs in enumerate(card["paragraph_facts"]):
        refs = set(refs)
        if any(region_of(f) == "us-fl-miami" for f in refs):
            marker = paragraph_when[i] if isinstance(paragraph_when, list) and i < len(paragraph_when) else None
            if marker != {"municipality": "us-fl-miami"}:
                report.err(f"{where}.body[{i}]", "paragraph citing a City of Miami fact needs paragraph_when municipality us-fl-miami")
        elif any(unincorporated_only(f) for f in refs):
            marker = paragraph_when[i] if isinstance(paragraph_when, list) and i < len(paragraph_when) else None
            if marker != {"municipality": "unincorporated"}:
                report.err(f"{where}.body[{i}]", "paragraph citing an unincorporated-only fact needs paragraph_when municipality unincorporated")

    immigration_facts = sorted(
        f for f in used if {"immigration", "tps"} & set(facts.get(f, {}).get("topics") or [])
    )
    desk_id = card["desk"]
    desk = desks.get(desk_id)
    if desk is None:
        report.err(where, f"unknown desk {desk_id}")
    elif not region_covers(region_of(desk_id), region):
        report.err(where, f"desk {desk_id} is more local than card region {region}")
    immigration_desk = bool(desk and desk.get("immigration"))

    if (immigration_facts or immigration_desk) and not card["is_immigration"]:
        report.err(where, "references immigration facts or desk but is_immigration is false")
    if bool(card["is_immigration"]) != (card["privacy_scope"] == "person-papers"):
        report.err(where, "is_immigration and privacy_scope must agree (person-papers iff immigration)")
    if card["is_immigration"] and card["privacy_scope"] == "household":
        report.err(where, "an immigration card is never household scope (papers stay on the person)")
    if card["privacy_scope"] == "household" and immigration_facts:
        report.err(where, f"household-scope card references papers/immigration facts {immigration_facts}")

    if tourist:
        if card["is_immigration"]:
            report.err(where, "tourist-mode card is marked is_immigration")
        if immigration_facts:
            report.err(where, f"tourist-mode card references immigration facts {immigration_facts}")
        if immigration_desk:
            report.err(where, f"tourist-mode card ends at immigration desk {desk_id}")
        for key in ("title", "summary", "body"):
            lang = has_immigration_wording(card[key])
            if lang:
                report.err(f"{where}.{key}.{lang}", "tourist-mode card uses immigration wording")
        if not ({1, 10} & set(card["stages"])):
            report.err(where, "tourist-mode card must show in stage 1 or 10 (tourist mode hides stages 2-9)")

    for lang in LANGS:
        for i, u in enumerate(card["utterances"][lang]):
            uwhere = f"{where}.utterances.{lang}[{i}]"
            if not u.strip():
                report.err(uwhere, "empty utterance")
            if "{" in u or "}" in u:
                report.err(uwhere, "utterances hold no placeholders")
            for problem in copy_problems(u) + spelled_problems(u, lang) + status_date_problems(u):
                report.err(uwhere, problem)
            if tourist and IMMIGRATION_WORDS.search(u):
                report.err(uwhere, "tourist-mode card utterance uses immigration wording")
    for action in card.get("actions") or []:
        place = (action.get("target") or {}).get("fact") if action["type"] == "open_map" else None
        if place is not None:
            fid = place["fact_id"]
            if place["pack_id"] != region_of(fid):
                report.err(where, f"open_map place pack_id {place['pack_id']} does not own fact {fid}")
            if fid not in card["fact_refs"]:
                report.err(where, f"open_map place fact {fid} is not in the card's fact_refs")
            if fid in facts and facts[fid].get("value_type") != "place":
                report.err(where, f"open_map place fact {fid} must have value_type place")
            continue
        desk_ref = action_desk(action)
        target = desks.get(desk_ref)
        if target is None:
            report.err(where, f"action {action['type']} names unknown desk {desk_ref}")
            continue
        need = "phone" if action["type"] == "call_desk" else "address"
        if need not in target.get("contact_fields", []):
            report.err(where, f"action {action['type']} needs desk {desk_ref} to have a {need} fact")
        if tourist and target.get("immigration"):
            report.err(where, f"tourist-mode card offers an action at immigration desk {desk_ref}")
        if not region_covers(region_of(desk_ref), card["region_pack"]):
            report.err(where, f"action desk {desk_ref} is more local than card region {card['region_pack']}")

    if kind == "stage":
        if len(card["stages"]) != 1:
            report.err(where, "a stage card shows exactly one stage")
        if not card.get("hero_cards"):
            report.err(where, "a stage card needs hero_cards")
    elif "hero_cards" in card:
        report.err(where, "hero_cards is only for stage cards")
    if kind == "lens" and not card.get("origin_lenses"):
        report.err(where, "a lens card must name its origin lens")


def check_lens(lens: dict, where: str, cards: dict, facts: dict, desks: dict, report: Report, use) -> None:
    lid = lens["id"]
    if lens["origin_lens"] != lid:
        report.err(where, f"origin_lens {lens['origin_lens']} must equal the lens id {lid} (one id form: the ADCore case)")
    desk = desks.get(lens["desk"])
    if desk is None:
        report.err(where, f"unknown desk {lens['desk']}")
    elif "tourist" in lens["modes"] and desk.get("immigration"):
        report.err(where, f"tourist lens hands off to immigration desk {lens['desk']}")
    expect_nr = {"en": False, **{l: lens["translation_status"].get(l) != "reviewed" for l in ("es", "ht")}}
    if lens["needs_review"] != expect_nr:
        report.err(where, f"needs_review must be {expect_nr} to match translation_status")
    for key in ("title", "summary"):
        check_localized(f"{where}.{key}", lens[key], report)
    if lid == "haiti":
        for key in ("title", "summary"):
            for lang in LANGS:
                for problem in d5_haiti_problems(lens[key].get(lang, "")):
                    report.err(f"{where}.{key}.{lang}", problem)
    tourist_only = lens["modes"] == ["tourist"]
    lens_card = cards.get(lens["lens_card"])
    if lens_card is None:
        report.err(where, f"lens_card {lens['lens_card']} does not exist")
    elif lens_card.get("kind") != "lens":
        report.err(where, f"lens_card {lens['lens_card']} is not kind lens")
    elif lid not in (lens_card.get("origin_lenses") or []):
        report.err(where, f"lens_card {lens['lens_card']} does not list lens {lid}")
    used: set[str] = set()
    lines_for: set[str] = set()
    for i, line in enumerate(lens["origin_lines"]):
        lwhere = f"{where}:origin_lines[{i}]"
        check_localized(lwhere, line["text"], report)
        if lid == "haiti":
            for lang in LANGS:
                for problem in d5_haiti_problems(line["text"].get(lang, "")):
                    report.err(f"{lwhere}.text.{lang}", problem)
        if line["card"] in lines_for:
            report.err(lwhere, f"second line for card {line['card']}")
        lines_for.add(line["card"])
        if line["card"] not in lens["attaches_to"]:
            report.err(lwhere, f"card {line['card']} is not in attaches_to")
        target = cards.get(line["card"])
        line_region = line.get("region_pack") or (target.get("region_pack") if target else None)
        if target and line.get("region_pack") and not region_covers(target["region_pack"], line["region_pack"]):
            report.err(lwhere, f"line region {line['region_pack']} is not inside card region {target['region_pack']}")
        missing = localized_placeholders(line["text"]) - set(line["fact_refs"])
        if missing:
            report.err(lwhere, f"placeholders not in fact_refs: {sorted(missing)}")
        for fid in line["fact_refs"]:
            use(fid, f"lens:{lid}", lwhere, line_region, line["card"] if target else None)
            used.add(fid)
            topics = set(facts.get(fid, {}).get("topics") or [])
            if topics & {"immigration", "tps"} and target is not None and not target.get("is_immigration"):
                report.err(lwhere, f"immigration fact {fid} on non-immigration card {line['card']}")
            if topics & {"immigration", "tps"} and "tourist" in lens["modes"]:
                report.err(lwhere, f"tourist lens references immigration fact {fid}")
        if "tourist" in lens["modes"] and has_immigration_wording(line["text"]):
            report.err(lwhere, "tourist lens uses immigration wording")
        if target is not None and target.get("is_immigration") is False and has_immigration_wording(line["text"]) \
                and "tourist" in target.get("modes", []):
            report.err(lwhere, f"immigration wording on tourist-visible card {line['card']}")
    lens_texts = []
    for key in ("title", "summary"):
        localized = lens.get(key) or {}
        for lang in LANGS:
            if isinstance(localized.get(lang), str):
                lens_texts.append((lang, localized[lang]))
    for line in lens["origin_lines"]:
        localized = line.get("text") or {}
        for lang in LANGS:
            if isinstance(localized.get(lang), str):
                lens_texts.append((lang, localized[lang]))
    if any(_d8_text_used(text, lang) for lang, text in lens_texts):
        linked = "status-word" in (lens.get("attaches_to") or []) or any(
            line.get("card") == "status-word" for line in lens.get("origin_lines") or []
        )
        if not linked:
            report.err(where, "D8: status word used without link to status-word")
    if set(lens["fact_refs"]) != used:
        report.err(where, f"fact_refs must equal the union of origin_lines fact_refs: {sorted(used)}")
    for target_id in lens["attaches_to"]:
        target = cards.get(target_id)
        if target is None:
            report.err(where, f"attaches_to unknown card {target_id}")
            continue
        if lid not in (target.get("origin_lenses") or []):
            report.err(where, f"card {target_id} does not list lens {lid} in origin_lenses")
        if target_id not in lines_for:
            report.err(where, f"attaches to {target_id} but has no origin line for it")
        if tourist_only and "tourist" not in target.get("modes", []):
            report.err(where, f"tourist-only lens attaches to non-tourist card {target_id}")


def load_ledger(ledger_dir: Path, report: Report) -> dict[str, dict] | None:
    """research/facts/*.json: a list, one object, or {"facts": [...]}. None if the dir is missing."""
    if not ledger_dir.is_dir():
        report.err(str(ledger_dir), "ledger directory not found")
        return None
    ledger: dict[str, dict] = {}
    for path in sorted(ledger_dir.rglob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            report.err(str(path), f"ledger JSON parse error: {exc}")
            continue
        items = data.get("facts", [data]) if isinstance(data, dict) else data
        for item in items if isinstance(items, list) else []:
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                ledger[item["id"]] = item
    return ledger


# A placeholder renders its ledger value inline, in every locale. Only short values (number,
# money, phone, url, name, address, date) may sit inline; a rule text or quote (a string value
# of more than INLINE_QUOTE_MAX_WORDS words) is cited as a source only: keep it in fact_refs and
# paragraph_facts, and write the sentence so it stands alone.
INLINE_QUOTE_MAX_WORDS = 12


def inline_quote_problems(text: str, ledger: dict[str, dict]) -> list[str]:
    problems = []
    for fid in placeholders(text):
        value = (ledger.get(fid) or {}).get("value")
        if isinstance(value, str) and len(value.split()) > INLINE_QUOTE_MAX_WORDS:
            problems.append(f"inline-quote-placeholder: {{fact:{fid}}} renders a {len(value.split())}-word ledger "
                            "quote inline; cite it in paragraph_facts only and reword the sentence")
    return problems


def check_inline_quotes(cards: dict, lenses: dict, ledger: dict[str, dict], report: Report) -> None:
    def scan(where: str, localized) -> None:
        if not isinstance(localized, dict):
            return
        for lang in LANGS:
            value = localized.get(lang)
            if isinstance(value, str):
                for problem in inline_quote_problems(value, ledger):
                    report.err(f"{where}.{lang}", problem)

    for cid, card in cards.items():
        for key in ("title", "summary", "body"):
            scan(f"cards/{cid}.yaml.{key}", card.get(key))
        for i, action in enumerate(card.get("actions") or []):
            if isinstance(action, dict):
                for key in ("label", "labels"):
                    scan(f"cards/{cid}.yaml.actions[{i}].{key}", action.get(key))
    for lid, lens in lenses.items():
        for key in ("title", "summary"):
            scan(f"lenses/{lid}.yaml.{key}", lens.get(key))
        for i, line in enumerate(lens.get("origin_lines") or []):
            if isinstance(line, dict):
                scan(f"lenses/{lid}.yaml:origin_lines[{i}].text", line.get("text"))


def check_ledger(ledger_dir: Path, facts: dict, report: Report, require: bool,
                 ledger: dict[str, dict] | None = None) -> None:
    if ledger is None:
        ledger = load_ledger(ledger_dir, report)
    if ledger is None:
        return
    covered = [fid for fid in facts if fid in ledger]
    for fid, fact in facts.items():
        entry = ledger.get(fid)
        if entry is None:
            (report.err if require else report.warn)(f"ledger:{fid}", "not yet in research ledger")
            continue
        for key in ("kind", "value_type"):
            if entry.get(key) and entry[key] != fact.get(key):
                report.err(f"ledger:{fid}", f"{key} {entry[key]!r} in ledger, {fact.get(key)!r} requested")
    report.info.append(f"ledger: {len(covered)}/{len(facts)} requested facts present in {ledger_dir}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--content", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="content directory (default: the one containing tools/)")
    parser.add_argument("--ledger", type=Path, default=None, help="research/facts directory to cross-check")
    parser.add_argument("--require-ledger", action="store_true", help="missing ledger facts are errors")
    parser.add_argument("--topics", type=Path, default=None,
                        help="Research topic vocabulary (default: <content>/../research/topics.yaml)")
    parser.add_argument("--quiet-warnings", action="store_true", help="print only the warning count")
    args = parser.parse_args(argv)
    report = validate(args.content, args.ledger, args.require_ledger, args.topics)
    for line in report.errors:
        print(f"ERROR {line}")
    if args.quiet_warnings and report.warnings:
        print(f"WARN  {len(report.warnings)} warning(s) hidden (--quiet-warnings)")
    else:
        for line in report.warnings:
            print(f"WARN  {line}")
    for line in report.info:
        print(f"INFO  {line}")
    if report.errors:
        print(f"FAILED: {len(report.errors)} error(s)")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
