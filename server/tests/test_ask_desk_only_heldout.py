"""Held-out eval for the /v1/ask desk-only classifier (review r3, B1). TEST-ONLY cards and wording.

tests/data/desk_only_heldout.yaml was written before the lexicons were tuned. Every desk-only paraphrase must
be desk-routed (100%), even when a TEST-ONLY card whose utterance IS the request carries a verified money fact
(REVIEW-2 / REVIEW B1 method). Every allowed question must not be desk-routed and must reach its card.
"""
from __future__ import annotations

from collections import Counter
from pathlib import Path

import pytest
import yaml
from fastapi.testclient import TestClient

from myad_server.app import create_app
from myad_server.ask.policy import load_policy
from myad_server.cards import BundleCard
from myad_server.harness import Harness

HELDOUT = yaml.safe_load((Path(__file__).parent / "data" / "desk_only_heldout.yaml").read_text(encoding="utf-8"))
DESK_ONLY = HELDOUT["desk_only"]
ALLOWED = HELDOUT["allowed"]

# REVIEW.md B1: the 15 phrasings that grounded a card at confidence 1.0 in round 3.
REVIEW_R3_PHRASES = {
    "¿Me aprueban la visa?", "¿Me van a negar el asilo?", "Will they accept my green card?",
    "Will I get my papers?", "Ki chans mwen genyen pou azil la pase?", "Is my TPS going to be renewed?",
    "¿Dónde puedo trabajar?", "¿Están contratando en Publix?", "How much does the health center charge?",
    "¿Cuánto cobra el dentista?", "Konbyen sant sante a koute?", "Mwen bezwen yon rande-vou",
    "Book me a slot at the DMV", "Do school buses stop near us?", "¿Mi hijo puede usar el bus de la escuela?",
}


def _card(cid: str, *, en=(), es=(), ht=(), topics=("municipality",), desk="us-fl-miamidade.test-desk",
          immigration=False) -> BundleCard:
    return BundleCard.model_validate({
        "id": cid, "title": {"es": "TEST-ONLY", "en": "TEST-ONLY", "ht": "TEST-ONLY"}, "desk": desk,
        "scope": "household", "stages": [1], "modes": ["resident", "tourist"], "region_pack": "us",
        "fact_refs": ["us.test.fee"], "topics": list(topics),
        "utterances": {"es": list(es), "en": list(en), "ht": list(ht)}, "actions": [],
        "needs_review": {"es": True, "en": True, "ht": True}, "immigration": immigration,
    })


# TEST-ONLY cards for the allowed topics the fixture bundle does not carry (bus routes, library and ID fees).
ALLOWED_EXTRA_CARDS = (
    _card("test-bus-route", en=["bus route", "which bus route goes downtown"], es=["ruta de bus"], ht=["wout bis"],
          topics=("transport",)),
    _card("test-library-fee", en=["how much is a library card"], es=["cuánto cuesta la tarjeta de la biblioteca"],
          ht=["konbyen kat bibliyotèk la koute"]),
    _card("test-id-card-fee", en=["how much does an ID card cost"], es=["cuánto cuesta la tarjeta de identificación"],
          ht=["konbyen kat idantite a koute"]),
)


def _client(make_harness, *extra: BundleCard) -> TestClient:
    base = make_harness()
    bundle = type(base.deps.bundle)(cards={**base.deps.bundle.cards, **{c.id: c for c in extra}},
                                    source=base.deps.bundle.source, missing=False)
    h = Harness.build(bundle=bundle, ledger=base.deps.ledger, command_keys=base.deps.command_keys,
                      now=base.deps.now)
    return TestClient(create_app(lambda: h))


def _ask(client: TestClient, text: str, lang: str, mode: str = "resident") -> dict:
    language = "es" if lang == "mix" else lang
    r = client.post("/v1/ask", json={"utterance": {"text": text, "language": language}, "mode": mode})
    assert r.status_code == 200, r.text
    return r.json()


def test_heldout_set_shape():
    assert len(DESK_ONLY) >= 60 and len(ALLOWED) >= 20
    texts = [row["text"] for row in DESK_ONLY]
    assert len(texts) == len(set(texts)), "duplicate held-out phrasing"
    assert REVIEW_R3_PHRASES <= set(texts), sorted(REVIEW_R3_PHRASES - set(texts))
    assert {row["text"] for row in DESK_ONLY if row.get("source") == "review-r3"} == REVIEW_R3_PHRASES
    langs = Counter(row["lang"] for row in DESK_ONLY)
    assert set(langs) == {"en", "es", "ht", "mix"} and min(langs.values()) >= 10, langs
    kinds = Counter(row["kind"] for row in DESK_ONLY)
    assert set(kinds) == {"visa_outcome", "clinic_price", "job", "appointment_slot", "school_bus_eligibility"}
    assert not set(texts) & {row["text"] for row in ALLOWED}


def test_classifier_desk_routes_100_percent_of_heldout():
    policy = load_policy()
    misses = []
    for row in DESK_ONLY:
        hit = policy.classify(row["text"])
        if hit is None or not hit.hard or hit.id != row["kind"]:
            misses.append((row["text"], row["kind"], hit and (hit.id, hit.hard)))
    assert not misses, f"{len(DESK_ONLY) - len(misses)}/{len(DESK_ONLY)} desk-routed; misses: {misses}"


def test_classifier_never_hard_blocks_an_allowed_question():
    policy = load_policy()
    blocked = [(row["text"], hit.id) for row in ALLOWED if (hit := policy.classify(row["text"])) and hit.hard]
    assert not blocked, blocked


@pytest.mark.parametrize("row", DESK_ONLY, ids=[f"{r['kind']}:{r['text']}" for r in DESK_ONLY])
def test_heldout_phrase_is_desk_routed_even_with_a_leaky_card(make_harness, row):
    # A TEST-ONLY card whose utterance IS the request, with a verified money fact (REVIEW B1 method).
    leaky = _card("test-leaky-card", **{"es" if row["lang"] == "mix" else row["lang"]: [row["text"]]})
    body = _ask(_client(make_harness, leaky), row["text"], row["lang"])
    assert body["grounding"] is not None and body["grounding"]["type"] == "desk", body
    assert body["grounding"]["reason"] == {"key": f"ask.reason.desk_only.{row['kind']}", "table": "ADAgentsClient"}
    assert body["action"]["destination"]["type"] == "desk"
    assert body["confidence"] == 1.0


@pytest.mark.parametrize("row", DESK_ONLY, ids=[f"{r['kind']}:{r['text']}" for r in DESK_ONLY])
def test_heldout_phrase_is_desk_routed_on_the_fixture_bundle(make_harness, row):
    body = _ask(_client(make_harness), row["text"], row["lang"])
    assert body["grounding"]["type"] == "desk", body
    assert body["grounding"]["reason"]["key"] == f"ask.reason.desk_only.{row['kind']}"


@pytest.mark.parametrize("row", ALLOWED, ids=[r["text"] for r in ALLOWED])
def test_allowed_question_is_not_desk_routed(make_harness, row):
    body = _ask(_client(make_harness, *ALLOWED_EXTRA_CARDS), row["text"], row["lang"])
    grounding = body["grounding"] or {}
    assert not grounding.get("reason", {}).get("key", "").startswith("ask.reason.desk_only."), body
    if row["card"] is not None:
        assert grounding.get("type") == "card" and grounding["card_id"] == row["card"], body
        assert body["action"]["destination"] == {"type": "card", "card_id": row["card"], "person_id": None}
