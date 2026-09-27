"""Deterministic, structural desk-only classifier for /v1/ask (review r3, finding B1).

A desk-only question is one only a desk can answer (visa outcome, clinic or medical price, jobs, appointment
slots, school-bus eligibility). Exact phrases leak paraphrases, so the classifier works on structure:

1. Normalize: casefold, accent-fold and strip punctuation (``retrieval.normalize``), then tokenize.
2. Stem simply: a token also matches with a plural, ``-ed``, ``-d`` or ``-ing`` ending removed (stems of at least
   3 letters; lexicon entries are written as base forms and are not stemmed themselves), and a lexicon entry ending in ``*`` is a prefix (at least 4 letters). Two adjacent tokens also
   match as one word, so ``rande-vou`` matches ``randevou`` and ``school bus`` matches ``schoolbus``.
3. Lexicons (``data/ask_policy.yaml``) name DOMAINS (immigration status, employment, medical, appointments,
   school, bus) and QUESTION-TYPE cues (outcome/approval, price/cost, booking). The three languages are one
   pool, so code-switched text needs no language detection.
4. A rule fires HARD when every lexicon of one of its ``when`` clauses hits. A rule whose domain word appears
   without its question-type cue fires SOFT (``ambiguous_domain``): the resolver then fails closed and sends
   it to the desk unless a card that is itself about that domain matches confidently.

No model, network or randomness: the same text always gives the same answer.
"""
from __future__ import annotations

from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass

from .retrieval import normalize

_SUFFIXES = ("ing", "es", "ed", "s", "d")
MIN_STEM = 3
MIN_PREFIX = 4


def tokenize(text: str) -> tuple[str, ...]:
    return tuple(normalize(text).split())


def forms(token: str) -> frozenset[str]:
    """The token plus its simple stems (plural, -ed, -d, -ing removed), never shorter than MIN_STEM."""
    out = {token}
    for suffix in _SUFFIXES:
        if token.endswith(suffix) and len(token) - len(suffix) >= MIN_STEM:
            out.add(token[: -len(suffix)])
    return frozenset(out)


@dataclass(frozen=True)
class Doc:
    """Tokens of one text with their stems, and the stems of each adjacent pair written as one word."""

    toks: tuple[str, ...]
    forms: tuple[frozenset[str], ...]
    pair_forms: tuple[frozenset[str], ...]

    all_forms: frozenset[str] = frozenset()

    @classmethod
    def of(cls, toks: Sequence[str]) -> "Doc":
        toks = tuple(toks)
        token_forms = tuple(forms(t) for t in toks)
        pair_forms = tuple(forms(a + b) for a, b in zip(toks, toks[1:]))
        return cls(toks, token_forms, pair_forms, frozenset().union(*token_forms, *pair_forms))


@dataclass(frozen=True)
class Entry:
    words: tuple[str, ...]
    prefix: bool  # the last word is a prefix

    @classmethod
    def parse(cls, raw: str) -> "Entry":
        prefix = raw.rstrip().endswith("*")
        words = tuple(normalize(raw.replace("*", " ")).split())
        if not words:
            raise ValueError(f"empty lexicon entry {raw!r}")
        if prefix and len(words[-1]) < MIN_PREFIX:
            raise ValueError(f"prefix entry {raw!r} is shorter than {MIN_PREFIX} letters")
        return cls(words, prefix)

    def _word(self, word: str, token_forms: frozenset[str], last: bool) -> bool:
        if last and self.prefix:
            return any(f.startswith(word) for f in token_forms)
        # One-directional: the TOKEN is stemmed, the entry is not ("renewed" never matches "renew").
        return word in token_forms

    def spans(self, doc: Doc) -> list[tuple[int, int]]:
        n, out = len(self.words), []
        for i in range(len(doc.toks) - n + 1):
            if all(self._word(w, doc.forms[i + j], j == n - 1) for j, w in enumerate(self.words)):
                out.append((i, i + n))
        if not self.prefix:
            joined = "".join(self.words)
            # A multi-word entry written as one token ("schoolbus"), or a one-word entry written as two
            # ("rande vou", "green card" -> "greencard").
            if n > 1:
                out.extend((i, i + 1) for i, f in enumerate(doc.forms) if joined in f)
            out.extend((i, i + 2) for i, f in enumerate(doc.pair_forms) if joined in f)
        return out


@dataclass(frozen=True)
class Lexicon:
    name: str
    entries: tuple[Entry, ...]
    # Fast path, derived from `entries`: exact words (and joined multi-word entries) that hit when they are
    # a stem of any token or adjacent token pair; only the remaining entries are scanned position by position.
    exact: frozenset[str] = frozenset()
    scanned: tuple[Entry, ...] = ()

    @classmethod
    def parse(cls, name: str, raw: object) -> "Lexicon":
        if not isinstance(raw, list) or not raw or not all(isinstance(x, str) for x in raw):
            raise ValueError(f"lexicon {name!r} must be a non-empty list of strings")
        entries = tuple(Entry.parse(x) for x in raw)
        exact = frozenset("".join(e.words) for e in entries if not e.prefix)
        scanned = tuple(e for e in entries if e.prefix or len(e.words) > 1)
        return cls(name, entries, exact, scanned)

    def spans(self, doc: Doc) -> list[tuple[int, int]]:
        return [span for entry in self.entries for span in entry.spans(doc)]

    def hits(self, doc: Doc) -> bool:
        if not self.exact.isdisjoint(doc.all_forms):
            return True
        return any(entry.spans(doc) for entry in self.scanned)


_MASKED = "\x00"


@dataclass(frozen=True)
class DeskOnlyRule:
    id: str
    when: tuple[tuple[Lexicon, ...], ...]
    topics: tuple[str, ...] = ()
    immigration: bool = False
    ambiguous_domain: Lexicon | None = None
    mask: tuple[Lexicon, ...] = ()

    def _prepared(self, doc: Doc | Sequence[str]) -> Doc:
        doc = doc if isinstance(doc, Doc) else Doc.of(doc)
        if not self.mask:
            return doc
        toks = list(doc.toks)
        for lexicon in self.mask:
            for start, end in lexicon.spans(doc):
                for k in range(start, end):
                    toks[k] = _MASKED
        return Doc.of(toks) if toks != list(doc.toks) else doc

    def hard(self, doc: Doc | Sequence[str]) -> bool:
        doc = self._prepared(doc)
        return any(all(lex.hits(doc) for lex in clause) for clause in self.when)

    def soft(self, doc: Doc | Sequence[str]) -> bool:
        if self.ambiguous_domain is None:
            return False
        return self.ambiguous_domain.hits(self._prepared(doc))

    def matches(self, normalized: str) -> bool:
        """Compatibility with the earlier regex rules: a HARD hit on already-normalized text."""
        return self.hard(tuple(normalized.split()))


@dataclass(frozen=True)
class DeskOnlyHit:
    rule: DeskOnlyRule
    hard: bool

    @property
    def id(self) -> str:
        return self.rule.id


def classify(rules: Iterable[DeskOnlyRule], text: str) -> DeskOnlyHit | None:
    """First HARD rule in policy order; otherwise the first SOFT (ambiguous-domain) rule; otherwise None."""
    rules = tuple(rules)
    toks = tokenize(text)
    if not toks:
        return None
    doc = Doc.of(toks)
    for rule in rules:
        if rule.hard(doc):
            return DeskOnlyHit(rule, True)
    for rule in rules:
        if rule.soft(doc):
            return DeskOnlyHit(rule, False)
    return None


def parse_rules(rows: object, lexicons: Mapping[str, Lexicon], kinds: Iterable[str], where: str) -> tuple[DeskOnlyRule, ...]:
    kinds = frozenset(kinds)
    if not isinstance(rows, list) or not rows:
        raise ValueError(f"{where}: desk_only must be a non-empty list")
    rules, seen = [], set()

    def lex(name: object, rule_id: str) -> Lexicon:
        if not isinstance(name, str) or name not in lexicons:
            raise ValueError(f"{where}: {rule_id}: unknown lexicon {name!r}")
        return lexicons[name]

    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise ValueError(f"{where}: each desk-only rule needs a string id")
        rid = row["id"]
        if rid not in kinds:
            raise ValueError(f"{where}: unknown desk-only kind {rid!r}")
        if rid in seen:
            raise ValueError(f"{where}: duplicate desk-only kind {rid!r}")
        seen.add(rid)
        unknown = set(row) - {"id", "when", "topics", "immigration", "ambiguous_domain", "unless_part_of"}
        if unknown:
            raise ValueError(f"{where}: {rid}: unknown keys {sorted(unknown)}")
        when = row.get("when")
        if not isinstance(when, list) or not when or not all(isinstance(c, list) and c for c in when):
            raise ValueError(f"{where}: {rid}: when must be a non-empty list of non-empty lexicon lists")
        topics = row.get("topics", [])
        if not isinstance(topics, list) or not all(isinstance(t, str) for t in topics):
            raise ValueError(f"{where}: {rid}: topics must be a list of strings")
        immigration = row.get("immigration", False)
        if not isinstance(immigration, bool):
            raise ValueError(f"{where}: {rid}: immigration must be boolean")
        ambiguous = row.get("ambiguous_domain")
        mask = row.get("unless_part_of", [])
        if not isinstance(mask, list):
            raise ValueError(f"{where}: {rid}: unless_part_of must be a list of lexicon names")
        rules.append(DeskOnlyRule(
            id=rid,
            when=tuple(tuple(lex(name, rid) for name in clause) for clause in when),
            topics=tuple(topics),
            immigration=immigration,
            ambiguous_domain=lex(ambiguous, rid) if ambiguous is not None else None,
            mask=tuple(lex(name, rid) for name in mask),
        ))
    return tuple(rules)
