"""Every region value, in both pin fixtures and in the ledger drafts, validates against Agents' /v1 FactValue."""
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[1]
SERVER_SRC = HERE.parent / "src"
PHONE_FIXTURES = HERE.parents[1] / "ios/Packages/ADCityPack/Sources/ADCityPack/Resources/Fixtures"


def _fact_value_adapter():
    sys.path.insert(0, str(SERVER_SRC))
    try:
        from pydantic import TypeAdapter
        from myad_server.values import FactValue
    except ImportError as e:  # server package or pydantic not installed in this interpreter
        pytest.skip(f"myad_server.values not importable here: {e}")
    finally:
        sys.path.remove(str(SERVER_SRC))
    return TypeAdapter(FactValue)


def _values():
    for path in sorted(PHONE_FIXTURES.glob("pin-*.json")) + sorted((HERE / "ledger-draft").glob("demo-*.json")):
        doc = json.loads(path.read_text(encoding="utf-8"))
        rows = doc.get("results") if isinstance(doc, dict) else doc
        if rows is None and isinstance(doc, dict):
            rows = doc.get("facts") or doc.get("entries") or []
        for r in rows:
            if isinstance(r, dict) and r.get("value") is not None:
                yield f"{path.name}:{r.get('fact_id') or r.get('id')}", r["value"]


def test_every_region_value_is_a_v1_fact_value():
    adapter = _fact_value_adapter()
    values = list(_values())
    assert len(values) > 30, "expected both pins' values and the demo ledger drafts"
    bad = []
    for where, v in values:
        try:
            adapter.validate_python(v)
        except Exception as e:  # pydantic ValidationError
            bad.append(f"{where}: {str(e).splitlines()[0]}")
    assert not bad, "\n".join(bad)
