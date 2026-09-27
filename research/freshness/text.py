"""Text extraction, normalization, and quote re-finding."""
from __future__ import annotations

import difflib
import functools
import re
import shutil
import subprocess
import tempfile
import unicodedata
from dataclasses import dataclass

_TRANS = str.maketrans({
    "\u2018": "'", "\u2019": "'", "\u201a": "'", "\u201b": "'",
    "\u201c": '"', "\u201d": '"', "\u201e": '"', "\u2033": '"',
    "\u2013": "-", "\u2014": "-", "\u2012": "-", "\u2212": "-", "\u2010": "-", "\u2011": "-",
    "\u00a0": " ", "\u2009": " ", "\u202f": " ", "\u200b": "", "\ufeff": "", "\u00ad": "",
})
_WS = re.compile(r"\s+")
_PUNCT = re.compile(r"[^\w$%.,/:-]+")


def normalize(s: str) -> str:
    """NFKC, straight quotes, plain dashes and spaces, collapsed whitespace."""
    s = unicodedata.normalize("NFKC", s or "").translate(_TRANS)
    return _WS.sub(" ", s).strip()


def fold(s: str) -> str:
    """normalize + casefold + punctuation other than $ % . , / : - dropped (lenient match)."""
    return _WS.sub(" ", _PUNCT.sub(" ", normalize(s).casefold())).strip()


def html_to_text(content: bytes) -> str:
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(content, "html.parser")
    for tag in soup(["script", "style", "noscript", "template"]):
        tag.decompose()
    return normalize(soup.get_text(" "))


def pdf_to_text(content: bytes) -> str:
    if shutil.which("pdftotext"):
        with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
            f.write(content)
            f.flush()
            out = subprocess.run(["pdftotext", "-layout", f.name, "-"], capture_output=True, timeout=120)
            if out.returncode == 0:
                return normalize(out.stdout.decode("utf-8", errors="replace"))
    try:  # optional fallback
        import io

        from pdfminer.high_level import extract_text  # type: ignore

        return normalize(extract_text(io.BytesIO(content)))
    except ImportError as e:  # pragma: no cover
        raise RuntimeError("no PDF text extractor: install poppler-utils (pdftotext) or pdfminer.six") from e


def to_text(content: bytes, content_type: str = "", hint: str | None = None) -> str:
    """hint: 'pdf' | 'html' | 'text' | None (sniff)."""
    kind = hint
    if kind is None:
        if content[:5] == b"%PDF-" or "pdf" in content_type:
            kind = "pdf"
        elif "html" in content_type or content.lstrip()[:1] == b"<":
            kind = "html"
        else:
            kind = "text"
    if kind == "pdf":
        return pdf_to_text(content)
    if kind == "html":
        return html_to_text(content)
    return normalize(content.decode("utf-8", errors="replace"))


@dataclass
class QuoteMatch:
    found: bool
    how: str  # "exact" | "folded" | "missing"
    snippet: str | None = None
    similarity: float | None = None


@functools.lru_cache(maxsize=8)
def _tokens(text: str) -> tuple[list[str], list[str]]:
    toks = text.split(" ") if text else []
    return toks, [fold(t) for t in toks]


def best_snippet(text: str, quote: str, *, context: int = 8, candidates: int = 25) -> tuple[str | None, float]:
    """Best-matching window of the text for a quote.

    Linear prefilter (token overlap in a sliding window) picks a few candidate positions; difflib ratio
    ranks only those, then the best window's edges are refined. Fast on long pages and PDFs."""
    from collections import Counter

    toks, ftoks = _tokens(text)
    qtoks = [t for t in (fold(x) for x in normalize(quote).split(" ")) if t]
    if not toks or not qtoks:
        return None, 0.0
    n = len(qtoks)
    qcount = Counter(qtoks)
    win: Counter = Counter()
    overlap = 0
    scores: list[tuple[int, int]] = []
    for i, t in enumerate(ftoks):
        win[t] += 1
        if win[t] <= qcount.get(t, 0):
            overlap += 1
        if i >= n:
            old = ftoks[i - n]
            if win[old] <= qcount.get(old, 0):
                overlap -= 1
            win[old] -= 1
        if i >= n - 1 or i == len(ftoks) - 1:
            scores.append((overlap, max(0, i - n + 1)))
    scores.sort(key=lambda x: -x[0])
    qf = " ".join(qtoks)
    sm = difflib.SequenceMatcher(autojunk=False)
    sm.set_seq2(qf)
    best = (0.0, 0, n)
    seen = set()
    for ov, i in scores[:candidates]:
        if ov == 0 or i in seen:
            continue
        seen.add(i)
        sm.set_seq1(" ".join(x for x in ftoks[i:i + n] if x))
        r = sm.ratio()
        if r > best[0]:
            best = (r, i, n)
    if best[0] == 0.0:
        return None, 0.0
    r0, i, m = best
    step = max(1, n // 4)
    for a in range(max(0, i - step), i + step + 1):
        for b in range(max(a + 1, i + m - step), min(len(ftoks), i + m + step) + 1):
            sm.set_seq1(" ".join(x for x in ftoks[a:b] if x))
            r = sm.ratio()
            if r > r0:
                r0, i, m = r, a, b - a
    s_, e_ = max(0, i - context), min(len(toks), i + m + context)
    return " ".join(toks[s_:e_]), round(r0, 3)


def find_quote(text: str, quote: str) -> QuoteMatch:
    t, q = normalize(text), normalize(quote)
    if not q:
        return QuoteMatch(False, "missing", None, None)
    if q in t:
        return QuoteMatch(True, "exact")
    if fold(q) and fold(q) in fold(t):
        return QuoteMatch(True, "folded")
    snip, sim = best_snippet(t, q)
    return QuoteMatch(False, "missing", snip, sim)
