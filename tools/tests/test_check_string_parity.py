"""Tests for tools/check_string_parity.py (stdlib unittest; also collected by pytest).

Staging layout: this file, check_string_parity.py and fixtures/ sit side by side.
In the tree (proposal): tools/tests/test_check_string_parity.py with the fixtures under
tools/tests/fixtures/parity_rules/ (the checker already skips tools/tests/fixtures).
"""
from __future__ import annotations

import contextlib
import io
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
for cand in (HERE, HERE.parent):  # staging: same dir; tree: tools/ is the parent of tools/tests/
    if (cand / "check_string_parity.py").is_file():
        sys.path.insert(0, str(cand))
        break
import check_string_parity as csp  # noqa: E402

FIX = next(p for p in (HERE / "fixtures" / "parity_rules", HERE / "fixtures") if (p / "r1_missing_language").is_dir())
LINE_RE = re.compile(r"^(?P<file>.+?): key '(?P<key>.*)' lang=(?P<lang>\S+) rule=(?P<rule>[\w-]+): (?P<msg>.+)$")


def run(root: Path, *args: str, env: dict | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    environ = {k: v for k, v in os.environ.items() if k != csp.RELEASE_ENV}
    environ.update(env or {})
    with mock.patch.dict(os.environ, environ, clear=True), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = csp.main(["--root", str(root), *args])
    return code, out.getvalue(), err.getvalue()


def findings(stderr: str) -> set[tuple[str, str, str]]:
    got = set()
    for line in stderr.splitlines():
        m = LINE_RE.match(line)
        assert m, f"unparseable problem line: {line!r}"
        got.add((m["key"], m["lang"], m["rule"]))
    return got


# Exact expected (key, lang, rule) findings for each failing fixture.
EXPECTED_FAIL = {
    "r1_missing_language": {
        ("trash.tomorrow", "ht", "missing-language"),
        ("rent.due", "es", "missing-language"),
        ("brand.metrorail", "es", "missing-language"),   # shouldTranslate:false is no longer skipped
        ("brand.metrorail", "en", "missing-language"),
        ("brand.metrorail", "ht", "missing-language"),
        ("empty.loc", "ht", "missing-language"),
    },
    "r2_empty_value": {
        ("greeting", "ht", "empty-value"),
        ("blank.es", "es", "empty-value"),
        ("days.left", "en", "empty-value"),               # empty plural case
        ("empty.group", "es", "empty-value"),             # plural group with no cases
        ("empty.sub", "ht", "empty-value"),               # substitution with no value
    },
    "r3_untranslated": {
        ("button.cancel", "es", "untranslated"),
        ("button.save", "ht", "untranslated"),
        ("trash.tomorrow", "es", "untranslated"),
        ("trash.tomorrow", "ht", "untranslated"),
        ("place.littleHaiti", "es", "untranslated"),      # plain-word names need a [name] marker
        ("days.left", "es", "untranslated"),
    },
    "r4_placeholder": {
        ("hello.name", "es", "placeholder"),              # count
        ("days.type", "es", "placeholder"),               # type
        ("order.seq", "es", "placeholder"),               # sequential order swapped
        ("order.pos", "es", "placeholder"),               # positional index lost
        ("mixed", "es", "placeholder"),                   # positional + sequential mixed
        ("plural.conflict", "es", "placeholder"),         # one case %@, other %lld
        ("sub.undefined", "es", "placeholder"),           # %#@n@ without a substitution
    },
    "r5_verbatim": {
        ("desk.phone.fmt", "es", "verbatim"), ("desk.phone.fmt", "en", "verbatim"), ("desk.phone.fmt", "ht", "verbatim"),
        ("desk.name.fmt", "es", "verbatim"), ("desk.name.fmt", "en", "verbatim"), ("desk.name.fmt", "ht", "verbatim"),
        ("hotline", "es", "verbatim"), ("hotline", "en", "verbatim"), ("hotline", "ht", "verbatim"),
        ("area.code", "es", "verbatim"), ("area.code", "en", "verbatim"), ("area.code", "ht", "verbatim"),
        ("emergency.number", "ht", "verbatim"),           # digits changed in a [number] string
    },
    "r6_needs_review": set(),                             # normal run: listed only (release: see below)
    "r7_raw_key": {
        ("a11y.card.readAloud", "en", "raw-key"),
        ("household.add", "es", "raw-key"),
        ("card.title", "ht", "raw-key"),
    },
    "r8_a11y": {
        ("a11y.card.readAloud.label", "ht", "missing-language"),
        ("a11y.card.readAloud.hint", "es", "untranslated"),
        ("a11y.card.readAloud.inputLabels", "ht", "empty-value"),
        ("a11y.household.count", "ht", "placeholder"),
    },
    "r9_variations": {
        ("stops.away", "es", "empty-value"),              # device > plural > other, empty
        ("stops.away", "ht", "plural-other"),             # device iphone plural lacks "other"
        ("stops.away", "ht", "raw-key"),                  # raw key deep in a variation
        ("sub.meta", "es", "placeholder"),                # substitution formatSpecifier differs
        ("tasks.pending", "ht", "untranslated"),          # untranslated leaf inside a substitution
    },
}
RULE_OF = {  # the rule each fixture pair exists to prove
    "r1_missing_language": "missing-language", "r2_empty_value": "empty-value", "r3_untranslated": "untranslated",
    "r4_placeholder": "placeholder", "r5_verbatim": "verbatim", "r6_needs_review": "needs-review",
    "r7_raw_key": "raw-key", "r8_a11y": None, "r9_variations": None,
}


class FixturePairs(unittest.TestCase):
    def test_every_rule_has_a_pass_and_a_fail_fixture(self):
        rules = sorted(p.name for p in FIX.iterdir() if p.name.startswith("r"))
        self.assertEqual(rules, sorted(EXPECTED_FAIL))
        for r in rules:
            for kind in ("pass", "fail"):
                self.assertTrue(list((FIX / r / kind).glob("*.xcstrings")), f"{r}/{kind} has no catalog")

    def test_pass_fixtures_pass_in_normal_and_release_mode(self):
        for r in EXPECTED_FAIL:
            for extra in ((), ("--release",)):
                with self.subTest(rule=r, mode=extra):
                    code, out, err = run(FIX / r / "pass", *extra)
                    self.assertEqual(err, "")
                    self.assertEqual(code, 0)
                    self.assertIn("1 catalog(s), 0 problem(s)", out)

    def test_fail_fixtures_report_exactly_the_expected_findings(self):
        for r, expected in EXPECTED_FAIL.items():
            with self.subTest(rule=r):
                code, out, err = run(FIX / r / "fail")
                self.assertEqual(findings(err), expected)
                self.assertEqual(code, 1 if expected else 0)
                self.assertIn(f"{len(err.splitlines())} problem(s)", out)
                if RULE_OF[r] and expected:
                    self.assertTrue(any(rule == RULE_OF[r] for _k, _l, rule in expected))

    def test_error_lines_name_file_key_language_rule_message(self):
        _code, _out, err = run(FIX / "r1_missing_language" / "fail")
        first = err.splitlines()[0]
        m = LINE_RE.match(first)
        self.assertTrue(m["file"].endswith("Fixture.xcstrings"))
        self.assertIn(m["lang"], {"es", "en", "ht"})
        self.assertTrue(m["msg"])


class FalsePositiveSweep(unittest.TestCase):
    def test_realistic_miami_strings_pass_in_release_mode(self):
        code, out, err = run(FIX / "fp_miami_sweep" / "pass", "--release")
        self.assertEqual(err, "")
        self.assertEqual(code, 0)


class NeedsReview(unittest.TestCase):
    root = FIX / "r6_needs_review" / "fail"

    def test_normal_run_lists_but_passes(self):
        code, out, err = run(self.root)
        self.assertEqual((code, err), (0, ""))
        self.assertIn("2 string(s) awaiting review", out)
        self.assertIn("key 'trash.tomorrow' lang=ht at stringUnit state=needs_review", out)
        self.assertIn("key 'rent.due' lang=es at stringUnit state=new", out)

    def test_release_flag_fails(self):
        code, _out, err = run(self.root, "--release")
        self.assertEqual(code, 1)
        self.assertEqual(findings(err), {("trash.tomorrow", "ht", "needs-review"), ("rent.due", "es", "needs-review")})

    def test_release_env_var_fails(self):
        code, _out, err = run(self.root, env={csp.RELEASE_ENV: "1"})
        self.assertEqual(code, 1)
        self.assertEqual(len(err.splitlines()), 2)

    def test_report_to_stdout_and_file(self):
        code, out, _err = run(self.root, "--report")
        self.assertEqual(code, 0)
        self.assertIn("# Strings awaiting review", out)
        self.assertIn("| Fixture.xcstrings | `trash.tomorrow` | ht | stringUnit | needs_review | Demen yo ranmase fatra |", out)
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "review.md"
            code, out, _err = run(self.root, "--report", str(dest))
            self.assertEqual(code, 0)
            self.assertIn("rent.due", dest.read_text(encoding="utf-8"))


class LegacyBehavior(unittest.TestCase):
    """Lead's original tools/tests/test_checks.py expectations, unchanged."""

    def test_parity_passes_with_all_three(self):
        self.assertEqual(run(FIX / "legacy" / "parity_pass")[0], 0)

    def test_parity_fails_when_ht_missing(self):
        code, _out, err = run(FIX / "legacy" / "parity_fail")
        self.assertEqual(code, 1)
        self.assertIn("missing ht", err)

    def test_parity_passes_with_no_catalogs(self):
        code, out, _err = run(FIX / "legacy" / "parity_empty")
        self.assertEqual(code, 0)
        self.assertIn("string parity: 0 catalog(s), 0 problem(s)", out)

    def test_unreadable_catalog_is_a_problem(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Bad.xcstrings").write_text("{not json", encoding="utf-8")
            code, _out, err = run(Path(tmp))
            self.assertEqual(code, 1)
            self.assertIn("rule=unreadable", err)

    def test_tools_tests_fixtures_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "tools" / "tests" / "fixtures" / "x"
            d.mkdir(parents=True)
            (d / "Bad.xcstrings").write_text("{not json", encoding="utf-8")
            self.assertEqual(run(Path(tmp))[0], 0)


class Heuristics(unittest.TestCase):
    """Guard rails against false positives on legitimate Miami es/ht strings."""

    def ok(self, value, lang="es", comment=None, **entry):
        if comment:
            entry["comment"] = comment
        tags, same = csp.comment_tags(entry)
        return csp.identical_is_ok(value, lang, entry, tags, same)

    def test_identical_is_ok_for_names_numbers_and_shared_words(self):
        for v in ["OK", "Ok", "Miami-Dade", "Tri-Rail", "myAmericanDream", "iPhone", "WhatsApp", "311", "911",
                  "(305) 468-5900", "$0.66", "4.5", "24/7", "%lld", "%1$@ · %2$@", "%lld min", "ITIN", "SNAP",
                  "U.S.", "miamidade.gov", "info@miamidade.gov", "Miami-Dade 311", "Wi-Fi", "7:30 a.m.",
                  "English", "Español", "Kreyòl", "Kreyòl ayisyen", "Français"]:
            with self.subTest(v=v):
                self.assertTrue(self.ok(v, "es") and self.ok(v, "ht"))
        self.assertTrue(self.ok("No", "es"))
        self.assertTrue(self.ok("Total", "es"))

    def test_identical_fails_for_plain_english(self):
        for v in ["Cancel", "Save", "Trash pickup is tomorrow", "Yes", "Kendall", "Little Haiti", "Hello, %@",
                  "Check your mail", "Close"]:
            with self.subTest(v=v):
                self.assertFalse(self.ok(v, "es"))
        self.assertFalse(self.ok("No", "ht"))  # Creole is "Non"

    def test_markers(self):
        self.assertTrue(self.ok("Kendall", comment="Neighborhood [name]"))
        self.assertTrue(self.ok("Hialeah", comment="City [Do-Not-Translate]"))
        self.assertTrue(self.ok("Hialeah", shouldTranslate=False))
        self.assertTrue(self.ok("Piano", "es", comment="[same:es, ht]"))
        self.assertTrue(self.ok("Piano", "ht", comment="[same:es,ht]"))
        self.assertFalse(self.ok("Piano", "ht", comment="[same:es]"))

    def test_placeholder_scanner(self):
        kinds = lambda s: [k for _t, _p, k in csp.specifiers(s)]  # noqa: E731
        self.assertEqual(kinds("50% off"), [])
        self.assertEqual(kinds("100 % de descuento"), [])
        self.assertEqual(kinds("%lld%% done"), ["int64"])
        self.assertEqual(kinds("%1$@ %2$lld %.2f %d %ld"), ["object", "int64", "double", "int", "int64"])
        self.assertEqual(kinds("Tienes %#@n@"), ["sub:n"])
        self.assertEqual(kinds("%arg tareas"), ["arg"])

    def test_substitution_reference_takes_an_argument_slot(self):
        leaves = lambda v: [csp.Leaf("stringUnit", {"value": v}, None)]  # noqa: E731
        en = csp._signature(leaves("%#@n@ in %@"), None)
        es = csp._signature(leaves("%2$@: %1$#@n@"), None)
        self.assertEqual(en[0], es[0])
        self.assertEqual(en[0], {2: {"object"}})

    def test_phone_detector(self):
        for v in ["1-800-%lld", "(305) %@", "305-%@-0100", "+1 305 %@", "305%@"]:
            with self.subTest(v=v):
                self.assertIsNotNone(csp.phone_with_specifier(v))
        for v in ["Paso %lld de 3", "2026 (%@)", "Más de 1.000 %@", "%lld-%lld años", "Llame al %@",
                  "%1$@ – %2$@", "Hace %lld min", "Ruta 9: %lld min", "Unidad 305 %@", "Desde 2020-%lld",
                  "$100-%lld", "Edades 18-65 %@", "305-%@"]:
            with self.subTest(v=v):
                self.assertIsNone(csp.phone_with_specifier(v))

    def test_raw_key_heuristic(self):
        for v in ["a11y.card.readAloud", "household.row.add", "card_detail_title", "household.add"]:
            self.assertTrue(csp.looks_like_raw_key(v), v)
        for v in ["U.S.", "4.5", "p.m.", "$0.66", "miamidade.gov", "www.miamidade.gov", "EE. UU.", "Sr.Pérez",
                  "OK", "Miami-Dade", "a.m./p.m."]:
            self.assertFalse(csp.looks_like_raw_key(v), v)


if __name__ == "__main__":
    unittest.main(verbosity=2)
