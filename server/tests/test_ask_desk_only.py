"""Structural desk-only classifier (review r3, B1): normalization, stemming, lexicon structure, fail-closed
resolution and the card-level second line of defence. TEST-ONLY cards and wording."""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from myad_server.ask.desk_only import Doc, Entry, Lexicon, classify, forms, tokenize
from myad_server.ask.policy import POLICY_PATH, load_policy
from myad_server.ask.ranker import StubRanker
from myad_server.ask.resolve import resolve_intent
from myad_server.cards import BundleCard
from myad_server.intent import AskRequest


def request(text: str, language: str = "en", *, mode: str = "resident", stage: int | None = None) -> AskRequest:
    body = {"utterance": {"text": text, "language": language}, "mode": mode}
    if stage is not None:
        body["stage"] = stage
    return AskRequest.model_validate(body)


def card(cid: str, *, en=(), es=(), ht=(), desk="us-fl-miamidade.test-desk", topics=("municipality",),
         immigration=False, modes=("resident", "tourist")) -> BundleCard:
    return BundleCard.model_validate({
        "id": cid, "title": {"es": "TEST-ONLY", "en": "TEST-ONLY", "ht": "TEST-ONLY"}, "desk": desk,
        "scope": "household", "stages": [1], "modes": list(modes), "region_pack": "us",
        "fact_refs": ["us.test.fee"], "topics": list(topics),
        "utterances": {"es": list(es), "en": list(en), "ht": list(ht)}, "actions": [],
        "needs_review": {"es": True, "en": True, "ht": True}, "immigration": immigration,
    })


def resolve(make_harness, text, language="en", *extra, mode="resident"):
    h = make_harness()
    cards = {**h.deps.bundle.cards, **{c.id: c for c in extra}}
    return resolve_intent(request(text, language, mode=mode), cards, h.deps.ledger, StubRanker(), h.deps.policy)


# ---- normalization and simple stemming -----------------------------------------------------------------

def test_tokenize_casefolds_accent_folds_and_strips_punctuation():
    assert tokenize("¿Cuánto COBRA el Dentista?") == ("cuanto", "cobra", "el", "dentista")
    assert tokenize("Èske y'ap ban m papye?") == ("eske", "y", "ap", "ban", "m", "papye")
    assert tokenize("djòb, lekòl; rande-vou") == ("djob", "lekol", "rande", "vou")


def test_stemming_is_one_directional():
    assert {"bus", "buse"} <= forms("buses") and "renew" in forms("renewed") and "cita" in forms("citas")
    assert forms("bus") == {"bus"} and forms("fees") >= {"fees", "fee"} and "fe" not in forms("fees")
    renewed = Lexicon.parse("t", ["renewed"])
    assert renewed.hits(Doc.of(("renewed",))) and not renewed.hits(Doc.of(("renew",)))


def test_hyphen_split_and_compound_forms_match_one_entry():
    randevou = Lexicon.parse("t", ["randevou"])
    assert randevou.hits(Doc.of(tokenize("Mwen bezwen yon rande-vou")))
    school_bus = Lexicon.parse("t", ["school bus"])
    assert school_bus.hits(Doc.of(tokenize("the schoolbus"))) and school_bus.hits(Doc.of(tokenize("school buses")))


def test_prefix_entries_need_four_letters():
    assert Entry.parse("trabaj*").prefix
    assert Lexicon.parse("t", ["trabaj*"]).hits(Doc.of(tokenize("dónde puedo trabajar")))
    with pytest.raises(ValueError):
        Entry.parse("tra*")


# ---- structure: domain + question-type cue ----------------------------------------------------------------

@pytest.mark.parametrize(("text", "kind"), [
    ("Will my TPS be renewed?", "visa_outcome"),
    ("¿Me renuevan el TPS?", "visa_outcome"),
    ("How much is the doctor?", "clinic_price"),
    ("Schedule me an interview at the office", "appointment_slot"),
    ("¿El bus de la escuela para aquí?", "school_bus_eligibility"),
    ("Is anyone hiring?", "job"),
])
def test_domain_plus_cue_is_a_hard_hit(text, kind):
    hit = load_policy().classify(text)
    assert hit is not None and hit.hard and hit.id == kind


@pytest.mark.parametrize(("text", "kind"), [
    # Misses of a fresh probe written AFTER the held-out set was tuned (28/30 before these two entries).
    ("Are they going to let me stay?", "visa_outcome"),
    ("Will the judge grant me asylo?", "visa_outcome"),
])
def test_post_tuning_fresh_probe_misses_are_now_hard_hits(text, kind):
    hit = load_policy().classify(text)
    assert hit is not None and hit.hard and hit.id == kind


@pytest.mark.parametrize(("text", "kind"), [
    ("renew my work permit", "visa_outcome"),        # immigration domain, no outcome cue
    ("clinic near my home", "clinic_price"),         # medical domain, no price cue
])
def test_domain_without_cue_is_soft(text, kind):
    hit = load_policy().classify(text)
    assert hit is not None and not hit.hard and hit.id == kind


@pytest.mark.parametrize("text", [
    "bus schedule", "which school is my child assigned to", "How much is a library card?",
    "Konbyen kat idantite a koute?", "pay my electric bill", "library book", "Kilè pou mwen pran bis la?",
])
def test_non_desk_only_questions_do_not_hit(text):
    assert load_policy().classify(text) is None


def test_work_permit_is_not_a_job_question():
    policy = load_policy()
    job = next(r for r in policy.desk_only if r.id == "job")
    assert not job.hard(tokenize("renovar mi permiso de trabajo"))
    assert job.hard(tokenize("¿Puedo trabajar con mi permiso de trabajo?"))


# ---- resolver: fail closed and the card-level backstop -----------------------------------------------------

def test_ambiguous_domain_reaches_an_on_domain_card(make_harness):
    result = resolve(make_harness, "renew my work permit")
    assert result.grounding.type == "card" and result.grounding.card_id == "test-work-permit"
    result = resolve(make_harness, "clínica cerca de mi casa", "es")
    assert result.grounding.type == "card" and result.grounding.card_id == "test-clinic"


def test_ambiguous_domain_with_a_weak_or_off_domain_card_fails_closed(make_harness):
    # "clinic" is a medical-domain word without a price cue. test-clinic ("clinic near my home") matches only
    # weakly, so the ambiguous overlap goes to the desk instead of grounding that card.
    h = make_harness()
    [top] = h.deps.index.search("clinic hours on the weekend", allowed={"test-clinic"})
    assert 0.2 <= top.q < 0.75
    result = resolve(make_harness, "clinic hours on the weekend")
    assert result.grounding.type == "desk"
    assert result.grounding.reason.key == "ask.reason.desk_only.clinic_price"
    assert result.action.destination.type == "desk"


def test_ambiguous_immigration_domain_with_no_card_still_goes_to_the_desk(make_harness):
    result = resolve(make_harness, "asilo")
    assert result.grounding.type == "desk"
    assert result.grounding.reason.key == "ask.reason.desk_only.visa_outcome"


def test_tourist_mode_ambiguous_immigration_never_names_an_immigration_desk(make_harness):
    result = resolve(make_harness, "renew my work permit", mode="tourist")
    assert result.action is None
    assert result.grounding.reason.key == "router.no_answer"
    assert result.grounding.desk_id != "us.test-desk"


def test_desk_only_card_never_grounds_even_when_the_request_is_innocent(make_harness):
    # The request has no desk-only words; only the card's own utterances are a clinic-price question.
    leaky = card("test-free-checkup", en=["free checkup tuesday"], desk="us.test-clinic-desk")
    result = resolve(make_harness, "tuesday", "en", leaky)
    assert result.grounding.type == "desk"
    assert result.grounding.desk_id == "us.test-clinic-desk"
    assert result.grounding.reason.key == "ask.reason.desk_only.clinic_price"


def test_desk_only_card_is_never_a_clarification_option(make_harness):
    leaky = card("test-trash-price-doctor", en=["how much does the doctor charge on trash day"])
    result = resolve(make_harness, "trash", "en", leaky)
    options = [o.id for o in (result.clarification.options if result.clarification else [])]
    assert "card.test-trash-price-doctor" not in options
    assert not (result.grounding and getattr(result.grounding, "card_id", None) == "test-trash-price-doctor")


def test_classifier_is_deterministic():
    policy = load_policy()
    runs = {(h.id, h.hard) if (h := classify(policy.desk_only, "¿Me aprueban la visa?")) else None for _ in range(20)}
    assert runs == {("visa_outcome", True)}


# ---- policy file validation --------------------------------------------------------------------------------

def _write(tmp_path: Path, mutate) -> Path:
    data = yaml.safe_load(POLICY_PATH.read_text(encoding="utf-8"))
    mutate(data)
    path = tmp_path / "ask_policy.yaml"
    path.write_text(yaml.safe_dump(data, allow_unicode=True), encoding="utf-8")
    return path


@pytest.mark.parametrize("mutate", [
    lambda d: d["desk_only"][0]["when"].append(["no_such_lexicon"]),
    lambda d: d["lexicons"].update({"bad": ["ab*"]}),
    lambda d: d["desk_only"].append(dict(d["desk_only"][0])),
    lambda d: d["desk_only"][0].update({"all_of": ["legacy"]}),
    lambda d: d["desk_only"][0].update({"id": "not_a_kind"}),
    lambda d: d["jurisdictions"].update({"unknown": "us-fl-miami"}),
    lambda d: d["jurisdictions"]["parents"].update({"us-fl-miami": "us-fl-nowhere"}),
])
def test_bad_policy_is_rejected_at_load(tmp_path, mutate):
    with pytest.raises(ValueError):
        load_policy(_write(tmp_path, mutate))


def test_every_rule_kind_is_a_known_desk_only_kind():
    from myad_server.verifier import DESK_ONLY_KINDS

    assert {r.id for r in load_policy().desk_only} == set(DESK_ONLY_KINDS)


def test_desk_only_handoff_never_borrows_an_unrelated_cards_desk(make_harness):
    # test-work-permit (desk us.test-desk) shares "trabajo" with the request but is not a job card.
    job = resolve(make_harness, "necesito un trabajo de permiso", "es")
    assert job.grounding.reason.key == "ask.reason.desk_only.job"
    assert job.grounding.desk_id == "us-fl-miamidade.test-desk"      # the county's generic desk
    # A card about the same desk-only question does lend its desk.
    jobs_card = card("test-job-board", en=["I need a job"], desk="us.test-jobs-desk")
    job = resolve(make_harness, "can you find me a job", "en", jobs_card)
    assert job.grounding.desk_id == "us.test-jobs-desk"
