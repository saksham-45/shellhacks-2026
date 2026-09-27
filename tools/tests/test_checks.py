from pathlib import Path

import check_fact_coverage
import check_string_parity

FIX = Path(__file__).parent / "fixtures"


def test_parity_passes_with_all_three():
    assert check_string_parity.main(["--root", str(FIX / "parity_pass")]) == 0


def test_parity_fails_when_ht_missing(capsys):
    assert check_string_parity.main(["--root", str(FIX / "parity_fail")]) == 1
    assert "missing ht" in capsys.readouterr().err


def test_parity_passes_with_no_catalogs():
    assert check_string_parity.main(["--root", str(FIX / "parity_empty")]) == 0


def test_facts_pass():
    assert check_fact_coverage.main(["--root", str(FIX / "facts_pass")]) == 0


def test_facts_fail_when_ledger_lacks_ref(capsys):
    assert check_fact_coverage.main(["--root", str(FIX / "facts_missing")]) == 1
    assert "missing from research/facts" in capsys.readouterr().err


def test_facts_fail_when_placeholder_not_in_refs(capsys):
    assert check_fact_coverage.main(["--root", str(FIX / "facts_unlisted")]) == 1
    assert "not in fact_refs" in capsys.readouterr().err


def test_facts_pass_when_empty():
    assert check_fact_coverage.main(["--root", str(FIX / "facts_empty")]) == 0
