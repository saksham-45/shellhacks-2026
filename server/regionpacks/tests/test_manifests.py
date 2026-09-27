"""Manifests, desks, topics, value types, and fixture hygiene."""
import json
import re
from pathlib import Path

import pytest

from myad_regions import adapters as A
from myad_regions.manifests import (PACK_ORDER, ROOT, TOPICS, adapters_for_topic, all_adapters, manifest,
                                    manifests, sources)
from myad_regions.types import VALUE_TYPES, validate_value

TREE = ROOT.parent.parent
DESK = re.compile(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$")


def vocabulary() -> set[str]:
    topics_yaml = TREE / "research" / "topics.yaml"
    if topics_yaml.exists():  # Research's single vocabulary wins once it exists
        import yaml
        data = yaml.safe_load(topics_yaml.read_text(encoding="utf-8")) or {}
        items = data.get("topics", data) if isinstance(data, dict) else data
        return {t["slug"] if isinstance(t, dict) else str(t) for t in items}
    return set(TOPICS)


def test_manifests_chain_and_levels():
    ms = manifests()
    assert [m.id for m in ms] == list(PACK_ORDER)
    assert [m.level for m in ms] == ["country", "state", "county", "city"]
    for m in ms[1:]:
        assert m.parent == PACK_ORDER[PACK_ORDER.index(m.id) - 1]
    for m in ms:
        assert set(m.languages) == {"es", "en", "ht"}


def test_desks_are_ids_only_and_declared():
    for m in manifests():
        assert m.desks_placeholder is True  # placeholder ids until myAD Research posts the final ones
        for d in m.desks:
            assert DESK.match(d) and d.startswith(m.id + ".")
            assert not re.search(r"\d{3}[-. ]?\d{4}|https?:|@", d)  # no phone, url, address, hours
        for a in m.adapters:
            assert a.desk in m.desks
    raw = json.loads((ROOT / "us-fl-miamidade" / "manifest.json").read_text())
    assert not {"phone", "address", "hours", "url"} & {k for a in raw["adapters"] for k in a}


def test_every_emitted_id_is_declared_in_its_manifest(answers):
    declared = {f.id: a.pack for a in all_adapters() for f in a.facts}
    for res in answers.values():
        for fid, r in res.items():
            assert declared.get(fid) == r["pack"]


def test_every_adapter_has_code_and_every_class_has_a_manifest_entry():
    assert {a.id for a in all_adapters()} == set(A.registry())
    for a in all_adapters():
        for s in a.sources:
            assert s in sources()


def test_fact_ids_are_prefixed_lowercase_and_ranked_1_to_3():
    for a in all_adapters():
        for f in a.facts:
            assert re.match(r"^[a-z0-9-]+(\.[a-z0-9-]+)+$", f.id) and f.id.startswith(a.pack + ".")
            ranks = [p for p in f.id.split(".") if p.isdigit()]
            assert all(r in ("1", "2", "3") for r in ranks)


def test_topic_tags_come_from_the_vocabulary():
    vocab = vocabulary()
    for a in all_adapters():
        for f in a.facts:
            assert f.topics, f.id
            assert set(f.topics) <= vocab, (f.id, f.topics)
    ledger = json.loads((ROOT / "ledger-draft" / "lookups.json").read_text())
    for e in ledger:
        assert set(e.get("topics") or []) <= vocab, e["id"]
    assert "recycling" not in vocab and "government" not in vocab


def test_adapters_for_topic():
    trash = dict(adapters_for_topic("trash"))
    assert set(trash) == {"us-fl-miamidade.trash-county-garbage", "us-fl-miamidade.trash-county-recycling",
                          "us-fl-miami.trash-city"}
    assert trash["us-fl-miamidade.trash-county-recycling"] == ["us-fl-miamidade.trash.recycling-day",
                                                               "us-fl-miamidade.trash.recycling-week"]
    assert "us-fl-miami.trash-city" not in dict(adapters_for_topic("trash", packs=["us", "us-fl", "us-fl-miamidade"]))
    assert adapters_for_topic("tolls") == []


def test_ledger_draft_lookups_cover_manifests_and_have_desks():
    ledger = json.loads((ROOT / "ledger-draft" / "lookups.json").read_text())
    ids = {e["id"] for e in ledger}
    assert {f.id for a in all_adapters() for f in a.facts} <= ids
    for e in ledger:
        assert e["desk"] and e["desk"] in manifest(e["id"].split(".")[0]).desks, e["id"]


def test_value_types_are_exactly_the_ten_adcore_cases(answers):
    assert VALUE_TYPES == {"text", "code", "codes", "phone", "date", "money", "quantity", "weekdays", "place", "flag"}
    for bad in ("verbatim", "number", "url", "string"):
        assert validate_value({"type": bad, "text": "x", "value": "1"})
    for res in answers.values():
        for r in res.values():
            if r["value"] is not None:
                assert r["value"]["type"] in VALUE_TYPES


def test_place_facts_have_name_lat_lon(answers):
    for res in answers.values():
        for fid, r in res.items():
            if any(k in fid for k in (".school.elementary", ".school.middle", ".school.high", ".parks.", ".library.",
                                      ".polling-place")) and not fid.endswith((".phone", ".grades")):
                if r["status"] == "ok":
                    v = r["value"]
                    c = v["place"]["coordinate"]
                    assert v["type"] == "place" and v["place"]["name"]
                    assert isinstance(c["latitude"], float) and isinstance(c["longitude"], float)
            if re.search(r"nearest-stop\.\d$", fid):
                assert r["value"]["type"] == "place"


# The plan's wrong year for 111 NW 1st St must never appear as a value (the county parcel says 1984). Matched as a
# standalone number: coordinate digits such as -80.19255... are not a year.
WRONG_YEAR = re.compile(r"(?<![\d.])%d(?!\d)" % (1900 + 25))
PERSONAL = re.compile(r"TRUE_OWNER|OWNER\d|MAILING|CONTACT|CREATEDBY|MODIFIEDBY|EMAIL|GlobalID|MUNICUID", re.I)
FILES = sorted(p for d in ("fixtures", "data", "ledger-draft") for p in (ROOT / d).rglob("*.json"))


@pytest.mark.parametrize("path", FILES, ids=lambda p: str(p.relative_to(ROOT)))
def test_saved_files_are_json_without_personal_fields_or_wrong_year(path):
    text = path.read_text(encoding="utf-8")
    json.loads(text)
    assert not PERSONAL.search(text), path
    assert not WRONG_YEAR.search(text)
    assert "<html" not in text.lower() and "AIza" not in text


@pytest.mark.parametrize("meta", sorted((ROOT / "fixtures").rglob("*.meta.json")), ids=lambda p: p.name)
def test_every_fixture_has_url_and_retrieved_at(meta):
    from datetime import datetime
    m = json.loads(meta.read_text())
    assert m["request_url"].startswith("https://") and "/identify" not in m["request_url"]
    assert datetime.fromisoformat(m["retrieved_at"]).utcoffset() is not None
    assert meta.with_name(meta.name.replace(".meta.json", ".json")).exists()


def test_ios_copy_is_in_sync():
    import subprocess
    import sys
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "export_fixtures.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
