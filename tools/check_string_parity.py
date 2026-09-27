#!/usr/bin/env python3
"""Check every .xcstrings catalog for es/en/ht parity. Passes when there are no catalogs.

Usage: check_string_parity.py [--root DIR] [--release] [--report [PATH]]

Exit 0 when no problems, 1 when any problem (unchanged). Problems go to stderr, one per line:
    <file>: key '<key>' lang=<es|en|ht|*> rule=<rule>: <message>
The needs-review list and the summary go to stdout.

Rules (README.md in the proposal explains each one in plain sentences):
  missing-language  every key has es, en and ht. shouldTranslate:false keys are not skipped.
  empty-value       every leaf is non-blank: stringUnit, each plural/device case, each substitution.
  untranslated      an es or ht leaf identical to en fails unless exempt (see identical_is_ok).
  placeholder       format specifiers match in count, type and argument position across languages.
  verbatim          no format specifier inside a phone number or in a [phone]/[name]/[number] key;
                    [phone]/[number] keys keep the same digits in every language.
  needs-review      a leaf whose state is not "translated" is listed on every run; --release (or
                    MYAD_STRINGS_RELEASE=1) turns each one into a problem.
  raw-key           a value that is its own key, or looks like a catalog key, fails.
  plural-other      every plural variation has an "other" case.
Accessibility labels, hints and Voice Control phrases are ordinary keys: no key prefix is skipped.

Markers, all in the entry's "comment" (the translator comment Xcode shows):
  [name] [phone] [number]  the string is a proper name / phone / number; kept as-is, never formatted.
  [do-not-translate]       identical text in all languages is intended (same as shouldTranslate:false).
  [same:es] [same:ht] [same:es,ht]  reviewed: this language is spelled like English on purpose.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REQUIRED = ("es", "en", "ht")
REFERENCE = "en"
SKIP_DIRS = {".git", ".build", "build", ".venv", "__pycache__", "DerivedData", "node_modules"}
RELEASE_ENV = "MYAD_STRINGS_RELEASE"
TRANSLATED = "translated"

VERBATIM_TAGS = {"name", "phone", "number"}
TAG_RE = re.compile(r"\[\s*(name|phone|number|do-not-translate|same\s*:\s*[a-z]{2}(?:\s*,\s*[a-z]{2})*)\s*\]", re.I)

# One scanner for printf-style specifiers as Xcode writes them. "%%" is a literal percent. A space
# is not accepted as a flag, so "50% off" / "100 % de descuento" are plain text, not specifiers.
SPEC_RE = re.compile(
    r"%(?:"
    r"(?P<pct>%)"
    r"|(?:(?P<subpos>\d+)\$)?#@(?P<sub>\w+)@"                     # %#@name@ substitution reference
    r"|(?P<arg>arg)"                                              # %arg inside a substitution
    r"|(?:(?P<pos>\d+)\$)?[-+0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<len>hh|h|ll|l|q|L|z|t|j)?(?P<conv>[@dDiuUxXoOfFeEgGaAcCsSp])"
    r")"
)
_FAMILY = {**dict.fromkeys("@", "object"), **dict.fromkeys("dDiuUxXoO", "int"),
           **dict.fromkeys("fFeEgGaA", "double"), **dict.fromkeys("cC", "char"),
           **dict.fromkeys("sS", "cstring"), "p": "pointer"}
_LENGTH = {"": "", "l": "64", "ll": "64", "q": "64", "z": "64", "t": "64", "j": "64",
           "h": "16", "hh": "8", "L": "long"}

# Automatic exemptions for "identical to English" (rule untranslated). Kept deliberately small;
# anything else that is legitimately identical gets a comment marker instead.
UNIVERSAL_TOKENS = {"ok", "min", "km", "mi", "mph", "kg", "lb", "lbs", "oz", "ft", "h", "hr", "hrs",
                    "am", "pm", "a.m", "p.m", "gal", "cm", "mm", "kwh", "°f", "°c", "wifi", "wi-fi"}
SHARED_WORDS = {  # common UI words spelled the same in the target language and English
    "es": {"no", "total", "error", "normal", "hospital", "hotel", "taxi", "metro", "local", "final",
           "chat", "radio", "doctor", "general", "internet", "plan", "club", "bus", "demo"},
    "ht": {"total", "plan", "bank"},  # Kreyòl words spelled like English; extend only after a Creole review
}
# Language names shown in their own language (ARCHITECTURE §3: the picker uses autonyms), identical by design.
AUTONYMS = {"english", "español", "kreyòl", "kreyòl ayisyen", "français", "português", "italiano", "deutsch",
            "tiếng việt", "русский", "中文", "العربية", "हिन्दी", "日本語", "한국어", "tagalog"}
_EDGE_PUNCT = ".,;:!?¡¿()[]{}\"'«»“”‘’…·–—/*"
_ACRONYM_RE = re.compile(r"^[A-Z][A-Z0-9&.]{1,7}$")                     # OK, ITIN, SNAP, U.S.
_CAMEL_RE = re.compile(r"[a-zà-ÿ][A-ZÀ-Þ]")                               # myAmericanDream, iPhone
_HYPHEN_NAME_RE = re.compile(r"^[A-ZÀ-Þ][\wÀ-ÿ']*(?:-[A-ZÀ-Þ0-9][\wÀ-ÿ']*)+$")  # Miami-Dade, Tri-Rail
_URL_RE = re.compile(r"^(?:https?://)?(?:[\w-]+\.)+(?:gov|org|com|edu|net|us|io|info)(?:/\S*)?$", re.I)
_EMAIL_RE = re.compile(r"^[\w.+-]+@[\w-]+(?:\.[\w-]+)+$")

# Raw-key heuristic, ported from Access's A11yLabelLint.looksLikeRawKey.
_ALLOWED_TLDS = {"gov", "org", "com", "edu", "net", "us", "io", "info"}
_SNAKE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+$")
_DOTTED_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]+(\.[A-Za-z][A-Za-z0-9_]+)+$")


@dataclass(frozen=True)
class Leaf:
    path: str          # "stringUnit", "variations.plural.one.stringUnit", "substitutions.n.variations..."
    unit: dict
    sub: str | None    # substitution name the leaf belongs to, None for the main string

    @property
    def value(self) -> str:
        v = self.unit.get("value", "")
        return v if isinstance(v, str) else str(v)

    @property
    def state(self) -> str:
        return str(self.unit.get("state") or "<none>")


def catalogs(root: Path) -> list[Path]:
    out = []
    for p in root.rglob("*.xcstrings"):
        rel = p.relative_to(root).parts
        # Test fixtures for this checker deliberately include failing catalogs.
        if SKIP_DIRS.intersection(rel) or rel[:3] == ("tools", "tests", "fixtures"):
            continue
        out.append(p)
    return sorted(out)


# ---------------------------------------------------------------- tree walking (plural/device/subs)

def _walk(node: dict, path: str, sub: str | None, leaves: list[Leaf], holes: list[tuple[str, str]],
          plural_no_other: list[str]) -> int:
    """Collect every stringUnit under node. Returns how many leaves were found."""
    n = 0
    unit = node.get("stringUnit")
    if isinstance(unit, dict):
        leaves.append(Leaf(path + "stringUnit", unit, sub))
        n += 1
    elif "stringUnit" in node:
        holes.append((path + "stringUnit", "stringUnit is not an object"))
    if "variations" in node:
        variations = node["variations"]
        if not isinstance(variations, dict) or not variations:
            holes.append((path + "variations", "variations has no cases"))
        else:
            for kind in sorted(variations):
                cases, p = variations[kind], f"{path}variations.{kind}"
                if not isinstance(cases, dict) or not cases:
                    holes.append((p, f"{kind} variation has no cases"))
                    continue
                if kind == "plural" and "other" not in cases:
                    plural_no_other.append(p)
                for name in sorted(cases):
                    case = cases[name] if isinstance(cases[name], dict) else {}
                    got = _walk(case, f"{p}.{name}.", sub, leaves, holes, plural_no_other)
                    if not got:
                        holes.append((f"{p}.{name}", "variation case has no value"))
                    n += got
    if "substitutions" in node:
        subs = node["substitutions"]
        if not isinstance(subs, dict) or not subs:
            holes.append((path + "substitutions", "substitutions is empty"))
        else:
            for name in sorted(subs):
                s = subs[name] if isinstance(subs[name], dict) else {}
                got = _walk(s, f"{path}substitutions.{name}.", name, leaves, holes, plural_no_other)
                if not got:
                    holes.append((f"{path}substitutions.{name}", "substitution has no value"))
                n += got
    return n


def _has_content(loc) -> bool:
    return isinstance(loc, dict) and any(k in loc for k in ("stringUnit", "variations", "substitutions"))


# ---------------------------------------------------------------- placeholders

def specifiers(value: str) -> list[tuple[str, int | None, str]]:
    """[(token, explicit position or None, kind)] where kind is 'object64', 'sub:name', 'arg', ..."""
    out = []
    for m in SPEC_RE.finditer(value):
        if m.group("pct"):
            continue
        if m.group("sub"):
            pos = m.group("subpos")
            out.append((m.group(0), int(pos) if pos else None, "sub:" + m.group("sub")))
        elif m.group("arg"):
            out.append((m.group(0), None, "arg"))
        else:
            pos = m.group("pos")
            kind = _FAMILY[m.group("conv")] + _LENGTH[m.group("len") or ""]
            out.append((m.group(0), int(pos) if pos else None, kind))
    return out


def _signature(leaves: list[Leaf], sub: str | None) -> tuple[dict[int, set[str]], set[str], bool, bool]:
    """Argument signature of one language's leaves belonging to `sub` (None = main string).

    Returns ({argument index: {types}}, {substitution names referenced}, mixes positional and
    sequential, uses %arg). Plural cases may drop a specifier (en "one": "One day"), so the
    signature is the union over the cases.
    """
    args: dict[int, set[str]] = {}
    subs: set[str] = set()
    mixed = uses_arg = False
    for leaf in leaves:
        if leaf.sub != sub:
            continue
        seq, positional, sequential = 0, False, False
        for _tok, pos, kind in specifiers(leaf.value):
            if kind.startswith("sub:"):  # %#@n@ consumes an argument slot like any specifier
                subs.add(kind[4:])
                if pos is None:
                    seq += 1
                    sequential = True
                else:
                    positional = True
                continue
            if kind == "arg":
                uses_arg = True
                continue
            if pos is None:
                seq += 1
                idx, sequential = seq, True
            else:
                idx, positional = pos, True
            args.setdefault(idx, set()).add(kind)
        mixed = mixed or (positional and sequential)
    return args, subs, mixed, uses_arg


def _fmt_args(args: dict[int, set[str]]) -> str:
    return " ".join(f"#{i}:{'|'.join(sorted(t))}" for i, t in sorted(args.items())) or "none"


# ---------------------------------------------------------------- exemptions and heuristics

def comment_tags(entry: dict) -> tuple[set[str], set[str]]:
    """(markers like {'name', 'do-not-translate'}, languages from [same:..])."""
    tags, same = set(), set()
    comment = entry.get("comment")
    if isinstance(comment, str):
        for raw in TAG_RE.findall(comment):
            t = re.sub(r"\s+", "", raw.lower())
            if t.startswith("same:"):
                same.update(t[5:].split(","))
            else:
                tags.add(t)
    return tags, same


def _token_ok(token: str, lang: str) -> bool:
    t = token.strip(_EDGE_PUNCT)
    if not t or not any(ch.isalpha() for ch in t):
        return True                                   # numbers, phones, prices, symbols
    if t.endswith(("'s", "’s")):
        t = t[:-2]
    low = t.lower()
    return bool(low in UNIVERSAL_TOKENS or low in SHARED_WORDS.get(lang, ())
                or _ACRONYM_RE.match(t) or _CAMEL_RE.search(t) or _HYPHEN_NAME_RE.match(t)
                or _URL_RE.match(t) or _EMAIL_RE.match(t))


def identical_is_ok(value: str, lang: str, entry: dict, tags: set[str], same: set[str]) -> bool:
    """True when an es/ht value identical to en is legitimate (see module docstring)."""
    if entry.get("shouldTranslate") is False or "do-not-translate" in tags or tags & VERBATIM_TAGS:
        return True
    if lang in same or value.strip().casefold() in AUTONYMS:
        return True
    text = SPEC_RE.sub(" ", value)
    return all(_token_ok(tok, lang) for tok in text.split())


def looks_like_raw_key(value: str) -> bool:
    s = value.strip()
    if not s or any(ch.isspace() for ch in s):
        return False
    if s.startswith("a11y."):
        return True
    if _SNAKE_RE.match(s):
        return True
    if not _DOTTED_RE.match(s):
        return False
    return s.split(".")[-1].lower() not in _ALLOWED_TLDS   # www.miamidade.gov is a domain, not a key


def _is_semantic_key(key: str) -> bool:
    return bool(key) and not any(ch.isspace() for ch in key) and ("." in key or "_" in key)


_PHONE_CHARS = set("0123456789()+- \x00")
_PHONE_SHAPES = (
    re.compile(r"\(\d{3}\)\s?\x00"),      # (305) %@
    re.compile(r"\+\d[\d\s-]*\x00"),        # +1 305 %@
    re.compile(r"\d\x00|\x00\d"),           # 305%@ (glued to digits)
)
_HYPHEN_SHAPE = re.compile(r"\d-\x00|\x00-\d")  # 1-800-%@, 305-%@-0100 (needs 2+ digit groups)


def phone_with_specifier(value: str) -> str | None:
    """Return the phone-shaped run that contains a format specifier, if any.

    A run is a stretch of digits, spaces, ( ) + - and specifiers holding a specifier and 3+ digits.
    It is a phone when the specifier follows an area code "(305) %@", an international prefix
    "+1 305 %@", is glued to digits "305%@", or sits on a hyphen between digit groups "1-800-%@".
    Ranges and plain numbers do not match: "2020-%lld", "$100-%lld", "Paso %lld de 3", "2026 (%@)",
    "1.000 %@", "Edades 18-65 %@". Known miss: "305-%@" (one digit group).
    """
    marked = SPEC_RE.sub(lambda m: "" if m.group("pct") else "\x00", value)
    runs, cur = [], ""
    for ch in marked:
        if ch in _PHONE_CHARS:
            cur += ch
        else:
            runs.append(cur)
            cur = ""
    runs.append(cur)
    for run in runs:
        if "\x00" not in run or sum(ch.isdigit() for ch in run) < 3:
            continue
        groups = len(re.findall(r"\d+", run))
        if any(r.search(run) for r in _PHONE_SHAPES) or (_HYPHEN_SHAPE.search(run) and groups >= 2):
            return run.strip().replace("\x00", "%…")
    return None


def _digits(value: str) -> str:
    return "".join(ch for ch in SPEC_RE.sub("", value) if ch.isdigit())


# ---------------------------------------------------------------- the check

@dataclass(frozen=True)
class Review:
    path: Path
    key: str
    lang: str
    leaf: str
    state: str
    value: str


def check_catalog(path: Path, release: bool = False) -> tuple[list[str], list[Review]]:
    def err(key: str, lang: str, rule: str, msg: str) -> None:
        line = f"{path}: key {key!r} lang={lang} rule={rule}: {msg}"
        if line not in seen:
            seen.add(line)
            errs.append(line)

    errs: list[str] = []
    seen: set[str] = set()
    review: list[Review] = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        return [f"{path}: key '-' lang=* rule=unreadable: unreadable catalog ({e})"], []
    strings = data.get("strings") if isinstance(data, dict) else None
    if not isinstance(strings, dict):
        return [f"{path}: key '-' lang=* rule=unreadable: not a string catalog (no \"strings\" object)"], []

    for key in sorted(strings):
        entry = strings[key] if isinstance(strings[key], dict) else {}
        tags, same = comment_tags(entry)
        explicit_dnt = entry.get("shouldTranslate") is False or "do-not-translate" in tags
        locs = entry.get("localizations") if isinstance(entry.get("localizations"), dict) else {}
        by_lang: dict[str, list[Leaf]] = {}

        # Rules 1, 2, 9: presence and non-empty leaves, walking every variation and substitution.
        for lang in REQUIRED:
            loc = locs.get(lang)
            if not _has_content(loc):
                hint = " (shouldTranslate:false still ships all three; repeat the value)" \
                    if entry.get("shouldTranslate") is False else ""
                err(key, lang, "missing-language", f"missing {lang}{hint}")
                continue
            leaves: list[Leaf] = []
            holes: list[tuple[str, str]] = []
            no_other: list[str] = []
            _walk(loc, "", None, leaves, holes, no_other)
            for where, why in holes:
                err(key, lang, "empty-value", f"{why} at {where}")
            for where in no_other:
                err(key, lang, "plural-other", f"plural variation without an 'other' case at {where}")
            for leaf in leaves:
                if not leaf.value.strip():
                    err(key, lang, "empty-value", f"empty value at {leaf.path}")
            by_lang[lang] = [lf for lf in leaves if lf.value.strip()]

        # Rule 6: review states, per leaf.
        for lang in REQUIRED:
            for leaf in by_lang.get(lang, []):
                if leaf.state != TRANSLATED:
                    review.append(Review(path, key, lang, leaf.path, leaf.state, leaf.value))
                    if release:
                        err(key, lang, "needs-review", f"state={leaf.state} at {leaf.path} (release mode)")

        # Rule 7: raw key as value (every language, every leaf).
        for lang in REQUIRED:
            for leaf in by_lang.get(lang, []):
                v = leaf.value.strip()
                if (v == key and _is_semantic_key(key)) or (not explicit_dnt and looks_like_raw_key(v)):
                    err(key, lang, "raw-key", f"value {v!r} at {leaf.path} is a raw catalog key")

        # Rule 3: es/ht identical to en, compared leaf by leaf on the same path.
        ref = {lf.path: lf.value for lf in by_lang.get(REFERENCE, [])}
        for lang in REQUIRED:
            if lang == REFERENCE:
                continue
            for leaf in by_lang.get(lang, []):
                en = ref.get(leaf.path)
                if en is None or leaf.value.strip().casefold() != en.strip().casefold():
                    continue
                if not identical_is_ok(leaf.value, lang, entry, tags, same):
                    err(key, lang, "untranslated",
                        f"{leaf.value.strip()!r} at {leaf.path} is identical to en; translate it, or mark "
                        f"the key [name]/[phone]/[number]/[do-not-translate] or [same:{lang}] in its comment")

        # Rule 4: placeholder parity for the main string and every substitution.
        present = [lang for lang in REQUIRED if by_lang.get(lang)]
        base = REFERENCE if REFERENCE in present else (present[0] if present else None)
        sub_names = sorted({lf.sub for lang in present for lf in by_lang[lang] if lf.sub})
        for scope in [None, *sub_names]:
            where = "main string" if scope is None else f"substitution {scope!r}"
            sigs = {lang: _signature(by_lang[lang], scope) for lang in present}
            for lang in present:
                args, _subs, mixed, _arg = sigs[lang]
                if mixed:
                    err(key, lang, "placeholder", f"{where} mixes positional (%1$@) and sequential (%@) specifiers")
                for idx, kinds in sorted(args.items()):
                    if len(kinds) > 1:
                        err(key, lang, "placeholder",
                            f"{where} uses argument #{idx} as {' and '.join(sorted(kinds))} in different cases")
            if base is None:
                continue
            if scope is None:  # every %#@name@ must be defined in that language's substitutions
                for lang in present:
                    defined = (locs.get(lang) or {}).get("substitutions")
                    defined = set(defined) if isinstance(defined, dict) else set()
                    for name in sorted(sigs[lang][1] - defined):
                        err(key, lang, "placeholder", f"%#@{name}@ is used but substitution {name!r} is not defined")
            in_scope = {lang for lang in present if any(lf.sub == scope for lf in by_lang[lang])}
            if base not in in_scope:
                continue
            b_args, b_subs, _m, b_arg = sigs[base]
            b_types = {i: sorted(t) for i, t in b_args.items()}
            for lang in present:
                if lang == base or lang not in in_scope:  # an empty scope is already an empty-value
                    continue
                args, subs, _m, uses_arg = sigs[lang]
                if {i: sorted(t) for i, t in args.items()} != b_types:
                    err(key, lang, "placeholder",
                        f"{where} placeholders {_fmt_args(args)} do not match {base} {_fmt_args(b_args)}")
                if subs != b_subs:
                    err(key, lang, "placeholder",
                        f"{where} substitution references {sorted(subs)} do not match {base} {sorted(b_subs)}")
                if scope is not None and uses_arg != b_arg:
                    err(key, lang, "placeholder", f"{where} %arg use differs from {base}")
            if scope is not None:  # argNum / formatSpecifier of the substitution itself
                meta = {}
                for lang in present:
                    s = ((locs.get(lang) or {}).get("substitutions") or {}).get(scope)
                    if isinstance(s, dict):
                        meta[lang] = (s.get("argNum"), s.get("formatSpecifier"))
                if base in meta:
                    for lang, m in sorted(meta.items()):
                        if m != meta[base]:
                            err(key, lang, "placeholder",
                                f"{where} argNum/formatSpecifier {m} do not match {base} {meta[base]}")

        # Rule 5: phones, names and numbers are never formatted; phones/numbers keep their digits.
        verbatim = sorted(tags & VERBATIM_TAGS)
        for lang in REQUIRED:
            for leaf in by_lang.get(lang, []):
                specs = [tok for tok, _p, _k in specifiers(leaf.value)]
                if verbatim and specs:
                    err(key, lang, "verbatim",
                        f"format specifier {specs[0]} at {leaf.path} in a [{verbatim[0]}] string; "
                        "phones, names and numbers are written out, never formatted")
                run = phone_with_specifier(leaf.value)
                if run:
                    err(key, lang, "verbatim",
                        f"format specifier inside phone number {run!r} at {leaf.path}; "
                        "write the whole number or pass it as one argument")
        if tags & {"phone", "number"} and REFERENCE in by_lang:
            ref_digits = {lf.path: _digits(lf.value) for lf in by_lang[REFERENCE]}
            for lang in REQUIRED:
                if lang == REFERENCE:
                    continue
                for leaf in by_lang.get(lang, []):
                    want = ref_digits.get(leaf.path)
                    if want is not None and _digits(leaf.value) != want:
                        err(key, lang, "verbatim",
                            f"digits {_digits(leaf.value)!r} at {leaf.path} differ from en {want!r}; "
                            "phones and numbers stay as-is in every language")
    return errs, review


def problems(path: Path, release: bool = False) -> list[str]:
    """Back-compatible helper: problem lines for one catalog."""
    return check_catalog(path, release)[0]


def review_markdown(items: list[Review], root: Path) -> str:
    lines = ["# Strings awaiting review", "", f"{len(items)} string(s) not in state `translated`.", ""]
    if items:
        lines += ["| catalog | key | lang | at | state | value |", "| --- | --- | --- | --- | --- | --- |"]
        for r in items:
            try:
                cat = r.path.relative_to(root)
            except ValueError:
                cat = r.path
            val = r.value.replace("|", "\\|").replace("\n", " ")
            lines.append(f"| {cat} | `{r.key}` | {r.lang} | {r.leaf} | {r.state} | {val} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--release", action="store_true",
                    help=f"fail on strings not in state 'translated' (also: {RELEASE_ENV}=1)")
    ap.add_argument("--report", nargs="?", const="-", metavar="PATH",
                    help="write the review list as Markdown to PATH (stdout when PATH is omitted)")
    args = ap.parse_args(argv)
    release = args.release or os.environ.get(RELEASE_ENV, "").strip().lower() in {"1", "true", "yes"}

    found = catalogs(args.root)
    errs: list[str] = []
    review: list[Review] = []
    for p in found:
        e, r = check_catalog(p, release)
        errs += e
        review += r
    for e in errs:
        print(e, file=sys.stderr)

    print(f"string parity: {len(review)} string(s) awaiting review"
          + (" (release mode: each is a problem)" if release else " (listed, not failing; --release fails)"))
    for r in review:
        print(f"  review: {r.path}: key {r.key!r} lang={r.lang} at {r.leaf} state={r.state}")
    if args.report is not None:
        md = review_markdown(review, args.root)
        if args.report == "-":
            print(md, end="")
        else:
            Path(args.report).write_text(md, encoding="utf-8")
            print(f"string parity: review report written to {args.report}")
    print(f"string parity: {len(found)} catalog(s), {len(errs)} problem(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
