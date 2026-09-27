# research/ — freshness + region onboarding: design

Task FM-MYAD-RES. Owner of this file and of `research/freshness/`, `research/onboarding/`,
`research/tests/`. The ledger itself (`sources.yaml`, `facts/*.json`, `schema/*.json`,
`tools/validate.py`, `README.md`) belongs to the ledger worker; this code only reads it,
except for one narrow write (freshness may flip `status` to `stale`, see A.6).

Method: pstack architect. Usage first, then types, then two structurally different candidate
shapes, a synthesis decision, then implementation against the sketch. There is no multi-model
arena on this box, so the two candidates were written by one author and screened against the
red flags (shallow modules, information leakage, temporal decomposition, pass-through methods).

No version control: the captain said no git and no GitHub. Everything here is plain files.
The eventual public home is `saksham-45/shellhacks-2026`; nothing here touches any repo.

Secrets and caches:
* No keys or tokens in the tree. Optional keys come only from the environment:
  `CENSUS_API_KEY` (ACS API; without it the ACS table-based summary files on www2 are used),
  `HUD_API_TOKEN` (HUD income limits / FMR; without it the gap is reported). Code works without them.
* Freshness state and caches of fetched pages live in `research/freshness/.cache/`
  (`state.json`, `pages/`). That directory must be ignored by any packaging/VCS (`.cache/` in the
  ignore list) and nothing large is committed. Proposals (small JSON) live in
  `research/freshness/proposals/` and are meant to be reviewed.
* Onboarding runs keep raw responses in `<out>/.cache/` (ignored); only the small outputs are kept.
* Test fixtures are trimmed (tens of KB, not MB).

## 0. Ground truth this design is built on (observed 2026-09-25 from the box)

* Ledger contract (project skeleton `/workspace/myamericandream`, which wins over the early staging schema):
  `research/facts/*.json` are JSON **arrays** of facts; `check_every` is an ISO 8601 duration (`P7D`, `P30D`, `P1Y`);
  `research/sources.yaml` is `{sources: [...]}` with `id, publisher, title, url, kind (api|gis-layer|gtfs|pdf|html|dataset),
  jurisdiction, key_required, check_every, notes` plus optional `official`, `extraction`. A fact may carry
  `kind: static|lookup` (default static), `desk`, and `value_type` (final list: text, code, codes, phone, date,
  money, quantity, weekdays, place, flag). A lookup fact has `value: null`, a `desk`, and
  `lookup = {endpoint, layer_id, fields[], method, question, params?}`. Extra keys are `x-` prefixed.
  Readers here also accept the older `{"domain", "facts": [...]}` wrapper and `7d`-style intervals, so nothing breaks
  while formats settle. Source `kind` maps to a check method: html -> html-quote, pdf -> pdf-quote, gis-layer ->
  arcgis-query, api/dataset -> api-json, gtfs -> download check; an explicit `extraction` wins.
* Network from this box: `geocoding.geo.census.gov` and `tigerweb.geo.census.gov` answer
  "Request Rejected" (a WAF page, HTTP 200). `api.census.gov` now redirects to `missing_key.html`
  without a key. `www2.census.gov` (reference code files, ACS table-based summary files) answers.
  FCC Area API (`geo.fcc.gov/api/census/area`) answers. ArcGIS World geocoder answers.
  CISA `.gov` registry CSV answers. Mobility Database `feeds_v2.csv` answers. Miami-Dade
  `gisweb.miamidade.gov/arcgis/rest/services` answers.
  Consequence: every resolver is a chain of providers, the official one first, and every result
  records which provider answered and whether it is official.

## 1. Usage (written first)

```bash
# from the project root (the directory that contains research/)
python -m research.freshness check                    # check every source
python -m research.freshness check --due-only         # only sources whose check_every elapsed
python -m research.freshness check --source gmx-toll-pdf --report /tmp/r.md
python -m research.freshness check --due-only --no-write-ledger   # never touch facts/*.json
python -m research.freshness status                   # print state.json summary, no network

python -m research.onboarding propose --place "Miami-Dade County, FL" --city "Miami" \
    --out research/onboarding/runs/us-fl-miamidade
python -m research.onboarding propose --place "Travis County, TX"          # any US county
python -m research.onboarding propose --place "Miami, FL"                  # a place: county is derived
python -m research.onboarding reemit --run research/onboarding/runs/us-fl-miamidade   # rebuild outputs, no network
python -m research.onboarding compare --run research/onboarding/runs/us-fl-miamidade \
    --plan /home/box/agent-data/grok-ship/myad/plans/mymiami-public-data.md

python -m pytest research/tests -m 'not live'         # unit tests, no network (this is what tools/ci.sh runs)
python -m pytest research/tests -m live --run-live    # live tests, hit the real endpoints
```

Scheduled wake (documented only; this task creates no scheduled job):

```bash
cd <project root> && python -m research.freshness check --due-only \
  --report /home/box/agent-data/grok-ship/reports/FM-MYAD-RES-freshness-$(date +%F).md
# exit code (bit flags): 0 clean; 1 drift (value changed / quote missing / schema drift); 2 a source was
# unreachable this run (transient); 4 moved (redirect); 8 a fact hit the consecutive-unreachable threshold
# (default 3, --unreachable-threshold) and a stale proposal was written; 64 usage/config; 70 internal.
# A wake should open a review task when (code & 9); (code & 2) alone just means "try again next run".
```

Weekly report = the same command without `--due-only` once a week.

## 2. A) Freshness

### 2.1 Module map (`research/freshness/`)

| module | owns | public surface |
| --- | --- | --- |
| `ledger.py` | reading sources.yaml + facts, the one status write | `Ledger.load(root)`, `Ledger.mark_stale(fact_ids, note)` |
| `schedule.py` | `check_every` parsing, due decision | `parse_interval(s)`, `is_due(source, state, now)` |
| `state.py` | `.cache/state.json` (per-source last check, hashes, final URL, per-fact last outcome, pin cache) | `State.load(path)`, `.save()`, `.record_source(...)` |
| `net.py` | the only HTTP client for all of research/: polite UA, timeouts, retries with backoff, per-host spacing, redirect history, WAF-page detection, record/replay for tests | `Fetcher(...).get(url, params) -> Fetched` |
| `text.py` | html/pdf to text, normalization, quote search, best-snippet | `to_text(fetched, kind)`, `normalize(s)`, `find_quote(text, quote) -> Match` |
| `values.py` | comparing recorded vs observed values (numbers, money, strings), JSON path picking | `values_equal(a, b)`, `pick(obj, path)`, `find_value(obj, v)` |
| `pins.py` | demo pin geocoding via provider chain (Census first, then ArcGIS World, marked secondary), cached in state | `resolve_pin(pin, fetcher, state) -> Pin` |
| `checks.py` | one checker per extraction method + lookup checker; classification | `check_source(source, facts, ctx) -> SourceResult` |
| `report.py` | Markdown + JSON summary, proposals files | `write_report(run, md_path, json_path)`, `write_proposals(run, dir)` |
| `cli.py` / `__main__.py` | argparse, exit codes | `main(argv) -> int` |

### 2.2 Types

```python
Outcome = Literal["unchanged", "value-changed", "quote-missing", "schema-drift", "source-unreachable", "moved", "skipped"]
# value-changed = content drifted; quote-missing = quote no longer found; both plus schema-drift are "drift".
# source-unreachable = transient (retried next run, status unchanged); counted per fact in state.

@dataclass class Fetched:  url, final_url, status: int|None, redirects: list[str], headers, content: bytes,
                           content_type, error: str|None, elapsed_ms, retrieved_at
    ok -> bool; moved -> bool (final_url differs from url beyond trailing slash / http->https)

@dataclass class FactResult: fact_id, source_id, kind, outcome: Outcome, detail: str,
                             snippet: str|None, similarity: float|None, observed: Any
@dataclass class SourceResult: source_id, url, final_url, http_status, outcome_summary,
                               content_sha256, content_changed: bool|None, facts: list[FactResult], error
@dataclass class Run: started_at, finished_at, args, results: list[SourceResult], pin: Pin|None
    exit_code() -> int   # bit flags, see usage
```

### 2.3 Algorithm

1. Load ledger. Group facts by `source_id`. Facts with status `unsourced` or `demo` are listed as
   `skipped` (nothing to re-find). Facts whose source is missing from sources.yaml are reported as
   config errors in the report, not crashes.
2. Pick sources: `--source ID` (forced, repeatable) else all, else with `--due-only` only those where
   `now - state.last_checked >= parse_interval(check_every)` or never checked. The fact-level
   `check_every` can be shorter than the source's; the source is due if any of its facts is due.
3. Fetch the source URL once (the `Fetcher` retries 3x on timeout/5xx/connect errors with
   exponential backoff, 20 s timeout, spacing >= 1 s per host). A WAF "Request Rejected" page is
   treated as unreachable, not as content. Store `sha256(raw)` and `sha256(normalized text)`;
   `content_changed` compares the normalized hash with the previous run.
4. Per fact, by the source's `extraction` (a fact's own `query`/`lookup` wins over the source):
   * `html-quote` / `pdf-quote`: text = BeautifulSoup text (scripts/styles dropped) or `pdftotext -layout`
     (fallback: pdfminer.six if installed). Normalize both sides (NFKC, curly quotes to straight, dashes,
     nbsp, collapse whitespace). Exact normalized substring => unchanged. Else case/punctuation-folded
     match => unchanged with detail "matched after case/punctuation folding". Else drift, with the best
     matching window (difflib ratio over sliding token windows) as `snippet` and its similarity.
     When the fact URL differs from the source URL (e.g. a deep link), the fact URL is fetched instead.
   * `arcgis-query` / `api-json` (static): re-run `fact.query.url` (+ `params`) or the fact URL; if the fact
     has `query.field` / `query.json_path` pick that value, else search all leaves for the recorded value.
     Equal (numeric tolerance 1e-9, money/commas stripped, case/whitespace-folded strings) => unchanged,
     else drift with the observed value.
   * `kind: lookup` (any extraction): GET layer metadata `endpoint[/layer_id]?f=json`; the layer must exist
     and every `lookup.fields` name must be present (case-insensitive) => else `schema-drift` listing missing
     fields / new layer name. Then run a sample query at the demo pin (`pins.yaml`, default
     11200 SW 137th Ave, Miami FL 33186): point, `esriSpatialRelIntersects`, `outFields=fields`, plus
     `lookup.params` (e.g. buffer distance). An ArcGIS `error` object or non-JSON => `schema-drift`.
     Zero features is not drift (the county garbage layer legitimately returns nothing in the City of
     Miami); it is recorded in the detail. The layer name seen is stored in state; a later rename is drift.
   * `manual`: skipped, listed for a human.
   * precedence per fact: source-unreachable > drift/schema-drift > moved > unchanged.
5. Write `.cache/state.json` after every source (an interrupted run keeps what it did).
6. Unreachable is transient: the fact's status is left alone, `consecutive_unreachable` is counted in state, and only
   when it reaches the threshold (default 3) a proposal "mark stale" is written (still no automatic flip). This mirrors
   the app, which has a separate `unavailable(desk)` outcome for a source that exists but can't be reached; that is
   not the same as unsourced, so one failed fetch must never look like a missing source. The report keeps three
   buckets apart: "source unreachable this run" (transient, retried next run), "content drifted" (value-changed /
   schema-drift) and "quote no longer found" (quote-missing). A successful fetch resets the counter to 0.
   For html/pdf quotes, "value-changed" means the best-matching passage (similarity >= 0.75) still exists but its figures
   differ; otherwise "quote-missing". For api/arcgis values, `value_type` drives comparison (weekdays as a day set in
   en/es, phone by digits, codes as a set, flag as boolean, date parsed, money/quantity numeric).
7. Drift (value-changed, quote-missing, schema-drift): never rewrite `value`, `quote`, or `url`. With `--write-ledger` (default) the
   fact's `status` flips `verified -> stale` in its facts file (JSON reloaded just before the write,
   only that key changed, 2-space indent kept). A proposal file
   `research/freshness/proposals/<date>/<fact_id>.json` holds recorded vs observed, snippet, similarity,
   source hash, and "action: human/agent review". `moved` writes a proposal to update the URL.
   `--no-write-ledger` writes proposals/state/report only.
8. Report: Markdown (default `/home/box/agent-data/grok-ship/reports/FM-MYAD-RES-freshness-<date>.md`)
   and JSON (same path, `.json`). Counts by outcome, per source table, drift details with snippets,
   unreachable list, moved list, skipped list, pin provider used.

### 2.4 Candidates considered

* **A. Checker-per-method registry over a thin orchestration loop (chosen).** One `check_source`
  entry point hides fetching, text extraction, matching and classification; checkers are plain
  functions keyed by method. Adding a method = one function. Callers never see fetch details.
* **B. Pipeline stages (fetch-all -> extract-all -> compare-all -> classify-all).** Rejected: temporal
  decomposition, leaks intermediate formats between stages, loses state on interruption, and holds
  every PDF in memory at once.
* Also rejected: a class hierarchy of `Source` subclasses per method (fat constructors, shallow
  subclasses, the method lives in data so a hierarchy adds nothing).

## 3. B) Region onboarding

### 3.1 Module map (`research/onboarding/`)

| module | owns | public surface |
| --- | --- | --- |
| `model.py` | types below | dataclasses |
| `resolve.py` | place string / address -> `JurisdictionChain` using Census reference files on www2 (state, county, place-to-county), FCC Area API for points, geocoder chain for addresses | `resolve(place, city, fetcher) -> JurisdictionChain` |
| `discover/base.py` | `Discoverer` protocol, `Context` (chain, fetcher, shared `Findings` board so later discoverers can use earlier results, e.g. official domains) | `run_all(ctx, discoverers)` |
| `discover/dotgov.py` | CISA .gov registry: official domains by jurisdiction name + state; desk candidates by keyword (tax collector, motor vehicles, housing authority, school district, 311, legal aid) | |
| `discover/website.py` | fetch official homepages (and up to N same-site pages whose link text matches topics); harvest links to ArcGIS REST roots, open-data portals, GTFS zips, 311/211 pages; phones only with the quoted surrounding text | |
| `discover/arcgis.py` | enumerate ArcGIS REST roots found by anyone (folders, services, `layers?f=json` for topic-matching services), fields + geometry type | |
| `discover/portals.py` | Socrata discovery API (domains that match official domains), CKAN (`catalog.data.gov` package_search), ArcGIS Online search for hub sites / services owned under official domains | |
| `discover/gtfs.py` | Mobility Database catalog CSV filtered by state + county/city names + bounding box; HEAD/GET probe of each feed URL | |
| `discover/federal.py` | ACS language (table-based summary file B16001 1-year / C16001 5-year on www2), HUD Public Housing Authority layer (hud ArcGIS), NCES school district directory, HUD income-limit / FMR API pages (token noted) | |
| `taxonomy.py` | generic topic taxonomy (municipal boundary, parcel, trash, recycling, school attendance, school sites, parks, libraries, voting, water/sewer, broadband, public safety, zoning, transit, 311 history, mosquito, flood) with keyword rules over service/layer/field names; `address_dependent` flag for polygon layers | `classify_layer(layer) -> list[TopicMatch]` |
| `emit.py` | writes the five outputs, all derived only from findings | `emit(run, out_dir)` |
| `compare.py` | compares a run with a plan markdown (URLs + `X/MapServer` paths) | `compare(run_dir, plan_md) -> Comparison` |
| `cli.py` / `__main__.py` | `propose`, `compare` | |

### 3.2 Types

```python
@dataclass class Jurisdiction: level: Literal["country","state","county","city"], name, fips: str|None,
                               pack_id: str, parent: str|None, evidence: list[Evidence]
@dataclass class JurisdictionChain: levels: list[Jurisdiction]; most_local() ; by_level(level)
@dataclass class Evidence: url, http_status, retrieved_at, provider, official: bool, quote: str|None
@dataclass class Finding:
    kind: Literal["domain","desk","portal","arcgis_root","arcgis_service","arcgis_layer","gtfs_feed",
                  "dataset","language","page","geocoder"]
    jurisdiction: str (pack id), title, url, official: bool, discoverer, evidence: Evidence,
    data: dict   # kind-specific: fields, geometry, layer_id, phone+quote, share, feed id ...
@dataclass class Gap: topic, jurisdiction, reason, tried: list[str]
@dataclass class OnboardingRun: place, chain, findings, gaps, fetch_log, started_at, finished_at
```

### 3.3 Rules

* Nothing is recorded unless it was fetched in this run: every finding carries an `Evidence` with
  the URL actually fetched, status and time. A phone number is recorded only as text matched on a
  fetched page, stored with the quote around it. No URL is constructed and reported unless the
  constructed URL was then fetched and answered as expected (e.g. `…/rest/services?f=json` returned
  an ArcGIS JSON directory).
* `official` = the fetched host is `.gov`/`.mil`, or is in the CISA .gov registry set discovered for
  the chain, or is a known federal/state data host (census.gov, hud.gov, huduser.gov, nces.ed.gov,
  fcc.gov, bls.gov, data.gov). Everything else (mobilitydatabase.org, arcgis.com hosted services of
  unknown owner, trilliumtransit.com, 211 nonprofits) is `official: false` unless the service's own
  metadata names an official owner, and that is written in `notes`.
* Generic: the only place-specific inputs are CLI args. Test fixtures may be Miami.
* Pack ids: `us`, `us-<st>`, `us-<st>-<county slug>`, `us-<st>-<city slug>` where slug is the
  Census name minus the legal suffix ("County", "city", "town", "village"), lowercased, non-alnum removed
  (Miami-Dade County -> `miamidade`, Miami city -> `miami`).
* Outputs in `--out` (default `research/onboarding/runs/<pack id>/`):
  `manifest.proposed.yaml` (packs with parent, languages ranked by ACS share, desks with phone/url
  and evidence, adapters with endpoint + layer + fields + topic + confidence), `sources.fragment.yaml`
  (entries shaped per source.schema.json), `facts.skeleton.json` (`{"domain": ..., "facts": [...]}`,
  every entry `status: unsourced`, adapters as `kind: lookup` entries with `value: null`, `desk`, and a
  `lookup` block; candidate observations kept in `x-candidate`), `gaps.md`, `findings.json`,
  `fetch-log.json`.
* Politeness: request budget (default 400), >=1 s per host, 20 s timeout, cache per run.

### 3.4 Candidates considered

* **A. Discoverers writing to a shared findings board, emitters reading only the board (chosen).**
  Each discoverer is deep (hides its API), the board is the only coupling; order matters only in
  that later discoverers may read earlier findings (declared via `needs`).
* **B. One region-template per state with hand-listed endpoints.** Rejected: it is hardcoding with extra
  steps, and it could not report what it failed to find.
* **C. Pure crawler (start at homepage, follow everything).** Rejected as the only mechanism: too
  slow and impolite, misses catalogs (Mobility Database, CISA registry) that are the reliable
  generic entry points. Kept as one bounded discoverer (`website.py`).

## 4. Tests (`research/tests/`)

* `python -m pytest research/tests -m 'not live'` runs with no network: HTTP is replaced by the
  `Fetcher` replay mode reading `research/tests/fixtures/http/*.json` (url, status, headers, body path).
  Unit tests set `MYAD_NO_NETWORK=1`; the Fetcher raises if a request misses the fixtures.
* `-m live --run-live` hits real endpoints (skipped without `--run-live`).
* Markers are registered in `research/tests/conftest.py`, so no root pytest config is needed
  (project root belongs to the Lead).
* `research/ci-hook.sh` (executable; `tools/ci.sh` runs it with cwd = `research/`): runs `tools/validate.py` if it and
  `sources.yaml` exist, then `python -m pytest tests -m 'not live'` with `MYAD_NO_NETWORK=1`. Python is
  `$MYAD_RESEARCH_PYTHON`, else `research/.venv` (created with uv from `requirements.txt`, offline from the uv cache
  first), else `python3` if it has the deps. Touches only `research/` (no bytecode, no pytest cache).
  Ignore list for packaging: `research/.venv/`, `research/freshness/.cache/`, `research/onboarding/runs/*/.cache/`.

## 5. Open design questions

See the end of the FM-MYAD-RES reports; kept current there.
