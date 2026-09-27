# Demo endpoints (FM-MYAD-DEMO-DESK, server part)

These are four demo routes on the myAD agent server. Contracts (request and response JSON examples) live in
`contracts/v1/demo/` (`fee_check.*`, `handoff_sheet.*`, `desk_translate.*`, `live_token.*`, `demo_error.*`; kept out of the top-level `contracts/v1/` set that ADAgentsClient pins until the phone adopts them),
and the models are in `src/myad_server/demo_models.py`, re-exported from `models.py`. The code is in `src/myad_server/demo/`.

Ground rules the code enforces:

- **No invented facts.** Every fee, desk name and phone number comes from ledger facts that the Regions packs
  already serve (`server/regionpacks/*/manifest.json` `*.fee-check-*` adapters → `research/facts/*.json`).
  Answers go through `verifier.verify` and tourist `visibility`. Code and prompts hold no prices, desks or phones.
  `data/fee_purposes.yaml` holds only purpose keywords and sentence templates with `{source}`/`{amount}`/`{desk}` slots.
- **Key.** The key comes only from `os.environ["GEMINI_API_KEY"]`. It's read per request, passed explicitly to google-genai,
  and never logged or returned.
- **`MYAD_OFFLINE=1`** short-circuits before any client is built, so it never touches the network.
- **Logs** are the existing access log only: `request_id`, route, status, latency and integer counts
  (`request.state.counts`). No user text, OCR text, utterances, audio, transcripts or tokens are logged
  (`tests/test_demo_logs.py`). Validation errors return `{error, request_id}` and never echo the input.
- **Nothing is stored.** Handoff sheets and audio exist only for the length of the request.

## Offline now vs waits on `GEMINI_API_KEY`

| Route | Offline / keyless (today, CI) | With `GEMINI_API_KEY` (and google-genai installed) |
|---|---|---|
| `POST /v1/fee-check` | **200.** `RuleFeeExtractor` uses amount regexes and en/es/ht purpose keyword tables, then the deterministic ledger matcher. `extractor: "rule"`. | One `gemini-3.8-flash` structured-output call (`GeminiFeeExtractor`) returning `{payee_type, purpose_key (enum of the region's ledger fee purposes), amount_cents, method}`. The result is sanitised: an amount that isn't literally in the person's text is dropped, and an off-enum purpose becomes unknown. On error or timeout it falls back to the rules. **The matcher and answer are identical either way.** The model never produces answer text. |
| `POST /v1/handoff-sheet` | **200.** `ExtractiveHandoffSummarizer` keeps English utterances verbatim and marks non-English ones `needs_translation: true` (it never translates). `summarizer: "extractive"`. | One structured call (`GeminiHandoffSummarizer`). Each English sentence cites a `source_utterance_index` and gives a read-back in the person's language. It falls back to extractive on error. |
| `POST /v1/desk/translate` | **503 `fallback_unavailable`.** The phone shows the labelled cached replay. | One `gemini-3.8-flash` structured call → `{transcript, translation, mode: "fallback"}`. The audio is capped (16 kHz mono PCM16 or WAV, 15.5 s, 413 `audio_too_large`; 422 `audio_format` on a bad WAV). |
| `POST /v1/live/token` | **503 `live_unavailable`.** | Mints an ephemeral Live token (v1alpha, `uses: 1`, expires in 10 min, new session within 60 s). The constraints lock `gemini-3.1-flash-live-preview`, AUDIO output, automatic activity detection **disabled** (push-to-talk) and input/output transcription **on**. The key never leaves the server. |

The handoff verifier runs in both modes. It drops a sentence when:

- its cited index is invalid (`bad_index`);
- it doesn't map to its cited utterance (`unsupported`: content-token overlap, or for a live translation the read-back must overlap the utterance);
- it uses a legal or status word the person didn't say themselves (`unsaid_legal_word`, en/es/ht list in `data/handoff_words.yaml`);
- it uses a status word the person said but didn't tick (`unticked_status_word`).

`approved` is always `false`. The person approves the sheet on the phone.

### Fee-check outcomes (real ledger, offline)

| Outcome | When | Sentence built from |
|---|---|---|
| `official_fee` | The purpose matches a ledger money fact, e.g. `us-fl.flhsmv.fee.class-e-original`. | That fact's own `value`, plus `source_name`. An add-on fact (`tax-collector-service-fee`) is appended if the ledger has it. `fact_ids`, source, url and desk are included. |
| `official_rule` | The purpose matches a non-money fee rule (for example MIA taxi rules or the FTC gift-card scam fact). | The fact's own quote. |
| `immigration_lines` | Immigration purpose. | Only the USCIS fee lines present in the ledger (`us.uscis.forms-free`, `us.uscis.fee-payment-methods`), plus a handoff to `us.accredited-legal-help`. If those lines are absent, the answer is desk-only. |
| `private_no_verdict` | Private price (e.g. rent deposit). | "I don't have a price for private services" plus the desk. There is **no verdict** on the quoted amount. |
| `no_official_fee` | There is no ledger fee fact for the purpose or region. | A desk answer only. |
| `not_shown_tourist` | `mode: "tourist"` and the content is resident- or immigration-only. | "Can't help in visitor mode", plus the region's 311 desk. |

The quoted amount is echoed back only in `ask.amount_cents`, as a record of what the person said. It is never compared or judged, and
it is never put into answer text. Here is a smoke run against the real ledger with `MYAD_OFFLINE=1`:

- es "me cobran 150 dólares en efectivo para la licencia" → *"La tarifa oficial publicada por Florida Department of
  Highway Safety and Motor Vehicles (FLHSMV) es $48.00, más un posible cargo de servicio de $6.25."* It cites fact_ids
  `us-fl.flhsmv.fee.class-e-original` and `us-fl.flhsmv.fee.tax-collector-service-fee`, with handoffs to FLHSMV and the Tax Collector.

The en/es/ht copy templates are a first pass. Haitian Creole in particular still needs Language review.

## Environment

| Var | Meaning |
|---|---|
| `GEMINI_API_KEY` | The only key source. Unset means every live path degrades as described above. |
| `MYAD_OFFLINE=1` | Forces the stub or offline path. No client is built and there is no network. `ci-hook.sh` runs keyless. |
| `MYAD_FALLBACK_MODEL` | Overrides `gemini-3.8-flash` (the structured calls). |
| `MYAD_LIVE_MODEL` | Overrides `gemini-3.1-flash-live-preview` (the token constraint). |

google-genai is **not** in `requirements.lock`, so CI never needs it. Install it for live paths with the `live` extra
(google-adk depends on google-genai). The code was written against google-genai 2.25.0, the version used in `spikes/live/`
(`client.interactions.create`, `client.auth_tokens.create`). If the SDK is missing, the server behaves as if keyless.

Docs checked on 2026-09-25 and cited in code comments:

- https://ai.google.dev/gemini-api/docs/models
- https://ai.google.dev/gemini-api/docs/structured-output
- https://ai.google.dev/gemini-api/docs/audio
- https://ai.google.dev/gemini-api/docs/ephemeral-tokens

## curl

```bash
# Start the server locally (offline):
cd server && MYAD_OFFLINE=1 MYAD_ROOT="$(cd .. && pwd)" PYTHONPATH=src .venv/bin/uvicorn myad_server.app:app --port 8080

# 1. Fee check (200 offline)
curl -s localhost:8080/v1/fee-check -H 'content-type: application/json' \
  -d '{"region":"us-fl-miamidade","language":"es","text":"me cobran 150 dólares en efectivo para la licencia"}'
curl -s localhost:8080/v1/fee-check -H 'content-type: application/json' \
  -d '{"region":"us-fl-miamidade","language":"en","ocr_text":"RECEIPT  Driver license service  $150.00  CASH"}'
curl -s localhost:8080/v1/fee-check -H 'content-type: application/json' \
  -d '{"region":"us-fl-miamidade","language":"en","mode":"tourist","text":"the notario wants $500 for my green card form"}'

# 2. Handoff sheet (200 offline, extractive)
curl -s localhost:8080/v1/handoff-sheet -H 'content-type: application/json' \
  -d '{"person_id":"p1","language":"en","utterances":["My landlord changed the locks yesterday.","I have my lease."],"ticked_status_words":[],"desk_id":"us-fl-miamidade.311"}'

# 3. Desk translate (503 fallback_unavailable offline; 200 with key)
curl -s -i localhost:8080/v1/desk/translate -H 'content-type: application/json' \
  -d '{"text":"Proof of address?","source_language":"en","target_language":"es"}'
# audio: 16 kHz mono PCM16 or WAV, <= ~15 s
curl -s -i localhost:8080/v1/desk/translate -H 'content-type: application/json' \
  -d "{\"audio_b64\":\"$(base64 -w0 clip.wav)\",\"source_language\":\"es\",\"target_language\":\"en\"}"

# 4. Live token (503 live_unavailable offline)
curl -s -i localhost:8080/v1/live/token -H 'content-type: application/json' \
  -d '{"source_language":"en","target_language":"es"}'
```

## Tests (offline, no network)

- `tests/test_fee_check.py`: en/es/ht, a matched government fee plus the add-on, a private price with no verdict, immigration going to
  USCIS lines or desk-only, a tourist, no ledger fee fact, a fake Gemini extractor hallucinating an amount that must not appear, an
  off-enum purpose, and green card not being read as a card payment.
- `tests/test_handoff_sheet.py`: unsupported, unsaid legal word, unticked status word and bad index are dropped; es/ht legal
  words; extractive `needs_translation`; the live happy path with a fake client; no persistence.
- `tests/test_desk_live.py`: translate and token return 503 offline and keyless (and never build a client), happy paths with a
  monkeypatched fake client, token constraints, and audio caps and format.
- `tests/test_demo_logs.py`: log capture proving no user text, audio or token reaches the logs.
- Fixture ledger and packs are in `tests/fixtures/demo/`. They are clearly marked **TEST-ONLY** ($11.11 / $12.12 / $2.22,
  555-01xx phones) and are never used by the running server.
