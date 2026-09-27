"""POST /v1/fee-check (offline; TEST-ONLY ledger and manifests under fixtures/demo)."""
from __future__ import annotations

import json

import pytest

from demo_support import FakeGenaiClient, demo_catalog, demo_ledger, go_live, make_client

REGION = "us-fl-miamidade"
LICENSE = "us-fl.flhsmv.fee.class-e-original"
ADDON = "us-fl.flhsmv.fee.tax-collector-service-fee"


@pytest.fixture
def client(make_harness):
    return make_client(make_harness)


def post(client, text, language="en", **extra):
    r = client.post("/v1/fee-check", json={"region": REGION, "language": language, "text": text, **extra})
    assert r.status_code == 200, r.text
    return r.json()


def test_catalog_reads_only_fee_check_adapters_and_parents():
    cat = demo_catalog()
    assert cat.chain(REGION) == ("us", "us-fl", REGION)
    assert cat.chain("us-tx") == ("us", "us-tx")  # unknown pack: dash prefixes, no invented parent
    assert {g.key for g in cat.groups} == {"fees.uscis", "scams.gift-card", "fees.license", "rent.deposit",
                                           "fees.mia-taxi"}


def test_spanish_matched_government_fee_is_the_ledger_sentence(client):
    body = post(client, "El señor de la gestoría me cobra 300 dólares por sacar la licencia", "es")
    assert body["outcome"] == "official_fee" and body["extractor"] == "rule"
    assert body["ask"] == {"payee_type": "private", "purpose_key": LICENSE, "amount_cents": 30000,
                           "method": "unknown"}
    [line] = body["lines"]
    assert line["text"] == ("La tarifa oficial publicada por TEST-ONLY State Publisher es $11.11, "
                            "más un posible cargo de servicio de $2.22.")
    assert line["fact_ids"] == [LICENSE, ADDON] and line["source_id"] == "us-fl.test-only-source"
    assert body["facts"][LICENSE]["type"] == "fact" and body["facts"][ADDON]["type"] == "fact"
    assert body["desk_id"] == "us-fl.test-licensing-desk"
    desks = {h["desk_id"]: [c["fact_id"] for c in h["contact"]] for h in body["handoffs"]}
    assert desks["us-fl.test-licensing-desk"] == ["us-fl.test-licensing-desk.name", "us-fl.test-licensing-desk.phone"]
    assert "us-fl-miamidade.test-tax-desk" in desks  # the office that charges the add-on
    assert "300" not in json.dumps(body["lines"])  # the asked amount is never in the answer


def test_english_cash_license(client):
    body = post(client, "they want $150 cash to do my license")
    assert body["ask"]["method"] == "cash" and body["ask"]["amount_cents"] == 15000
    assert body["lines"][0]["text"].startswith("The official fee published by TEST-ONLY State Publisher is $11.11")


def test_creole_renewal(client):
    body = post(client, "Yo mande m 200 dola pou renouvle lisans mwen", "ht")
    assert body["ask"]["purpose_key"] == "us-fl.flhsmv.fee.class-e-renewal"
    assert body["lines"][0]["text"].startswith("Frè ofisyèl TEST-ONLY State Publisher pibliye a se $12.12")


def test_ocr_text_alone_is_accepted(client):
    r = client.post("/v1/fee-check", json={"region": REGION, "language": "en",
                                           "ocr_text": "RECEIPT  Driver License service  $95.00  CASH"})
    assert r.status_code == 200
    assert r.json()["ask"]["amount_cents"] == 9500 and r.json()["outcome"] == "official_fee"


def test_private_price_gets_no_verdict_only_the_desk(client):
    body = post(client, "My mechanic wants $400 to fix the car")
    assert body["outcome"] == "private_no_verdict"
    [line] = body["lines"]
    assert line["text"] == "I don't have a price for private services; ask TEST-ONLY County 311."
    assert line["fact_ids"] == ["us-fl-miamidade.311.name"]
    assert body["desk_id"] == "us-fl-miamidade.311"
    assert "$" not in line["text"] and "400" not in json.dumps(body["lines"])


def test_private_group_deposit_goes_to_its_regions_desk(client):
    body = post(client, "El casero quiere $2000 de depósito por Zelle", "es")
    assert body["outcome"] == "private_no_verdict" and body["desk_id"] == "us-fl.test-housing-desk"
    assert body["lines"][0]["text"].startswith("No tengo un precio para servicios privados")


def test_immigration_gets_only_uscis_lines_and_accredited_desk(client):
    body = post(client, "Me piden $500 por el formulario de USCIS, por Western Union", "es")
    assert body["outcome"] == "immigration_lines" and body["ask"]["purpose_key"] == "fees.uscis"
    assert [line["fact_ids"] for line in body["lines"]] == [["us.uscis.forms-free"], ["us.uscis.fee-payment-methods"]]
    assert body["lines"][0]["text"] == "TEST-ONLY Federal Publisher dice (en inglés): “TEST-ONLY forms line.”"
    assert body["desk_id"] == "us.accredited-legal-help"
    [handoff] = body["handoffs"]
    assert [c["fact_id"] for c in handoff["contact"]] == ["us.accredited-legal-help.name", "us.accredited-legal-help.phone"]
    assert "500" not in json.dumps(body["lines"])


def test_immigration_without_uscis_lines_is_desk_only(make_harness):
    from myad_server.ledger import Ledger

    full = demo_ledger()
    ledger = Ledger(facts={k: v for k, v in full.facts.items() if not k.startswith("us.uscis.")}, sources=full.sources)
    body = post(make_client(make_harness, ledger=ledger), "How much is the USCIS fee for form I-130?")
    assert body["outcome"] == "no_official_fee" and body["desk_id"] == "us.accredited-legal-help"
    [line] = body["lines"]
    assert line["text"] == "I don't have the official fee for that; ask TEST-ONLY Accredited Help Desk."
    assert line["fact_ids"] == ["us.accredited-legal-help.name"] and line["source_id"] is None


def test_tourist_never_sees_immigration_content(client):
    body = post(client, "They want $500 for my visa form", mode="tourist")
    assert body["outcome"] == "not_shown_tourist" and body["mode"] == "tourist"
    assert body["desk_id"] == "us-fl-miamidade.311" and body["dropped_claims"] >= 2
    text = json.dumps(body)
    assert "uscis." not in text and "accredited" not in text


def test_tourist_still_gets_taxi_meter_rule(client):
    body = post(client, "the taxi from the airport is $80", mode="tourist")
    assert body["outcome"] == "official_rule"
    assert body["lines"][0]["fact_ids"] == ["us-fl-miamidade.mia.taxi.meter-rule"]


def test_declared_fee_missing_from_ledger_answers_with_desk(client):
    body = post(client, "They charge $60 for a state ID card")
    assert body["ask"]["purpose_key"] == "us-fl.flhsmv.fee.id-card-original"
    assert body["outcome"] == "no_official_fee" and body["desk_id"] == "us-fl.test-licensing-desk"
    assert body["lines"][0]["text"] == "I don't have the official fee for that; ask TEST-ONLY State Licensing Desk."


def test_no_fee_facts_at_all_still_answers_with_a_desk_line(make_harness):
    from myad_server.demo.fee_catalog import FeeCatalog
    from myad_server.ledger import Ledger

    body = post(make_client(make_harness, ledger=Ledger(), catalog=FeeCatalog()), "they want $150 for my license")
    assert body["outcome"] == "no_official_fee" and body["facts"] == {}
    [line] = body["lines"]
    assert line["text"] == "I don't have the official fee for that; ask a local help desk." and line["fact_ids"] == []


class HallucinatingExtractor:
    """A fake Gemini extractor: amount and purpose that the person never said."""

    name = "gemini"

    def __init__(self, purpose=LICENSE, amount=99_900):
        self.purpose, self.amount = purpose, amount

    async def extract(self, text, purposes):
        from myad_server.demo_models import FeeAsk

        return FeeAsk(payee_type="government", purpose_key=self.purpose, amount_cents=self.amount, method="cash")


def test_hallucinated_amount_never_appears(make_harness):
    client = make_client(make_harness, extractor_factory=HallucinatingExtractor)
    body = post(client, "they want $150 to do my license")
    assert body["extractor"] == "gemini" and body["ask"]["amount_cents"] is None
    assert body["dropped_claims"] >= 1
    assert "999" not in json.dumps(body)
    assert body["lines"][0]["text"].startswith("The official fee published by TEST-ONLY State Publisher is $11.11")


def test_hallucinated_purpose_outside_the_enum_is_unknown(make_harness):
    client = make_client(make_harness, extractor_factory=lambda: HallucinatingExtractor(purpose="us.made-up.fee"))
    body = post(client, "they want $150 for something")
    assert body["ask"]["purpose_key"] == "unknown" and body["outcome"] == "no_official_fee"


def test_gemini_extractor_via_fake_client(make_harness, monkeypatch):
    fake = FakeGenaiClient(output={"payee_type": "private", "purpose_key": LICENSE, "amount_cents": 4_800_000,
                                   "method": "cash"})
    go_live(monkeypatch, fake)
    body = post(make_client(make_harness), "El gestor me pide 300 dólares en efectivo por la licencia", "es")
    assert body["extractor"] == "gemini"
    assert body["ask"]["amount_cents"] is None  # 48,000.00 was never said
    assert "48000" not in json.dumps(body) and body["lines"][0]["fact_ids"][0] == LICENSE
    [call] = fake.interactions.calls
    assert call["model"] == "gemini-3.8-flash"
    fmt = call["response_format"]
    assert fmt["type"] == "text" and fmt["mime_type"] == "application/json"
    enum = fmt["schema"]["properties"]["purpose_key"]["enum"]
    assert LICENSE in enum and "private_service" in enum and "unknown" in enum


def test_gemini_failure_degrades_to_rules(make_harness, monkeypatch):
    go_live(monkeypatch, FakeGenaiClient(exc=RuntimeError("TEST-ONLY outage")))
    body = post(make_client(make_harness), "they want $150 cash to do my license")
    assert body["extractor"] == "rule" and body["outcome"] == "official_fee"


def test_offline_never_builds_a_client_even_with_a_key(make_harness, monkeypatch):
    from myad_server.demo import genai as G

    monkeypatch.setenv("GEMINI_API_KEY", "TEST-ONLY-NOT-A-KEY")
    monkeypatch.setenv("MYAD_OFFLINE", "1")
    monkeypatch.setattr(G, "build_client", lambda *a: pytest.fail("offline built a client"))
    assert post(make_client(make_harness), "they want $150 for my license")["extractor"] == "rule"


def test_validation_error_never_echoes_input(client):
    secret = "ZEBRA-QUARTZ-TEST-ONLY " * 200
    r = client.post("/v1/fee-check", json={"region": REGION, "language": "en", "text": secret})
    assert r.status_code == 422 and r.json()["error"] == "invalid_request"
    assert "ZEBRA" not in r.text
    r = client.post("/v1/fee-check", json={"region": REGION, "language": "en"})
    assert r.status_code == 422


def test_green_card_is_not_a_card_payment():
    from myad_server.demo.fee_extract import RuleFeeExtractor

    rules = RuleFeeExtractor()
    assert rules.extract_sync("the notario wants $500 for my green card form", []).method == "unknown"
    assert rules.extract_sync("quiere 500 por la tarjeta verde", []).method == "unknown"
    assert rules.extract_sync("pay by credit card, $20", []).method == "card"
