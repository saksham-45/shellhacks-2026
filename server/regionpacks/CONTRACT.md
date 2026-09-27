# Region packs contract (owner: myAD Regions)

What `runtime.py` returns, and how ADCityPack maps it to ADCore. Decisions come from ARCHITECTURE.md §13 and
Lead's final call in §13.z. The tests enforce every rule here (`tests/`, `ADCityPackTests`, both `ci-hook.sh`).

## 1. Entry points (`runtime.py`, in-process, read-only)

| call | returns |
|---|---|
| `resolve(pin, timeout_s=20.0)` | pack ids containing the pin, country first, e.g. `["us","us-fl","us-fl-miamidade"]`; `["us"]` if the pin cannot be placed |
| `answer(pin, fact_ids=None, topics=None, timeout_s=20.0)` | list of result dicts (§2) for the declared facts of the pin's packs, in manifest order, narrowed by `fact_ids` and/or `topics` |
| `answer_question(pin, question, timeout_s=20.0)` | `{question, owner, results, passed_over, membership_unknown}` (most local pack wins; §5) |

- `pin` is `{"address": str, "lat": float?, "lon": float?}`. With `lat`/`lon` the geocoder is **not** called and
  `basis.method` is `"device_coords"`. Without them the address is geocoded: first the Miami-Dade County address
  locator, using only its best `PointAddress` candidate at score 95 or above (`"county_locator"`; that point sits on
  the parcel), then the U.S. Census geocoder as a fallback (`"census_geocoder"`; street-interpolated, can land off
  the parcel). Send the ZIP in the address: without it the county locator also matches Homestead. The demo pins'
  coordinates are the county PointAddress points (`myad_regions/pins.py`).
- `timeout_s` caps the **whole call** and is clamped to (0, 20] s. The calls never raise for source problems.
- Thread-safe. Module state is read-only (manifests, source registry, adapters, fixture index). Each call has
  its own deadline, transport and executor.
- Fixture mode is the default. Live mode needs `MYAD_LIVE=1`.
- **No logging.** Nothing logs, prints or puts addresses, coordinates or request/response bodies into error
  strings. Error strings name the problem ("timed out", "HTTP 503") and never the URL. The URL appears only in
  the result's `url` field, which is the source evidence.

## 2. Result shape

```json
{
  "fact_id": "us-fl-miamidade.parcel.year-built",
  "ledger_id": "us-fl-miamidade.parcel.year-built.demo.pin-nw1st",
  "pack": "us-fl-miamidade",
  "status": "ok",
  "is_demo": true,
  "value": {"type": "quantity", "amount": 1984, "unit": "year"},
  "source_id": "us-fl-miamidade.gis-parcels",
  "publisher": "Miami-Dade County (GIS)",
  "url": "<exact request URL>",
  "retrieved_at": "2026-09-25T17:34:10-04:00",
  "quote": "YEAR_BUILT: 1984",
  "jurisdiction": "us-fl-miamidade",
  "desk": "us-fl-miamidade.property-appraiser",
  "basis": {"method": "device_coords", "lookup": "address_match", "distance_m": 0.0},
  "not_applicable": null,
  "error": null,
  "check_every": "P30D"
}
```

- `fact_id` is stable and deterministic. Ranked facts are `.1`–`.3`. Every emitted id is declared in the
  manifest's adapter `facts`.
- `ledger_id`: in fixture mode it is `<fact_id>.demo.<pin>` (`pin-sw137`, `pin-nw1st`; `pin-unmatched` for other
  pins, `pin-unresolved` when the pin could not be placed). Live, it equals `fact_id`.
- `is_demo` is `true` in fixture mode, and the Swift side then builds the Fact with status `.demo`.
- Fee Check facts (`basis.lookup` = `"ledger"`: official fees and payment rules) are not pin lookups. They are
  answered only from myAD Research's verified row in `research/facts/*.json` (override the folder with
  `MYAD_LEDGER_DIR`), never from code or fixtures. Their `ledger_id` always equals `fact_id` and `is_demo` is
  `false` in every mode. A fact the ledger lacks, or has unverified or untypeable (money without a currency,
  text without a language), is `unsourced` with the adapter's desk.
- `desk` is on **every** result. It is the manifest desk (a DeskID only, never a phone, address or hours).
  Desks are placeholders until Research posts final ids (`desks_placeholder: true`).
- `jurisdiction` is the pack whose law the figure belongs to. A figure applies only inside that jurisdiction:
  no `us-fl-miami` result ever appears for a pin outside the City of Miami.
- `url` and `retrieved_at` are present on every status except `unsourced` (no source exists).

### Status

| status | meaning | value | Swift `FactOutcome` |
|---|---|---|---|
| `ok` | answered from the source | required | `.fact(Fact)` (`.demo` if `is_demo`, else `.verified`); if value, url, retrieved_at or quote is missing or invalid → `.unavailable(desk)` |
| `not_applicable` | the source answers "not here" | null | `.notApplicable(reason: StringKey(key, table "ADCityPack"), deferTo: FactRef?)` |
| `unavailable` | the source exists but could not be reached or timed out | null | `.unavailable(desk)` |
| `error` | the source answered with something unusable (e.g. an unmapped TRASHDAY code) | null | `.unavailable(desk)` |
| `unsourced` | no source yet (e.g. county rent table) | null | `.unsourced(desk)` |

"Nothing recorded" is an outcome, never a fake value. For example, a parcel with `YEAR_BUILT` 0 or null is
`not_applicable` with `regions.na.parcel-year-not-recorded`, never `0`.

`not_applicable` is `{"reason": "<catalog key>", "defer_to": {"pack_id": ..., "fact_id": ...} | null}`.
`defer_to` only points at a **more local** pack, e.g. county trash inside the City of Miami defers to
`{"pack_id":"us-fl-miami","fact_id":"us-fl-miami.trash.day"}`. Reason keys live in ADCityPack.xcstrings:
`regions.na.outside-layer`, `.county-trash-not-serviced`, `.city-trash-not-serviced`, `.none-within-radius`,
`.parcel-year-not-recorded`, `.no-parcel-nearby`.

## 3. Values: exactly ADCore's ten `FactValue` cases (§13.z)

| `type` | fields | ADCore |
|---|---|---|
| `text` | `text`, `language` (BCP-47) | `.text(_, language:)`: the source's own wording (e.g. land use) |
| `code` | `code` | `.code`: never translated (folio, district, grade span, member name, utility code) |
| `codes` | `codes` | `.codes` (route lists) |
| `phone` | `digits` | `.phone(digits:)` |
| `date` | `date` (YYYY-MM-DD) | `.date` |
| `money` | `amount` (JSON number), `currency` | `.money` |
| `quantity` | `amount` (JSON number), `unit` | `.quantity`: year built is unit `"year"` |
| `weekdays` | `days` (`"sunday"`…`"saturday"`) | `.weekdays` |
| `place` | `place: {name, coordinate: {latitude, longitude}, address}` | `.place(Place)`: schools, parks, libraries, stops, polling place |
| `flag` | `value` (bool) | `.flag` |

Any other `type` fails validation (Python) and decoding (Swift). There is no URL value; a URL is only source
metadata (`url`). Distances are straight-line metres in `basis.distance_m`.

## 4. FactRef

The JSON is always `{"pack_id": "<RegionPackID>", "fact_id": "<FactID>"}` (ADCore `FactRef` CodingKeys).

## 5. Most local wins

For a question, walk the pin's chain from most local to least. A pack whose results are **all**
`not_applicable` passes to its parent (`passed_over`). Any other status stops there: `unavailable`, `error` and
`unsourced` hand over that pack's desk and never silently fall back to a parent's figure.
When the pin's packs can't be worked out (the geocoder or the county boundary layer is unreachable), the walk
also covers the county and state packs whose facts came back `unavailable` or `error`, so their desk still reaches
the caller, and `membership_unknown` is `true`. City packs are never claimed while membership is unknown.
Swift: `RegionPackRegistry.resolve(_:at:)`.

## 6. Topics

Every manifest fact carries `topics` from: trash, schools, parcel, water, parks, libraries, voting,
representatives, transit, tolls, rent, desk, municipality. `answer(pin, topics=[...])` and
`myad_regions.manifests.adapters_for_topic(topic, packs)` serve the household-week path. The vocabulary lives in
`myad_regions.manifests.TOPICS` until `research/topics.yaml` exists; the test switches to the yaml then.
