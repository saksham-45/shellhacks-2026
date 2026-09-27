import json
from pathlib import Path

import pytest

from myad_server.ledger import LedgerError, load_ledger


def test_fixture_ledger_loads_and_indexes_lookup_and_desk_facts(ledger):
    assert len(ledger.facts) >= 10
    assert ledger.lookup_for("us-fl-miamidade.test.trash-days.2").id == "us-fl-miamidade.test.trash-days"
    assert ledger.lookup_for("us-fl-miamidade.test.trash-days.1.days").id == "us-fl-miamidade.test.trash-days"
    assert ledger.lookup_for("us-fl-miamidade.test.school.district") is None
    assert [f.id.rsplit(".", 1)[-1] for f in ledger.desk_facts("us-fl-miamidade.test-desk")] == ["name", "phone", "hours"]
    assert ledger.get("us-fl-miamidade.test.trash-days.demo.pin-test1").status == "demo"


def test_loader_rejects_duplicate_ids(tmp_path: Path):
    facts = tmp_path / "facts"
    facts.mkdir()
    row = {
        "id": "us.example.fact", "claim": "TEST duplicate", "value": {"type": "flag", "value": True},
        "jurisdiction": "us", "source_id": "s", "url": "https://example.invalid/fact",
        "quote": "TEST FIXTURE", "retrieved_at": "2026-09-25T12:00:00-04:00",
        "check_every": "P1D", "status": "verified", "value_type": "flag",
    }
    (facts / "one.json").write_text(json.dumps([row]))
    (facts / "two.json").write_text(json.dumps([row]))
    (tmp_path / "sources.yaml").write_text("sources:\n  - id: s\n    publisher: TEST\n")
    with pytest.raises(LedgerError, match="duplicate id"):
        load_ledger(facts, tmp_path / "sources.yaml")


def test_loader_rejects_invalid_lookup_invariant(tmp_path: Path):
    facts = tmp_path / "facts"
    facts.mkdir()
    row = {
        "id": "us.example.lookup", "claim": "TEST bad lookup", "value": {"type": "flag", "value": True},
        "jurisdiction": "us", "source_id": "s", "url": "https://example.invalid/fact",
        "quote": "TEST FIXTURE", "retrieved_at": "2026-09-25T12:00:00-04:00",
        "check_every": "P1D", "status": "verified", "kind": "lookup", "value_type": "flag",
    }
    (facts / "bad.json").write_text(json.dumps([row]))
    (tmp_path / "sources.yaml").write_text("sources:\n  - id: s\n    publisher: TEST\n")
    with pytest.raises(LedgerError, match="must have value null"):
        load_ledger(facts, tmp_path / "sources.yaml")
