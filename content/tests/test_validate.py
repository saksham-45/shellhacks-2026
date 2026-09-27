"""Tests for content/tools/validate.py.

Each test builds a tiny valid content tree in a temp dir, breaks one rule, and checks
the validator catches it. The last tests run the validator on the real tree.
"""
from __future__ import annotations

import copy
import json
import os
import shutil
import stat
from pathlib import Path

import pytest
import yaml

import validate

CONTENT = Path(__file__).resolve().parent.parent
TS = {"es": "draft", "ht": "draft"}


def loc(en: str, es: str | None = None, ht: str | None = None) -> dict:
    return {"es": es or f"es {en}", "en": en, "ht": ht or f"ht {en}"}


def fact(fid, kind="static", value_type="phone", topic="general", used_by=(), card="emergency",
         desk="us.911", **extra) -> dict:
    f = {"id": fid, "card": card, "need": "A claim.", "hint": "plan", "kind": kind, "value_type": value_type,
         "desk": desk, "plan_text": "plan text", "source": {"publisher": "Agency", "url": None},
         "fact_type": "official", "topic": topic, "status": "requested", "used_by": list(used_by)}
    f.update(extra)
    return f


def base_facts() -> dict:
    return {"requested": [
        fact("us.911.name", value_type="code", used_by=["desk:us.911"]),
        fact("us.911.phone", used_by=["card:emergency", "desk:us.911"], topics=["desk"]),
        fact("us.uscis.name", value_type="code", used_by=["desk:us.uscis"], card="mail", desk="us.uscis"),
        fact("us.uscis.address-change.deadline", value_type="quantity", unit="day", topic="immigration",
             used_by=["card:mail"], card="mail", desk="us.uscis", topics=["immigration"]),
        fact("us-fl-miamidade.311.name", value_type="code", used_by=["desk:us-fl-miamidade.311"],
             card="trash", desk="us-fl-miamidade.311"),
        fact("us-fl-miamidade.trash.garbage-days", kind="lookup", value_type="weekdays",
             question="Which weekdays is garbage collected here?",
             endpoint="CommunityServices/MD_GarbageRecycle/MapServer/1",
             used_by=["card:trash"], card="trash", desk="us-fl-miamidade.311", topics=["trash"]),
        fact("us-fl-miamidade.immigration-legal-aid.name", value_type="code",
             used_by=["desk:us-fl-miamidade.immigration-legal-aid"], card="mail",
             desk="us-fl-miamidade.immigration-legal-aid"),
        fact("us-fl-miamidade.immigration-legal-aid.phone", value_type="phone",
             used_by=["desk:us-fl-miamidade.immigration-legal-aid"], card="mail",
             desk="us-fl-miamidade.immigration-legal-aid"),
    ]}


def desk(did, name, level="any", imm=False, fields=("name", "phone"), kind="static") -> dict:
    return {"id": did, "name": name, "level": level, "immigration": imm, "contact_kind": kind,
            "contact_fields": list(fields), "fact_refs": [f"{did}.{f}" for f in fields]}


def base_desks() -> dict:
    return {"translation_status": TS, "desks": [
        desk("us.911", loc("Emergency line", "Línea de emergencias", "Liy ijans")),
        desk("us.uscis", loc("USCIS"), level="federal", imm=True, fields=("name",)),
        desk("us-fl-miamidade.immigration-legal-aid", loc("Accredited legal help"), level="nonprofit",
             imm=True, fields=("name", "phone")),
        desk("us-fl-miamidade.311", loc("Miami-Dade county desk"), level="county", fields=("name",)),
    ]}


def card(cid: str, body=None, paragraph_facts=None, **over) -> dict:
    c = {
        "id": cid, "kind": "card", "status": "draft",
        "plan_refs": [{"plan": "myamericandream-plan.md", "section": "Test"}],
        "title": loc(f"Title {cid}"), "summary": loc("Summary"),
        "body": body or loc("Plain words."), "translation_status": dict(TS),
        "paragraph_facts": paragraph_facts if paragraph_facts is not None else [[]],
        "desk": "us.911", "privacy_scope": "person", "stages": [1],
        "modes": ["resident"], "region_pack": "us", "is_immigration": False, "fact_refs": [], "topics": ["desk"],
        "utterances": {"es": [f"abre {cid}", f"quiero ver {cid}", f"{cid} por favor"],
                       "en": [f"open {cid}", f"show me {cid}", f"{cid} please"],
                       "ht": [f"louvri {cid}", f"montre m {cid}", f"{cid} souple"]},
    }
    c.update(over)
    # `immigration` is the bundle override: present only when is_immigration differs from the
    # compiler's default (privacy_scope == person-papers).
    if "immigration" not in over and c["is_immigration"] != (c["privacy_scope"] == "person-papers"):
        c["immigration"] = c["is_immigration"]
    c.setdefault("needs_review", {"es": True, "en": False, "ht": True})
    return c


def base_cards() -> dict[str, dict]:
    emergency = card("emergency", modes=["resident", "tourist"], stages=[1, 10],
                     body=loc("Call {fact:us.911.phone}.", "Llama al {fact:us.911.phone}.",
                              "Rele {fact:us.911.phone}."),
                     paragraph_facts=[["us.911.phone"]], fact_refs=["us.911.phone"],
                     origin_lenses=["tourist"], actions=[{"type": "call_desk", "desk_id": "us.911"}])
    mail = card("mail", privacy_scope="person-papers", desk="us.uscis", stages=[2], is_immigration=True,
                region_pack="us-fl-miamidade",
                body=loc("Tell USCIS within {fact:us.uscis.address-change.deadline}.\n\nKeep the letter.",
                         "Avisa a USCIS en {fact:us.uscis.address-change.deadline}.\n\nGuarda la carta.",
                         "Di USCIS nan {fact:us.uscis.address-change.deadline}.\n\nKenbe lèt la."),
                paragraph_facts=[["us.uscis.address-change.deadline"], []],
                fact_refs=["us.uscis.address-change.deadline"],
                related_cards=["status-word"],
                actions=[{"type": "call_desk", "desk_id": "us-fl-miamidade.immigration-legal-aid"}])
    trash = card("trash", privacy_scope="household", desk="us-fl-miamidade.311", stages=[10],
                 region_pack="us-fl-miamidade",
                 body=loc("Trash: {fact:us-fl-miamidade.trash.garbage-days}.",
                          "Basura: {fact:us-fl-miamidade.trash.garbage-days}.",
                          "Fatra: {fact:us-fl-miamidade.trash.garbage-days}."),
                 paragraph_facts=[["us-fl-miamidade.trash.garbage-days"]],
                 fact_refs=["us-fl-miamidade.trash.garbage-days"])
    stage = card("stage-safe", kind="stage", hero_cards=["emergency"])
    lens_card = card("lens-tourist", kind="lens", modes=["tourist"], origin_lenses=["tourist"])
    status = card("status-word")
    return {c["id"]: c for c in (emergency, mail, trash, stage, lens_card, status)}


def base_lens() -> dict:
    return {
        "id": "tourist", "origin_lens": "tourist", "status": "draft",
        "plan_refs": [{"plan": "myamericandream-plan.md", "section": "Origin lens"}],
        "title": loc("Tourists"), "summary": loc("For a short visit."), "translation_status": dict(TS),
        "needs_review": {"es": True, "en": False, "ht": True}, "desk": "us.911",
        "origin_match": {"goals": ["visit"], "self_select": True},
        "modes": ["tourist"], "lens_card": "lens-tourist", "attaches_to": ["emergency"],
        "origin_lines": [{"card": "emergency", "fact_refs": [], "text": loc("At home the number may differ.")}],
        "fact_refs": [],
    }


def write_tree(root: Path, facts=None, desks=None, cards=None, lenses=None) -> Path:
    content = root / "content"
    shutil.copytree(CONTENT / "schema", content / "schema")
    (content / "cards").mkdir()
    (content / "lenses").mkdir()

    def dump(p: Path, d) -> None:
        p.write_text(yaml.safe_dump(d, allow_unicode=True, sort_keys=False), encoding="utf-8")

    dump(content / "facts-requested.yaml", facts if facts is not None else base_facts())
    dump(content / "desks.yaml", desks if desks is not None else base_desks())
    for c in (cards if cards is not None else base_cards()).values():
        dump(content / "cards" / f"{c['id']}.yaml", c)
    for lens in (lenses if lenses is not None else [base_lens()]):
        dump(content / "lenses" / f"{lens['id']}.yaml", lens)
    return content


def errors_for(tmp_path, **kw) -> list[str]:
    return validate.validate(write_tree(tmp_path, **kw)).errors


def assert_error(errors: list[str], needle: str) -> None:
    assert any(needle in e for e in errors), f"expected {needle!r} in:\n" + "\n".join(errors)


# ---------------------------------------------------------------- baseline
def test_fixture_is_valid(tmp_path):
    assert errors_for(tmp_path) == []


# ---------------------------------------------------------------- languages
def test_missing_language_fails(tmp_path):
    cards = base_cards()
    del cards["trash"]["title"]["ht"]
    assert_error(errors_for(tmp_path, cards=cards), "missing required field 'ht'")


def test_empty_language_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"]["es"] = "   "
    assert_error(errors_for(tmp_path, cards=cards), "empty")


def test_translation_status_required(tmp_path):
    cards = base_cards()
    del cards["trash"]["translation_status"]
    assert_error(errors_for(tmp_path, cards=cards), "missing required field 'translation_status'")


def test_placeholders_must_match_across_languages(tmp_path):
    cards = base_cards()
    cards["trash"]["body"]["ht"] = "Fatra chak semèn."
    assert_error(errors_for(tmp_path, cards=cards), "placeholders differ between languages")


def test_paragraph_counts_must_match(tmp_path):
    cards = base_cards()
    cards["mail"]["body"]["ht"] = "Di USCIS nan {fact:us.uscis.address-change.deadline}. Kenbe lèt la."
    assert_error(errors_for(tmp_path, cards=cards), "paragraph count differs")


def test_paragraph_facts_length_must_match(tmp_path):
    cards = base_cards()
    cards["mail"]["paragraph_facts"] = [["us.uscis.address-change.deadline"]]
    assert_error(errors_for(tmp_path, cards=cards), "paragraph_facts has 1 lists for 2 paragraphs")


# ---------------------------------------------------------------- facts
def test_unknown_fact_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["paragraph_facts"][0].append("us-fl-miamidade.trash.recycling-day")
    cards["trash"]["fact_refs"].append("us-fl-miamidade.trash.recycling-day")
    assert_error(errors_for(tmp_path, cards=cards), "is not in facts-requested.yaml")


def test_placeholder_must_be_in_paragraph_facts(tmp_path):
    cards = base_cards()
    cards["trash"]["paragraph_facts"] = [[]]
    assert_error(errors_for(tmp_path, cards=cards), "placeholders not in paragraph_facts[0]")


def test_card_fact_refs_must_equal_union(tmp_path):
    cards = base_cards()
    cards["trash"]["fact_refs"] = []
    assert_error(errors_for(tmp_path, cards=cards), "fact_refs must equal")


def test_unused_fact_fails(tmp_path):
    facts = base_facts()
    extra = copy.deepcopy(facts["requested"][1])
    extra["id"] = "us.emergency.unused"
    facts["requested"].append(extra)
    assert_error(errors_for(tmp_path, facts=facts), "requested but never referenced")


def test_used_by_must_be_truthful(tmp_path):
    facts = base_facts()
    facts["requested"][1]["used_by"] = ["card:emergency"]
    assert_error(errors_for(tmp_path, facts=facts), "used_by should be")


def test_card_field_must_show_the_fact(tmp_path):
    facts = base_facts()
    facts["requested"][5]["card"] = "mail"
    assert_error(errors_for(tmp_path, facts=facts), "does not show this fact")


def test_fact_desk_must_exist(tmp_path):
    facts = base_facts()
    facts["requested"][5]["desk"] = "us.nowhere"
    assert_error(errors_for(tmp_path, facts=facts), "unknown desk 'us.nowhere'")


def test_lookup_needs_question(tmp_path):
    facts = base_facts()
    del facts["requested"][5]["question"]
    assert_error(errors_for(tmp_path, facts=facts), "lookup fact needs a question")


def test_static_fact_has_no_question(tmp_path):
    facts = base_facts()
    facts["requested"][1]["question"] = "What?"
    assert_error(errors_for(tmp_path, facts=facts), "static fact must not carry question")


@pytest.mark.parametrize("field", ["kind", "value_type"])
def test_kind_and_value_type_required(tmp_path, field):
    facts = base_facts()
    del facts["requested"][1][field]
    assert_error(errors_for(tmp_path, facts=facts), f"missing required field '{field}'")


def test_unknown_value_type_fails(tmp_path):
    facts = base_facts()
    facts["requested"][5]["value_type"] = "weekday"
    assert_error(errors_for(tmp_path, facts=facts), "not an ADCore FactValue case")


def test_local_fact_on_country_card_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["kind"] = "country"
    assert_error(errors_for(tmp_path, cards=cards), "country card cites local fact")


def _with_city_fact(extra_refs=()):
    cards = base_cards()
    facts = base_facts()
    facts["requested"].append(fact("us-fl-miami.trash.day", kind="lookup", value_type="weekdays",
                                   question="City trash day?", used_by=["card:trash"], card="trash",
                                   desk="us-fl-miamidade.311"))
    t = cards["trash"]
    t["body"] = {k: v + "\n\nCity: {fact:us-fl-miami.trash.day}." for k, v in t["body"].items()}
    t["paragraph_facts"].append(["us-fl-miami.trash.day"] + list(extra_refs))
    t["paragraph_when"] = [None, {"municipality": "us-fl-miami"}]
    t["fact_refs"] = t["fact_refs"] + ["us-fl-miami.trash.day"] + list(extra_refs)
    for f in extra_refs:
        facts["requested"].append(fact(f, kind="lookup", value_type="code", question="Which city?",
                                       used_by=["card:trash"], card="trash", desk="us-fl-miamidade.311"))
    return cards, facts


def test_city_fact_needs_paragraph_municipality_condition(tmp_path):
    cards, facts = _with_city_fact()
    cards["trash"].pop("paragraph_when")
    assert_error(errors_for(tmp_path, cards=cards, facts=facts), "needs paragraph_when municipality us-fl-miami")


def test_city_fact_with_municipality_and_county_passes(tmp_path):
    cards, facts = _with_city_fact(["us-fl-miamidade.gov.municipality"])
    assert errors_for(tmp_path, cards=cards, facts=facts) == []


def test_paragraph_when_length_must_match(tmp_path):
    cards = base_cards()
    cards["trash"]["paragraph_when"] = [None, None]
    assert_error(errors_for(tmp_path, cards=cards), "paragraph_when has 2 items for 1 paragraphs")


def test_unincorporated_fact_condition_passes_and_missing_fails(tmp_path):
    cards = base_cards()
    facts = base_facts()
    facts["requested"][5]["need"] = "Unincorporated Miami-Dade county trash days."
    cards["trash"]["paragraph_when"] = [{"municipality": "unincorporated"}]
    assert errors_for(tmp_path, cards=cards, facts=facts) == []
    cards["trash"].pop("paragraph_when")
    assert_error(errors_for(tmp_path / "bad", cards=cards, facts=facts), "needs paragraph_when municipality unincorporated")


def test_city_fact_needs_county_counterpart(tmp_path):
    cards, facts = _with_city_fact(["us-fl-miamidade.gov.municipality"])
    t = cards["trash"]
    t["body"] = {k: v.replace("{fact:us-fl-miamidade.trash.garbage-days}", "county") for k, v in t["body"].items()}
    t["paragraph_facts"][0] = []
    t["fact_refs"].remove("us-fl-miamidade.trash.garbage-days")
    facts["requested"] = [f for f in facts["requested"] if f["id"] != "us-fl-miamidade.trash.garbage-days"]
    assert_error(errors_for(tmp_path, cards=cards, facts=facts), "without a county us-fl-miamidade.trash.* counterpart")


def test_quantity_needs_unit(tmp_path):
    facts = base_facts()
    del facts["requested"][3]["unit"]
    assert_error(errors_for(tmp_path, facts=facts), "quantity fact needs a unit")


def test_desk_more_local_than_card_fails(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["desk"] = "us-fl-miamidade.311"
    assert_error(errors_for(tmp_path, cards=cards), "more local than card region")


# ---------------------------------------------------------------- tourist, immigration, privacy
def test_immigration_fact_requires_flag(tmp_path):
    cards = base_cards()
    cards["mail"]["is_immigration"] = False
    assert_error(errors_for(tmp_path, cards=cards), "is_immigration is false")


def test_tourist_card_cannot_be_immigration(tmp_path):
    cards = base_cards()
    cards["mail"]["modes"] = ["resident", "tourist"]
    cards["mail"]["stages"] = [1]
    errs = errors_for(tmp_path, cards=cards)
    assert_error(errs, "tourist-mode card is marked is_immigration")
    assert_error(errs, "tourist-mode card references immigration facts")
    assert_error(errs, "tourist-mode card ends at immigration desk")


def test_tourist_card_with_immigration_wording_fails(tmp_path):
    cards = base_cards()
    cards["emergency"]["summary"] = loc("Keep your I-94 handy.")
    assert_error(errors_for(tmp_path, cards=cards), "tourist-mode card uses immigration wording")


def test_tourist_card_rejects_hidden_stage_two_to_nine(tmp_path):
    cards = base_cards()
    cards["emergency"]["stages"] = [1, 4]
    assert_error(errors_for(tmp_path, cards=cards), "hidden stages")


def test_household_immigration_card_fails(tmp_path):
    cards = base_cards()
    cards["mail"]["privacy_scope"] = "household"
    errs = errors_for(tmp_path, cards=cards)
    assert_error(errs, "never household scope")
    assert_error(errs, "household-scope card references papers")


def test_bad_privacy_scope_fails(tmp_path):
    cards = base_cards()
    cards["mail"]["privacy_scope"] = "family"
    assert_error(errors_for(tmp_path, cards=cards), "not one of")


# ---------------------------------------------------------------- digits heuristic
@pytest.mark.parametrize("text", [
    "Call 305-555-0100.", "It costs $5.", "Tip 20 percent.", "Due March 3.",
    "Within ten days.", "About two miles.", "Tip 18%.",
])
def test_inline_values_fail(tmp_path, text):
    cards = base_cards()
    cards["stage-safe"]["body"] = loc(text, "Texto.", "Tèks.")
    assert errors_for(tmp_path, cards=cards), text


def test_number_word_without_unit_is_allowed(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["body"] = loc("Bring two proofs.", "Texto.", "Tèks.")
    assert errors_for(tmp_path, cards=cards) == []  # heuristic limit, documented in README


@pytest.mark.parametrize("es,ht", [("Dentro de diez días.", "Tèks."), ("Texto.", "Nan dis jou."),
                                    ("Texto.", "Senk pousan.")])
def test_spelled_values_fail_in_es_and_ht(tmp_path, es, ht):
    cards = base_cards()
    cards["stage-safe"]["body"] = loc("Text.", es, ht)
    assert errors_for(tmp_path, cards=cards)


def test_identifiers_are_allowed(tmp_path):
    cards = base_cards()
    cards["mail"]["summary"] = loc("Bring the I-20, or the DS-2019 for J-1. Take I-95.")
    assert errors_for(tmp_path, cards=cards) == []


def test_unknown_placeholder_fails(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["summary"] = loc("{data:parcel.year}", "{data:parcel.year}", "{data:parcel.year}")
    assert_error(errors_for(tmp_path, cards=cards), "unknown placeholder")


def test_desk_names_are_checked(tmp_path):
    desks = base_desks()
    desks["desks"][2]["name"] = loc("Miami-Dade 311")  # digits in a desk name
    assert_error(errors_for(tmp_path, desks=desks), "inline digits")


# ---------------------------------------------------------------- structure
def test_card_must_name_a_desk(tmp_path):
    cards = base_cards()
    cards["trash"]["desk"] = None
    assert_error(errors_for(tmp_path, cards=cards), "cards/trash.yaml: $.desk")


def test_desk_id_is_region_scoped(tmp_path):
    cards = base_cards()
    cards["trash"]["desk"] = "miami-dade-311"
    assert_error(errors_for(tmp_path, cards=cards), "does not match")


def test_unknown_desk_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["desk"] = "us-fl-miamidade.nowhere"
    assert_error(errors_for(tmp_path, cards=cards), "unknown desk")


def test_stage_card_shows_one_stage(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["stages"] = [1, 2]
    assert_error(errors_for(tmp_path, cards=cards), "exactly one stage")


def test_stage_hero_must_exist(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["hero_cards"] = ["ghost"]
    assert_error(errors_for(tmp_path, cards=cards), "unknown card ghost")


def test_file_name_must_match_id(tmp_path):
    content = write_tree(tmp_path)
    (content / "cards" / "trash.yaml").rename(content / "cards" / "garbage.yaml")
    assert_error(validate.validate(content).errors, "does not match file name")


def test_unknown_field_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["price"] = "cheap"
    assert_error(errors_for(tmp_path, cards=cards), "unknown field 'price'")


def test_stage_out_of_range_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["stages"] = [11]
    assert_error(errors_for(tmp_path, cards=cards), "above maximum")


# ---------------------------------------------------------------- lenses
def test_lens_link_must_be_two_way(tmp_path):
    cards = base_cards()
    cards["emergency"]["origin_lenses"] = []
    assert_error(errors_for(tmp_path, cards=cards), "does not list lens tourist")


def test_lens_needs_line_for_each_attached_card(tmp_path):
    lens = base_lens()
    lens["origin_lines"] = [dict(lens["origin_lines"][0], card="lens-tourist")]
    assert_error(errors_for(tmp_path, lenses=[lens]), "has no origin line for it")


def test_tourist_lens_rejects_immigration_fact(tmp_path):
    lens = base_lens()
    lens["origin_lines"][0]["fact_refs"] = ["us.uscis.address-change.deadline"]
    lens["fact_refs"] = ["us.uscis.address-change.deadline"]
    facts = base_facts()
    facts["requested"][3]["used_by"] = ["card:mail", "lens:tourist"]
    assert_error(errors_for(tmp_path, lenses=[lens], facts=facts), "tourist lens references immigration fact")


def test_lens_card_must_be_kind_lens(tmp_path):
    lens = base_lens()
    lens["lens_card"] = "trash"
    assert_error(errors_for(tmp_path, lenses=[lens]), "is not kind lens")


def test_origin_lens_must_be_adcore_case(tmp_path):
    lens = base_lens()
    lens["origin_lens"] = "visitor"
    assert_error(errors_for(tmp_path, lenses=[lens]), "not one of")


# ---------------------------------------------------------------- ledger
def test_ledger_missing_is_warning_then_error(tmp_path):
    content = write_tree(tmp_path)
    ledger = tmp_path / "facts"
    ledger.mkdir()
    (ledger / "us.json").write_text(json.dumps([{"id": "us.911.phone", "kind": "static"}]))
    report = validate.validate(content, ledger)
    assert report.errors == []
    assert len(report.warnings) == 7
    strict = validate.validate(content, ledger, require_ledger=True)
    assert len(strict.errors) == 7


def test_ledger_kind_mismatch_fails(tmp_path):
    content = write_tree(tmp_path)
    ledger = tmp_path / "facts"
    ledger.mkdir()
    (ledger / "trash.json").write_text(json.dumps(
        [{"id": "us-fl-miamidade.trash.garbage-days", "kind": "static", "value_type": "code"}]))
    errs = validate.validate(content, ledger).errors
    assert_error(errs, "kind 'static' in ledger")
    assert_error(errs, "value_type 'code' in ledger")


def test_main_exit_codes(tmp_path, capsys):
    content = write_tree(tmp_path)
    assert validate.main(["--content", str(content)]) == 0
    (content / "cards" / "trash.yaml").write_text("id: [broken")
    assert validate.main(["--content", str(content)]) == 1


# ---------------------------------------------------------------- utterances, actions, desks, topics
@pytest.mark.parametrize("utt", ["call 911", "how much is $5", "twenty percent tip", "{fact:us.911.phone}"])
def test_bad_utterances_fail(tmp_path, utt):
    cards = base_cards()
    cards["trash"]["utterances"]["en"][0] = utt
    assert errors_for(tmp_path, cards=cards), utt


def test_utterances_need_three_languages(tmp_path):
    cards = base_cards()
    del cards["trash"]["utterances"]["ht"]
    assert_error(errors_for(tmp_path, cards=cards), "missing required field 'ht'")


def test_empty_utterance_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["utterances"]["es"][1] = "  "
    assert_error(errors_for(tmp_path, cards=cards), "empty")


def test_duplicate_utterance_across_cards_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["utterances"]["en"][0] = "Open emergency!"
    assert_error(errors_for(tmp_path, cards=cards), "also used by card")


def test_unknown_action_fails(tmp_path):
    cards = base_cards()
    cards["emergency"]["actions"] = [{"type": "send_sms", "desk_id": "us.911"}]
    assert_error(errors_for(tmp_path, cards=cards), "does not match any allowed shape")


def test_call_desk_needs_phone_fact(tmp_path):
    cards = base_cards()
    cards["mail"]["actions"] = [{"type": "call_desk", "desk_id": "us.uscis"}]
    assert_error(errors_for(tmp_path, cards=cards), "to have a phone fact")


def test_desk_fact_refs_follow_fields(tmp_path):
    desks = base_desks()
    desks["desks"][0]["fact_refs"] = ["us.911.phone"]
    assert_error(errors_for(tmp_path, desks=desks), "fact_refs must be exactly")


def test_desk_contact_value_type_checked(tmp_path):
    facts = base_facts()
    facts["requested"][1]["value_type"] = "code"
    assert_error(errors_for(tmp_path, facts=facts), "value_type should be phone")


def test_unused_desk_fails(tmp_path):
    desks = base_desks()
    desks["desks"].append(desk("us.ssa", loc("Social Security"), fields=()))
    desks["desks"][-1]["contact_fields"] = ["name"]
    desks["desks"][-1]["fact_refs"] = ["us.ssa.name"]
    facts = base_facts()
    facts["requested"].append(fact("us.ssa.name", value_type="code", used_by=["desk:us.ssa"]))
    assert_error(errors_for(tmp_path, desks=desks, facts=facts), "desk is not used by any card")


def test_unrequested_coined_topic_fails_without_vocab(tmp_path):
    cards = base_cards()
    cards["trash"]["topics"] = ["garbage"]
    assert_error(errors_for(tmp_path, cards=cards), "not a seed tag and not in topics-requested.yaml")


def test_requested_topic_warns_without_vocab(tmp_path):
    cards = base_cards()
    cards["trash"]["topics"] = ["heat"]
    content = write_tree(tmp_path, cards=cards)
    (content / "topics-requested.yaml").write_text("requested:\n  - tag: heat\n    meaning: Heat and sun.\n")
    report = validate.validate(content)
    assert report.errors == []
    assert any("pending Research" in w for w in report.warnings)


def test_research_vocab_is_the_authority(tmp_path):
    cards = base_cards()
    cards["trash"]["topics"] = ["trash", "heat"]
    content = write_tree(tmp_path, cards=cards)
    research = tmp_path / "research"
    research.mkdir()
    (research / "topics.yaml").write_text("topics:\n  - trash\n  - desk\n  - immigration\n")
    assert_error(validate.validate(content).errors, "topic 'heat' is not in topics.yaml")




# --- round-one policy decisions ------------------------------------------------------------
def test_tourist_related_card_must_also_be_tourist(tmp_path):
    cards = base_cards()
    cards["emergency"]["related_cards"] = ["mail"]
    assert_error(errors_for(tmp_path, cards=cards), "related_cards includes non-tourist card mail")


def test_tourist_endpoint_stages_pass(tmp_path):
    assert errors_for(tmp_path) == []


def test_immigration_card_needs_accredited_route(tmp_path):
    cards = base_cards()
    cards["mail"]["actions"] = []
    assert_error(errors_for(tmp_path, cards=cards), "must end at an accredited desk")


def _direct_policy_check(card, extra_desks=()):
    facts = {f["id"]: f for f in base_facts()["requested"]}
    desks = {d["id"]: d for d in base_desks()["desks"]}
    for d in extra_desks:
        desks[d["id"]] = d
    report = validate.Report()
    validate.check_card(card, f"cards/{card['id']}.yaml", facts, desks, report, lambda *args: None)
    return report.errors


@pytest.mark.parametrize("cid", ["lease-basics", "eviction-clock", "medical-bill"])
def test_civil_cards_end_at_legal_aid(cid):
    c = copy.deepcopy(base_cards()["trash"])
    c["id"] = cid
    c["desk"] = "us-fl-miamidade.legal-aid"
    legal = desk("us-fl-miamidade.legal-aid", loc("Legal aid"), level="county", fields=("name",))
    assert not [e for e in _direct_policy_check(c, [legal]) if "must end at" in e]


def test_civil_card_wrong_desk_fails():
    c = copy.deepcopy(base_cards()["trash"])
    c["id"] = "lease-basics"
    assert_error(_direct_policy_check(c), "lease-basics must end at us-fl-miamidade.legal-aid")


def test_health_coverage_routes_to_both_benefits_desks():
    c = copy.deepcopy(base_cards()["trash"])
    c["id"] = "health-coverage-changes"
    c["desk"] = "us-fl.dcf-access"
    c["region_pack"] = "us-fl"
    c["actions"] = [{"type": "call_desk", "desk_id": "us-fl.dcf-access"},
                     {"type": "call_desk", "desk_id": "us-fl.kidcare"}]
    dcf = desk("us-fl.dcf-access", loc("DCF"), level="state")
    kid = desk("us-fl.kidcare", loc("KidCare"), level="state")
    assert not [e for e in _direct_policy_check(c, [dcf, kid]) if "health-coverage-changes" in e]


def test_health_coverage_missing_kidcare_call_fails():
    c = copy.deepcopy(base_cards()["trash"])
    c["id"] = "health-coverage-changes"
    c["desk"] = "us-fl.dcf-access"
    c["region_pack"] = "us-fl"
    c["actions"] = [{"type": "call_desk", "desk_id": "us-fl.dcf-access"}]
    dcf = desk("us-fl.dcf-access", loc("DCF"), level="state")
    assert_error(_direct_policy_check(c, [dcf]), "must call_desk us-fl.kidcare")


def test_privacy_scope_must_match_immigration_flag(tmp_path):
    cards = base_cards()
    cards["mail"]["privacy_scope"] = "person"
    assert_error(errors_for(tmp_path, cards=cards), "privacy_scope must agree")


def test_privacy_scope_person_papers_matches_immigration(tmp_path):
    assert errors_for(tmp_path) == []


@pytest.mark.parametrize("text", [
    "TPS status: you must leave the country.",
    "Visa status: a bill in Congress will restore TPS.",
    "Permiso: valid until {fact:us.status.ead}.",
])
def test_status_hold_rejects_future_or_departure_copy(text):
    assert validate.status_date_problems(text)


def test_status_hold_allows_neutral_copy():
    assert validate.status_date_problems("TPS status depends on your papers.") == []


def test_d5_haiti_wording_rejects_forbidden_claim():
    assert validate.d5_haiti_problems("TPS for Haiti can change and may miss a window.")


def test_d5_haiti_wording_allows_neutral_line():
    assert validate.d5_haiti_problems("Each Haitian person's status depends on their papers.") == []


def test_d8_status_word_without_link_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"] = loc("Student status depends on your papers.")
    assert_error(errors_for(tmp_path, cards=cards), "D8: status word used without link to status-word")


def test_d8_status_word_with_link_passes(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"] = loc("Student status depends on your papers.")
    cards["trash"]["related_cards"] = ["status-word"]
    assert not [e for e in errors_for(tmp_path, cards=cards) if "D8: status word" in e]


def _haiti_fixture(cards, card_id="trash"):
    cards[card_id]["origin_lenses"] = ["haiti"]
    lens_card = copy.deepcopy(cards["lens-tourist"])
    lens_card.update(id="lens-haiti-test", modes=["resident"], origin_lenses=["haiti"])
    cards[lens_card["id"]] = lens_card
    lens = copy.deepcopy(base_lens())
    lens.update(id="haiti", origin_lens="haiti", modes=["resident"], lens_card=lens_card["id"],
                attaches_to=[card_id],
                origin_lines=[{"card": card_id, "fact_refs": [], "text": loc("A neutral line.")}])
    return [base_lens(), lens]


@pytest.mark.parametrize(("lang", "bad"), [
    ("en", "may change"), ("es", "pueden cambiar"), ("ht", "kapab chanje"),
])
def test_d5_haiti_card_localized_copy_fails(tmp_path, lang, bad):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    cards["trash"]["summary"][lang] = bad
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "D5: prohibited Haiti wording")


def test_d5_haiti_utterance_fails(tmp_path):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    cards["trash"]["utterances"]["ht"][0] = "pwochen etap"
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "D5: prohibited Haiti wording")


def test_d5_haiti_lens_origin_line_fails(tmp_path):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    lenses[1]["origin_lines"][0]["text"]["es"] = "próximos pasos"
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "D5: prohibited Haiti wording")


def test_d5_haiti_fixture_neutral_copy_passes(tmp_path):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    cards["trash"]["summary"] = loc("Each person has their own papers.",
                                     "Cada persona tiene sus propios documentos.",
                                     "Chak moun gen pwòp papye pa li.")
    assert not [e for e in errors_for(tmp_path, cards=cards, lenses=lenses) if "D5:" in e]


def test_d8_localized_copy_without_link_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"] = loc("Plain words.", "Tu estatus importa.", "Mo senp.")
    assert_error(errors_for(tmp_path, cards=cards), "D8: status word used without link to status-word")


def test_d8_localized_copy_with_link_passes(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"] = loc("Plain words.", "Tu estatus importa.", "Mo senp.")
    cards["trash"]["related_cards"] = ["status-word"]
    assert not [e for e in errors_for(tmp_path, cards=cards) if "D8: status word" in e]


def test_d8_utterance_only_without_link_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["utterances"]["ht"][0] = "kisa estati mwen ye"
    assert_error(errors_for(tmp_path, cards=cards), "D8: status word used without link to status-word")


def test_d8_utterance_only_with_link_passes(tmp_path):
    cards = base_cards()
    cards["trash"]["utterances"]["ht"][0] = "kisa estati mwen ye"
    cards["trash"]["related_cards"] = ["status-word"]
    assert not [e for e in errors_for(tmp_path, cards=cards) if "D8: status word" in e]


@pytest.mark.parametrize("text", ["your status requirement", "status-requirement"])
def test_d8_status_near_miss_still_fails(tmp_path, text):
    cards = base_cards()
    cards["trash"]["summary"] = loc(text)
    assert_error(errors_for(tmp_path, cards=cards), "D8: status word used without link to status-word")


def test_d8_exact_exemptions_are_narrow(tmp_path):
    assert not validate._d8_text_used("filing status", "en")
    assert not validate._d8_text_used("{fact:us-fl.liheap.household-status-requirement}", "en")
    assert validate._d8_text_used("your status requirement", "en")
    # only the one LIHEAP placeholder is exempt; every other placeholder id is scanned (F7)
    assert validate._d8_text_used("{fact:x.immigration-status}", "en")
    assert validate._d8_text_used("{fact:us.hhs.45-cfr-92.201.status}", "en")
    assert validate._d8_text_used("{fact:us-fl.liheap.household-status-requirement} {fact:x.status}", "en")


@pytest.mark.parametrize(("text", "lang"), [
    ("We do not prepare returns or pick a filing status.", "en"),
    ("Nou pa prepare deklarasyon ni chwazi estati deklarasyon ou.", "ht"),
    # es wording needs no exemption: "forma de declarar" holds no D8 word
    ("No preparamos declaraciones ni escogemos tu forma de declarar.", "es"),
])
def test_d8_tax_filing_phrases_are_exempt(text, lang):
    assert not validate._d8_text_used(text, lang)


@pytest.mark.parametrize(("text", "lang"), [
    ("Your status matters; so does your filing status.", "en"),
    ("Estati ou enpòtan; estati deklarasyon an tou.", "ht"),
    ("estati imigrasyon ou", "ht"),
])
def test_d8_tax_exemptions_leave_other_status_words(text, lang):
    assert validate._d8_text_used(text, lang)


def test_d8_other_placeholder_without_link_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"] = loc("See {fact:us.hhs.45-cfr-92.201.status}.")
    cards["trash"]["fact_refs"] = cards["trash"]["fact_refs"] + ["us.hhs.45-cfr-92.201.status"]
    assert_error(errors_for(tmp_path, cards=cards), "D8: status word used without link to status-word")


@pytest.mark.parametrize(("lang", "text"), [
    ("en", "status"), ("en", "statuses"), ("en", "lawful presence"), ("en", "parole"), ("en", "paroled"),
    ("en", "parolee"), ("en", "parolees"),
    ("es", "estatus"), ("es", "estatus migratorio"), ("es", "situación migratoria"), ("es", "situacion migratoria"),
    ("es", "situaciones migratorias"), ("es", "estado migratorio"), ("es", "parole"), ("es", "qué es el parole"),
    ("ht", "estati"), ("ht", "parole"), ("ht", "kisa parole ye"), ("ht", "parol imanitè"),
    ("ht", "sitiyasyon imigrasyon"), ("ht", "prezans legal"),
])
def test_d8_vocabulary_matches(lang, text):
    assert validate._d8_text_used(text, lang)


@pytest.mark.parametrize(("lang", "text"), [
    ("en", "mi tps"), ("es", "mi tps"), ("ht", "tps mwen"), ("en", "my daca renewal"), ("en", "opt and cpt"),
    ("en", "ask the dso"), ("es", "Tu TPS"), ("ht", "Daca"),
])
def test_d8_acronyms_match_case_insensitively(lang, text):
    assert validate._d8_text_used(text, lang)


@pytest.mark.parametrize(("lang", "text"), [
    ("ht", "Se yon bèl parol."),  # "parol" alone is "word/speech" in Creole
    ("en", "optional steps"), ("en", "a stats page"), ("es", "estado de cuenta"),
    ("en", "tapster"),
])
def test_d8_vocabulary_word_boundaries(lang, text):
    assert not validate._d8_text_used(text, lang)


def test_d8_lowercase_acronym_utterance_without_link_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["utterances"]["es"][0] = "qué pasa con mi tps"
    assert_error(errors_for(tmp_path, cards=cards), "D8: status word used without link to status-word")


@pytest.mark.parametrize(("key", "lang", "value"), [
    ("label", "en", "Ask about your status"),
    ("label", "es", "Pregunta por tu estatus"),
    ("labels", "ht", "Mande sou estati ou"),
])
def test_d8_localized_action_label_counts(key, lang, value):
    c = copy.deepcopy(base_cards()["trash"])
    c["actions"] = [{"type": "call_desk", "desk_id": "us.911", key: {"en": "Call", "es": "Llama", "ht": "Rele", lang: value}}]
    assert validate.d8_status_word_used(c)
    c["actions"][0][key][lang] = "Call"
    assert not validate.d8_status_word_used(c)


def test_d8_string_action_label_counts():
    c = copy.deepcopy(base_cards()["trash"])
    c["actions"] = [{"type": "call_desk", "desk_id": "us.911", "label": "TPS help"}]
    assert validate.d8_status_word_used(c)


def _status_lens_fixture(cards, link=None, title=None, summary=None,
                         line_text=("Your status matters.", "Texto sencillo.", "Mo senp.")):
    """link: None, "attaches_to" (lens attaches status-word, no origin line for it), or
    "origin_line" (origin line for status-word only). Each linking condition is tested alone."""
    cards["trash"]["origin_lenses"] = ["questionnaire"]
    lens_card = copy.deepcopy(cards["lens-tourist"])
    lens_card.update(id="lens-questionnaire-test", modes=["resident"], origin_lenses=["questionnaire"])
    lens_card["utterances"] = {lang: [u.replace("lens-tourist", "lens-questionnaire-test")
                                        for u in values]
                                for lang, values in lens_card["utterances"].items()}
    cards[lens_card["id"]] = lens_card
    lens = copy.deepcopy(base_lens())
    lens.update(id="questionnaire", origin_lens="questionnaire", modes=["resident"], lens_card=lens_card["id"],
                attaches_to=["trash"], origin_lines=[{
                    "card": "trash", "fact_refs": [], "text": loc(*line_text)
                }])
    if title is not None:
        lens["title"] = loc(*title)
    if summary is not None:
        lens["summary"] = loc(*summary)
    if link == "attaches_to":
        lens["attaches_to"].append("status-word")
        cards["status-word"].setdefault("origin_lenses", []).append("questionnaire")
    elif link == "origin_line":
        lens["origin_lines"].append({"card": "status-word", "fact_refs": [], "text": loc("Plain line.")})
    elif link is not None:
        raise ValueError(link)
    return [base_lens(), lens]


def test_d8_lens_path_without_status_word_fails(tmp_path):
    cards = base_cards()
    lenses = _status_lens_fixture(cards)
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "D8: status word used without link to status-word")


@pytest.mark.parametrize(("link", "consistency_error"), [
    ("attaches_to", "attaches to status-word but has no origin line for it"),
    ("origin_line", "card status-word is not in attaches_to"),
])
def test_d8_lens_each_link_condition_alone_passes_d8(tmp_path, link, consistency_error):
    cards = base_cards()
    lenses = _status_lens_fixture(cards, link=link)
    errs = errors_for(tmp_path, cards=cards, lenses=lenses)
    assert not [e for e in errs if "D8: status word" in e]
    # each half alone is still caught by the lens link-consistency checks
    assert_error(errs, consistency_error)


@pytest.mark.parametrize("field", ["title", "summary"])
@pytest.mark.parametrize(("lang_i", "word"), [(0, "Status"), (1, "Estatus"), (2, "Estati")])
def test_d8_lens_title_and_summary_without_link_fail(tmp_path, field, lang_i, word):
    cards = base_cards()
    texts = ["Plain.", "Sencillo.", "Senp."]
    texts[lang_i] = word
    kw = {field: tuple(texts), "line_text": ("A plain line.", "Texto sencillo.", "Mo senp.")}
    lenses = _status_lens_fixture(cards, **kw)
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "D8: status word used without link to status-word")


def test_d8_lens_plain_title_and_summary_pass(tmp_path):
    cards = base_cards()
    lenses = _status_lens_fixture(cards, title=("Plain.", "Sencillo.", "Senp."),
                                  summary=("Plain.", "Sencillo.", "Senp."),
                                  line_text=("A plain line.", "Texto sencillo.", "Mo senp."))
    assert not [e for e in errors_for(tmp_path, cards=cards, lenses=lenses) if "D8: status word" in e]


# --- D5 variants (F9) --------------------------------------------------------------------------
@pytest.mark.parametrize("text", [
    "Your next step is a call.", "Your next steps are here.",
    "Tu próximo paso es llamar.", "Tus próximos pasos.", "Tu proximo paso.",
    "Pwochen etap ou se yon apèl.",
    "The rules will change.", "The rules can change.", "Las reglas podrían cambiar.", "La regla puede cambiar.",
    "La regla podría cambiar.", "Règ yo ka chanje.", "Règ yo pral chanje.",
])
def test_d5_always_variants_fail(text):
    assert validate.d5_haiti_problems(text), text


@pytest.mark.parametrize("text", [
    "With TPS you have to leave.", "If your status ends you must leave.", "Your papers expire and you need to leave.",
    "Con TPS deben salir.", "Si tu estatus termina tienen que salir.", "Con esos papeles debes salir.",
    "A bill would restore TPS.", "Congress restores the status.", "They may restore your status.",
    "Pueden restablecer el TPS.", "Van a restaurar tu estatus.",
    "Ak TPS ou oblije kite.", "Si estati ou fini, fòk ou kite.", "Yo ka retabli TPS la.", "Papye ou: ou dwe kite.",
    "There is a window for TPS.", "Hay una ventana para el TPS.", "Gen yon fenèt pou TPS.",
    # leaving the country fails even with no other status word in the sentence
    "You must leave the country.", "Debes salir del país.", "Ou dwe kite peyi a.",
])
def test_d5_status_context_variants_fail(text):
    assert validate.d5_haiti_problems(text), text


@pytest.mark.parametrize("text", [
    "The power company will restore service after the storm.",
    "Después de la tormenta van a restaurar la luz.",
    "Kouran an ap retabli apre tanpèt la.",
    "The bus must leave on time.", "El bus debe salir a tiempo.", "Bis la dwe soti alè.",
    "Buy it at the ticket window.", "Compra en la ventana de boletos.", "Achte l nan fenèt tikè a.",
])
def test_d5_broad_terms_without_status_context_pass(text):
    assert validate.d5_haiti_problems(text) == [], text


def test_d5_context_is_per_sentence():
    assert validate.d5_haiti_problems("TPS is one topic. The bus must leave on time.") == []
    assert validate.d5_haiti_problems("The bus must leave on time because of TPS.")


# --- D5 Haiti linking (F10) --------------------------------------------------------------------
def test_d5_haiti_attaches_to_only_link_is_checked(tmp_path):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    cards["trash"].pop("origin_lenses")  # only the haiti lens's attaches_to links the card
    cards["trash"]["summary"]["en"] = "Rules may change."
    errs = errors_for(tmp_path, cards=cards, lenses=lenses)
    assert_error(errs, "cards/trash.yaml.summary.en: D5: prohibited Haiti wording")
    assert_error(errs, "card trash does not list lens haiti in origin_lenses")


def test_d5_haiti_origin_lenses_only_link_is_checked(tmp_path):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    lenses[1]["attaches_to"] = []
    lenses[1]["origin_lines"] = []
    cards["trash"]["summary"]["en"] = "Rules may change."
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "cards/trash.yaml.summary.en: D5: prohibited Haiti wording")


def test_d5_status_word_card_is_not_exempt(tmp_path):
    cards = base_cards()
    lenses = _haiti_fixture(cards, card_id="status-word")
    cards["status-word"]["summary"]["es"] = "Tus próximos pasos."
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), "cards/status-word.yaml.summary.es: D5: prohibited Haiti wording")


def test_d5_unlinked_card_is_not_checked(tmp_path):
    cards = base_cards()
    cards["trash"]["summary"]["en"] = "Rules may change."
    assert not [e for e in errors_for(tmp_path, cards=cards) if "D5:" in e]


@pytest.mark.parametrize("field", ["title", "summary"])
def test_d5_haiti_lens_title_and_summary_fail(tmp_path, field):
    cards = base_cards()
    lenses = _haiti_fixture(cards)
    lenses[1][field]["ht"] = "Pwochen etap yo"
    assert_error(errors_for(tmp_path, cards=cards, lenses=lenses), f"lenses/haiti.yaml.{field}.ht: D5: prohibited Haiti wording")


@pytest.mark.parametrize(("key", "lang", "value"), [
    ("label", "en", "Next steps"), ("label", "es", "Próximos pasos"), ("labels", "ht", "Pwochen etap"),
])
def test_d5_localized_action_label_fails(key, lang, value):
    c = copy.deepcopy(base_cards()["trash"])
    c["actions"] = [{"type": "call_desk", "desk_id": "us.911", key: {"en": "Call", "es": "Llama", "ht": "Rele", lang: value}}]
    report = validate.Report()
    validate.check_haiti_copy(c, "cards/trash.yaml", report)
    assert_error(report.errors, f"cards/trash.yaml.actions[0].{key}.{lang}: D5: prohibited Haiti wording")


def test_d5_string_action_label_fails():
    c = copy.deepcopy(base_cards()["trash"])
    c["actions"] = [{"type": "call_desk", "desk_id": "us.911", "label": "Next step"}]
    report = validate.Report()
    validate.check_haiti_copy(c, "cards/trash.yaml", report)
    assert_error(report.errors, "cards/trash.yaml.actions[0].label: D5: prohibited Haiti wording")


# --- inline quote placeholders (F4) ------------------------------------------------------------
LONG_QUOTE = ("But when you ask to see the rental, the fake owner will usually claim to be out of "
              "the country or give another excuse.")


def test_inline_quote_placeholder_flags_long_quote():
    ledger = {"x.quote": {"id": "x.quote", "value": LONG_QUOTE}}
    assert validate.inline_quote_problems("Scam signs: {fact:x.quote}.", ledger)


@pytest.mark.parametrize("value", ["305-555-0100", 6.25, "6.25", "https://example.gov/page", 165,
                                   "Miami-Dade Tax Collector", "2026-07-01",
                                   "one two three four five six seven eight nine ten eleven twelve"])
def test_inline_quote_placeholder_allows_short_values(value):
    ledger = {"x.v": {"id": "x.v", "value": value}}
    assert validate.inline_quote_problems("Call {fact:x.v}.", ledger) == []


def test_inline_quote_placeholder_ignores_facts_missing_from_ledger():
    assert validate.inline_quote_problems("Call {fact:x.missing}.", {}) == []


def _ledger_dir(tmp_path, value):
    ledger = tmp_path / "facts"
    ledger.mkdir()
    (ledger / "f.json").write_text(json.dumps([{"id": "us.911.phone", "kind": "static", "value_type": "phone",
                                                "value": value}]))
    return ledger


def test_inline_quote_placeholder_fails_in_card_copy_with_ledger(tmp_path):
    content = write_tree(tmp_path)
    errs = validate.validate(content, _ledger_dir(tmp_path, LONG_QUOTE)).errors
    assert_error(errs, "cards/emergency.yaml.body.en: inline-quote-placeholder")


def test_inline_quote_placeholder_passes_phone_with_ledger(tmp_path):
    content = write_tree(tmp_path)
    errs = validate.validate(content, _ledger_dir(tmp_path, "911")).errors
    assert not [e for e in errs if "inline-quote-placeholder" in e], errs


def test_inline_quote_fact_as_source_only_passes(tmp_path):
    cards = base_cards()
    # the fact stays in paragraph_facts and fact_refs, but no longer sits inline
    cards["emergency"]["body"] = loc("Call the emergency line.", "Llama a la línea de emergencias.", "Rele liy ijans lan.")
    content = write_tree(tmp_path, cards=cards)
    errs = validate.validate(content, _ledger_dir(tmp_path, LONG_QUOTE)).errors
    assert not [e for e in errs if "inline-quote-placeholder" in e or "paragraph_facts" in e or "fact_refs" in e], errs


def test_inline_quote_placeholder_fails_in_lens_line(tmp_path):
    lens = base_lens()
    lens["origin_lines"][0]["text"] = loc("At home: {fact:us.911.phone}.")
    lens["origin_lines"][0]["fact_refs"] = ["us.911.phone"]
    lens["fact_refs"] = ["us.911.phone"]
    content = write_tree(tmp_path, lenses=[lens])
    errs = validate.validate(content, _ledger_dir(tmp_path, LONG_QUOTE)).errors
    assert_error(errs, "lenses/tourist.yaml:origin_lines[0].text.en: inline-quote-placeholder")


def test_notary_equivalence_is_rejected():
    assert validate.notary_lawyer_problem("Un notario hace lo mismo que un abogado, no pagues más")


def test_notary_negation_between_words_passes():
    assert validate.notary_lawyer_problem("A notary is not a lawyer") is None


def test_region_parent_map_allows_city_to_use_county_state_federal():
    assert validate.region_covers("us-fl-miamidade", "us-fl-miami")
    assert validate.region_covers("us-fl", "us-fl-miami")
    assert validate.region_covers("us", "us-fl-miami")
    assert not validate.region_covers("us-fl-miami", "us-fl-miamidade")


def test_facts_topic_is_driven_by_topic_tags():
    import gen_facts_requested
    assert gen_facts_requested.fact_topic(["tps"]) == "immigration"
    assert gen_facts_requested.fact_topic(["health"]) == "general"


@pytest.mark.parametrize("word", [
    "status", "estatus", "estati", "visa", "papers", "papeles", "papye", "notary",
    "citizenship", "ciudadanía", "sitwayènte", "ICE", "depòte", "deportar", "deport",
])
def test_immigration_word_list_includes_round_one_terms(word):
    assert validate.IMMIGRATION_WORDS.search(word)


def test_immigration_word_list_allows_ordinary_word():
    assert validate.IMMIGRATION_WORDS.search("library") is None


def test_generator_freshness_check_passes_and_fails(tmp_path):
    import gen_facts_requested
    target = tmp_path / "facts-requested.yaml"
    assert gen_facts_requested.main(["--output", str(target)]) == 0
    assert gen_facts_requested.main(["--check-fresh", "--output", str(target)]) == 0
    target.write_text(target.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    assert gen_facts_requested.main(["--check-fresh", "--output", str(target)]) == 1

# ---------------------------------------------------------------- the real tree
def test_real_content_validates():
    report = validate.validate(CONTENT)
    assert report.errors == [], "\n".join(report.errors)


LEDGER = CONTENT.parent / "research" / "facts"


@pytest.mark.skipif(not LEDGER.is_dir(), reason="no ../research/facts ledger")
def test_real_content_validates_with_ledger():
    report = validate.validate(CONTENT, LEDGER)
    assert report.errors == [], "\n".join(report.errors)


def test_real_content_has_cards_and_lenses():
    assert len(list((CONTENT / "cards").glob("*.yaml"))) > 0
    assert len(list((CONTENT / "lenses").glob("*.yaml"))) > 0


def test_ci_hook_is_executable():
    hook = CONTENT / "ci-hook.sh"
    assert hook.exists()
    assert os.stat(hook).st_mode & stat.S_IXUSR


# ---------------------------------------------------------------- strings catalog
def test_build_strings_emits_every_key_in_three_languages(tmp_path):
    import build_strings

    content = write_tree(tmp_path)
    catalog = build_strings.build(content)
    keys = set(catalog["strings"])
    assert "card.trash.body" in keys and "desk.us.911.name" in keys and "lens.tourist.line.emergency" in keys
    for entry in catalog["strings"].values():
        assert set(entry["localizations"]) == {"en", "es", "ht"}
        assert all(v["stringUnit"]["value"].strip() for v in entry["localizations"].values())
    assert catalog["strings"]["card.trash.title"]["localizations"]["ht"]["stringUnit"]["state"] == "needs_review"


def test_committed_catalog_is_fresh():
    import build_strings

    assert build_strings.main(["--check"]) == 0


# --- status-date hold (Firstmate) ----------------------------------------------------------

def _tps_setup(desk_id="us.accredited-legal-help"):
    """mail card rewritten as a TPS card with a gated date, plus an accredited desk."""
    facts = base_facts()
    facts["requested"].append(fact("us.accredited-legal-help.name", value_type="code", kind="lookup",
                                   question="Nearest DOJ-recognized organization?",
                                   used_by=["desk:us.accredited-legal-help"], card="mail",
                                   desk="us.accredited-legal-help"))
    facts["requested"].append(fact("us.tps.example.end-date", value_type="date", topic="immigration",
                                   used_by=["card:mail"], card="mail", desk="us.accredited-legal-help",
                                   topics=["tps", "immigration"], verified_only=True,
                                   note="reported by Discovery, unverified, primary source required (USCIS / Federal Register)"))
    facts["requested"] = [f for f in facts["requested"] if f["id"] != "us.uscis.name"]
    for f in facts["requested"]:
        if f["desk"] == "us.uscis":
            f["desk"] = "us.accredited-legal-help"
    desks = base_desks()
    desks["desks"] = [d for d in desks["desks"] if d["id"] != "us.uscis"]
    desks["desks"].append(desk("us.accredited-legal-help", loc("Accredited legal help"), level="nonprofit",
                               imm=True, fields=("name",), kind="lookup"))
    cards = base_cards()
    m = cards["mail"]
    m["desk"] = desk_id
    m["body"] = loc("Tell USCIS within {fact:us.uscis.address-change.deadline}.\n\nTPS rules can change. Check with a trusted helper.",
                    "Avisa a USCIS en {fact:us.uscis.address-change.deadline}.\n\nLas reglas de TPS pueden cambiar. Consulta con alguien de confianza.",
                    "Di USCIS nan {fact:us.uscis.address-change.deadline}.\n\nRèg TPS yo ka chanje. Tcheke ak yon moun ou fè konfyans.")
    m["verified_only_refs"] = ["us.tps.example.end-date"]
    return facts, desks, cards


def test_tps_card_with_gated_date_passes(tmp_path):
    facts, desks, cards = _tps_setup()
    assert errors_for(tmp_path, facts=facts, desks=desks, cards=cards) == []


def test_tps_card_must_end_at_accredited_desk(tmp_path):
    facts, desks, cards = _tps_setup(desk_id="us.uscis")
    assert_error(errors_for(tmp_path, facts=facts, desks=desks, cards=cards), "accredited legal-aid desk")


def test_gated_date_in_copy_fails(tmp_path):
    facts, desks, cards = _tps_setup()
    m = cards["mail"]
    m["body"] = {k: v + " {fact:us.tps.example.end-date}" for k, v in m["body"].items()}
    m["paragraph_facts"][1] = ["us.tps.example.end-date"]
    m["fact_refs"] = m["fact_refs"] + ["us.tps.example.end-date"]
    assert_error(errors_for(tmp_path, facts=facts, desks=desks, cards=cards), "held status date")


def test_verified_only_ref_must_be_marked(tmp_path):
    facts, desks, cards = _tps_setup()
    del facts["requested"][-1]["verified_only"]
    assert_error(errors_for(tmp_path, facts=facts, desks=desks, cards=cards), "not marked verified_only")


def test_verified_only_fact_needs_date_and_note(tmp_path):
    facts, desks, cards = _tps_setup()
    facts["requested"][-1]["value_type"] = "text"
    facts["requested"][-1]["note"] = "from a blog"
    errs = errors_for(tmp_path, facts=facts, desks=desks, cards=cards)
    assert_error(errs, "value_type must be date")
    assert_error(errs, "note saying it is unverified")


@pytest.mark.parametrize("en", [
    "TPS for Haiti ended in July.",
    "Your TPS papers expire on October second.",
    "Re-register by the deadline in 2026 for TPS.",
    "TPS ended this summer.",
    "Bring it on 7/27.",
    "Medicaid changes start Oct {fact:us.911.phone}.",
])
def test_status_dates_in_copy_fail(tmp_path, en):
    cards = base_cards()
    cards["stage-safe"]["summary"] = loc(en, "Resumen.", "Rezime.")
    assert errors_for(tmp_path, cards=cards), en


@pytest.mark.parametrize("es,ht", [
    ("El TPS vence en octubre.", "Rezime."),
    ("Resumen.", "TPS la ekspire nan mwa out."),
    ("Resumen.", "TPS la te fini ete sa a."),
    ("Los documentos vencen el año pasado.", "Rezime."),
])
def test_status_dates_in_es_ht_fail(tmp_path, es, ht):
    cards = base_cards()
    cards["stage-safe"]["summary"] = loc("Summary.", es, ht)
    assert errors_for(tmp_path, cards=cards), (es, ht)


def test_utterance_month_fails(tmp_path):
    cards = base_cards()
    cards["trash"]["utterances"]["es"][0] = "qué pasa en octubre"
    assert_error(errors_for(tmp_path, cards=cards), "month name")


def test_ordinary_words_are_not_months(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["summary"] = loc("You may march ahead; May I help?", "Resumen.", "Li di m sa, men se pa sa. Out of the way.")
    errs = errors_for(tmp_path, cards=cards)
    assert not [e for e in errs if "hold" in e], errs


def test_medicaid_card_routes_to_benefits_desk(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["summary"] = loc("Medicaid rules can change.", "Las reglas de Medicaid pueden cambiar.",
                                         "Règ Medicaid yo ka chanje.")
    assert_error(errors_for(tmp_path, cards=cards), "benefits desk")


# --- lens ids, bundle mirror, action wire shapes, copy rules ---------------------------------
def test_lens_id_must_be_adcore_camel_case(tmp_path):
    cards = base_cards()
    cards["emergency"]["origin_lenses"] = ["latin-america"]
    assert_error(errors_for(tmp_path, cards=cards), "not one of")


def test_lens_id_equals_origin_lens(tmp_path):
    lens = base_lens()
    lens["origin_lens"] = "haiti"
    assert_error(errors_for(tmp_path, lenses=[lens]), "must equal the lens id")


def test_lens_needs_known_desk(tmp_path):
    lens = base_lens()
    lens["desk"] = "us.nowhere"
    assert_error(errors_for(tmp_path, lenses=[lens]), "unknown desk us.nowhere")


def test_tourist_lens_never_hands_off_to_immigration_desk(tmp_path):
    lens = base_lens()
    lens["desk"] = "us.uscis"
    assert_error(errors_for(tmp_path, lenses=[lens]), "tourist lens hands off to immigration desk")


def test_lens_needs_review_matches_translation_status(tmp_path):
    lens = base_lens()
    lens["needs_review"] = {"es": False, "en": False, "ht": True}
    assert_error(errors_for(tmp_path, lenses=[lens]), "needs_review must be")


def test_redundant_immigration_key_fails(tmp_path):
    cards = base_cards()
    cards["mail"]["immigration"] = True  # person-papers already defaults to true in the bundle
    assert_error(errors_for(tmp_path, cards=cards), "drop the duplicate `immigration` key")


def test_immigration_override_required_when_default_differs(tmp_path):
    cards = base_cards()
    cards["mail"]["privacy_scope"] = "person"  # is_immigration true, bundle default false
    cards["mail"].pop("immigration", None)
    assert_error(errors_for(tmp_path, cards=cards), "set `immigration: true`")


def test_open_map_desk_uses_target_shape(tmp_path):
    cards = base_cards()
    cards["emergency"]["actions"] = [{"type": "open_map", "desk_id": "us.911"}]
    assert_error(errors_for(tmp_path, cards=cards), "does not match any allowed shape")


def test_open_map_desk_target_needs_address(tmp_path):
    cards = base_cards()
    cards["emergency"]["actions"] = [{"type": "open_map", "target": {"type": "desk", "desk_id": "us.911"}}]
    assert_error(errors_for(tmp_path, cards=cards), "to have a address fact")


def test_open_map_place_must_be_cited_place_fact(tmp_path):
    cards = base_cards()
    cards["trash"]["actions"] = [{"type": "open_map", "target": {"type": "place", "fact": {
        "pack_id": "us-fl-miamidade", "fact_id": "us-fl-miamidade.trash.garbage-days"}}}]
    errors = errors_for(tmp_path, cards=cards)
    assert_error(errors, "must have value_type place")


def test_notary_is_never_called_a_lawyer(tmp_path):
    cards = base_cards()
    cards["stage-safe"]["summary"] = loc("At home a notario is a lawyer.", "En tu país un notario es un abogado.",
                                         "Lakay yon notè se yon avoka.")
    assert_error(errors_for(tmp_path, cards=cards), "calls a notary a lawyer")


def test_negated_notary_lawyer_is_fine():
    assert validate.notary_lawyer_problem("A notario here is not a lawyer.") is None
    assert validate.notary_lawyer_problem("Un notario aquí no es abogado.") is None
    assert validate.notary_lawyer_problem("Yon notè isit la pa yon avoka.") is None


def test_copy_must_not_assert_placeholder_value(tmp_path):
    cards = base_cards()
    cards["emergency"]["summary"] = loc("It answers in Creole: {fact:us.911.languages}.",
                                        "Contesta en criollo: {fact:us.911.languages}.",
                                        "Li reponn an kreyòl: {fact:us.911.languages}.")
    assert_error(errors_for(tmp_path, cards=cards), "asserts what the placeholder should supply")


@pytest.mark.parametrize("text", ["TPS rules changed recently.", "Las reglas de TPS cambiaron hace poco.",
                                  "Règ TPS pou Ayiti chanje dènyèman.", "Medicaid ends in 2027.",
                                  "Venezuela: {fact:x.y} in 2025"])
def test_status_hold_catches_implied_dates(text):
    assert validate.status_date_problems(text)


def test_status_hold_allows_can_change():
    assert validate.status_date_problems("TPS rules can change for any country.") == []
