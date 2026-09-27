# FM-MYAD-HH — ADCore design

Owner: Household (FM-MYAD-HH). ADCore is the shared model: the household and its people, stages
and heroes, tourist mode, onboarding, privacy, the on-device store, and the shared fact/card
types every other package reads (ARCHITECTURE.md §12, §13, §13.y, §13.z).

ADCore holds **no facts**: no phone numbers, prices, addresses, URLs, or dates of any office.
Those come only from ledger facts through `FactResolving`. `ci-hook.sh` enforces this.

Swift 6 language mode, swift-tools 6.0, iOS 18 / macOS 15. The `ADCore` target builds and tests
on Linux. `ADCoreSwiftData` compiles empty on Linux (`#if canImport(SwiftData)`).

## 1. Caller's view

```swift
// Onboarding, one typed answer per voice or touch turn (router: AppAction.answerOnboarding).
var draft = OnboardingDraft()
let (next, outcome) = Onboarding.apply(.pin(Pin(latitude: 0, longitude: 0, address: "…")), to: draft)
// outcome: .next(.people, person: nil) | .invalid(error, reask: step, person:) | .complete
draft = next
// … .people([...]), then per person .originAndLanguage(origin:thinkIn:) and .goal(_)
var home = draft.makeHousehold()!                        // everyone starts at stage 1, no status word

let hero = policy.hero(for: home.people[0], catalog: cards)          // HeroPolicy(lensResolver:)
let wallet = HeroPolicy.cards(matching: CardFilter(stage: .money), on: .person(id), in: home, catalog: cards)
let slice = home.view(for: .person(id))                  // the only household data a card/agent gets
let lines = card.factLines(using: resolver, asOf: .now)  // .shown / .notApplicable / handoff to desk
let parts = card.speakableParts(using: resolver, asOf: .now)
try await store.save(home)                               // any HouseholdStore
```

`Tests/ADCoreTests/UsageTests.swift` keeps this sketch compiling.

## 2. Module layout

```
Sources/ADCore/
  Shared/      Identifiers (CardID FactID SourceID DeskID RegionPackID), StringKey, LanguageCoding,
               Place (Coordinate, Place, Weekday), Desk, Fact (FactStatus Source FactValue Fact
               FactRef FactOutcome FactResolving), Card (FactLine SourceLine SpeakableParts)
  Household/   Origin + OriginLens, Person (PersonID Goal Paper StatusWord), Household (Pin ...)
  Journey/     Stage, HeroTopic, Mode, HeroPolicy, CardFilter (+ PinID)
  Onboarding/  OnboardingStep, OnboardingAnswer, OnboardingDraft, Onboarding.apply
  Privacy/     PrivacyScope, CardSurface, PrivacyPolicy, HouseholdView
  Store/       HouseholdStore, HouseholdLoad, InMemoryHouseholdStore, HouseholdCodec
  Resources/   ADCore.xcstrings (table "ADCore")
Sources/ADCoreSwiftData/  SwiftDataHouseholdStore (Apple only)
```

## 3. Household and people

- `Household { id, name?, pin: Pin?, homeLanguage, shared: SharedHousehold, people }`. The init
  throws `HouseholdError.duplicatePerson`; decoding rejects duplicate person ids too.
- `Pin { latitude, longitude, address?, isValid }` is Lead's shape (ADCityPack and
  ADAgentsClient use it).
- `Person { id, displayName, age?, origin?, thinkIn, surfaceLanguage?, goal, mode, stage,
  statusWord?, statusWordSharedWithHousehold, papers, completedCards }`. `mode` and `stage` are
  `private(set)` and change only through `setStage`, `advanceStage`, `iLiveHereNow`,
  `becomeTourist`. `thinkInLanguageTag` and `surfaceLanguageTag` (falls back to thinkIn) are the
  BCP-47 strings ADLocale reads. `isChild` is age < 18; unknown age counts as adult.
- `Goal`: arrive, study, work, reunite, visit, `getThroughWeek` (the server's raw values).
- `Origin { countryCode }` is uppercased on init and on decode. `OriginLens` uses the server's raw
  values (latinAmerica, haiti, leftDriving, internationalStudent, tourist, questionnaire). The
  country → lens mapping is content's (`OriginLensResolving`); ADCore has no country lists.
- The status word is optional everywhere. Nothing asks for it (see §6).

## 4. Stages, heroes, tourist mode

| # | `Stage` | slug | `heroTopics` |
|---|---|---|---|
| 1 | safeThisWeek | safe_this_week | bed, food, airport, scam |
| 2 | mailAndStatus | mail_and_status | statusWord, mailbox |
| 3 | identification | id | idChecklist |
| 4 | money | money | bank, remittance, noCheckCasher |
| 5 | roof | roof | rentLine, listingCheck, whichCity |
| 6 | health | health | clinicDesk |
| 7 | schoolOrAllowedWork | school_or_allowed_work | schoolZone, dso, eadDates |
| 8 | movement | movement | transit, license, tolls, insurance |
| 9 | paperTrail | paper_trail | irs, credit, deadlines |
| 10 | footing | footing | ordinaryWeek |

Tourist heroes (`Mode.touristHeroTopics`, plan order): airport, scam, tipping, sun,
rentalCarTolls, emergency911, backToAirport.

- `HeroPolicy.hero(for:catalog:)` ranks lens matches first, then the stage's topic order, and
  skips completed cards. Lenses add `.internationalStudent` for goal study and `.tourist` for
  tourists. `nextSteps(limit:)` clamps a negative limit to 0.
- Mode is per person. The household card is tourist only when every member is a tourist.
- A tourist's ladder is {1, 10}; `setStage(2...9)` throws. Decoding a tourist at stage 2–9 fails.
- Hard filter: an `isImmigrationContent` card is never shown to a tourist, whatever `modes`
  says. This applies to hero, next steps, and wallet, for person and household cards, on any
  surface where the viewer is a tourist.
- "I live here now" (`iLiveHereNow(goal:)`): mode becomes resident; stage 10 resumes at 2; stage 1
  stays 1; goal visit becomes arrive unless one is given. No status word is asked.

### 4.1 Hero SF Symbols

All symbols are decorative: the UI hides them from VoiceOver (`accessibilityHidden(true)`), and
the label comes from `HeroTopic.labelKey`. A pair that can share a screen never shares a base
glyph (tested).

| topic | symbol | topic | symbol |
|---|---|---|---|
| bed | bed.double | dso | studentdesk |
| food | fork.knife | eadDates | person.text.rectangle |
| airport | airplane | transit | bus |
| scam | exclamationmark.triangle | license | car |
| statusWord | doc.text | tolls | road.lanes |
| mailbox | envelope | insurance | checkmark.shield |
| idChecklist | list.clipboard | irs | archivebox |
| bank | building.columns | credit | creditcard |
| remittance | dollarsign.arrow.circlepath | deadlines | alarm |
| noCheckCasher | banknote | ordinaryWeek | calendar |
| rentLine | house | tipping | dollarsign.circle |
| listingCheck | checklist | sun | sun.max |
| whichCity | map | rentalCarTolls | car.rear.road.lane |
| clinicDesk | cross.case | emergency911 | sos |
| schoolZone | graduationcap | backToAirport | airplane.departure |

Swapped from the first draft: scam (was exclamationmark.shield, too close to insurance), irs
(was doc.plaintext, too close to statusWord), deadlines (was calendar.badge.clock), eadDates (was
calendar), ordinaryWeek (was list.bullet), noCheckCasher (was nosign), remittance (was
arrow.left.arrow.right), whichCity (was building.2, too close to bank). tipping is tourist-only
and remittance is resident stage 4, so the two dollar-sign glyphs never share a screen.
**Mac check needed:** `UIImage(systemName:) != nil` for all 30 names (Linux can't check this).

## 5. Shared fact and card types (the contract)

### 5.1 FactValue — final, exactly ten cases (§13.z)

```swift
public enum FactValue: Hashable, Sendable, Codable {
    case text(String, language: Locale.Language)
    case code(String)                 // never translated: folio, district id, grade span, names
    case codes([String])              // e.g. route names at a stop, source order
    case phone(digits: String)
    case date(Date)
    case money(amount: Decimal, currency: String)   // ISO 4217
    case quantity(Decimal, unit: String)            // year built: .quantity(1984, unit: "year")
    case weekdays(Set<Weekday>)
    case place(Place)
    case flag(Bool)
    public var displayKey: StringKey? { get }       // flag → fact.flag.yes / fact.flag.no; else nil
    public var verbatimCodes: [String]? { get }     // code → [s], codes → array; else nil
}
```

- No `number`, `url`, or `verbatim`. "None recorded" is a `FactOutcome`, never a sentinel.
- Wire: `{"kind": "<case name>", ...}`. Payload keys: text `text`+`language` (BCP-47), code
  `code`, codes `codes`, phone `digits`, date `date`, money `amount`+`currency`, quantity
  `amount`+`unit`, weekdays `days`, place `place`, flag `value`.
- `code`/`codes` render and speak verbatim: never localized, never looked up as a StringKey. ADCore
  adds no joiner words ("and"); it exposes the array and ADLocale joins it.
- Values are typed, never preformatted. ADLocale formats; ADVoice speaks.

### 5.2 Fact, FactRef, FactOutcome

- `Fact { id, source?, quote?, quoteLanguage?, retrievedAt?, status, checkEveryDays? }` plus an
  internal `value`. The init throws when evidence doesn't match status (verified/stale need value,
  source, quote, retrievedAt; demo needs value). Decoding runs the same validation.
  `displayValue` is nil for unsourced facts. `status(asOf:)` turns a verified fact stale after
  `checkEveryDays`.
- `FactStatus`: verified, stale, unsourced, demo (`labelKey` = `fact.status.<raw>`).
- `FactRef { regionPackID: RegionPackID, ledgerFactID: FactID }`, wire
  `{"pack_id": "...", "fact_id": "..."}` (explicit CodingKeys, golden fixture test).

```swift
public enum FactOutcome: Hashable, Sendable, Codable {
    case fact(Fact)
    case notApplicable(reason: StringKey, deferTo: FactRef?)
    case unsourced(desk: Desk)      // no source exists
    case unavailable(desk: Desk)    // a source exists but could not be reached
}
```

Wire is a tagged union with no nullable value slot: `{"type":"fact","fact":{…}}`,
`{"type":"not_applicable","reason":{…},"defer_to":{…}}` (defer_to omitted when nil),
`{"type":"unsourced","desk":{…}}`, `{"type":"unavailable","desk":{…}}`. Both desk cases carry
the full `Desk` (id, regionPack, contactFacts), the type `.unsourced` already used.

### 5.3 Card and the line logic

- `Card { id, regionPack, subject, titleKey, heroTopic?, modes, isImmigrationContent, lenses,
  desk, facts, keyFact? }`. The init throws `CardError.emptyDesk` or `.keyFactNotOnCard`; decoding
  runs the same checks and defaults (modes [.resident], immigration false, keyFact = first fact,
  titleKey `card.<id>.title` in table "Cards").
- `FactLine`: `.shown(Fact, status:)`, `.notApplicable(FactID, reason:, deferTo:)`,
  `.handedToDesk(FactID, desk:)`, `.sourceUnavailable(FactID, desk:)`. `handoffDesk` returns the
  desk for both handoff cases.
- Line rules: a fact shows only if `displayValue != nil` and its evidence matches its status
  (backstop against unchecked data); otherwise it goes to the card's desk. `.unsourced` goes to
  `.handedToDesk` and `.unavailable` goes to `.sourceUnavailable`. Both name the outcome's desk
  and show no value. An unknown id goes to the card's desk. Old data appears only as a sourced
  `Fact` with status `.stale` (or a verified fact past its check window), labelled stale, never
  as live.
- `SourceLine`: `.sourced([Source], lastChecked:)` (oldest retrieval among shown facts) or
  `.noSource(desk:)`.
- `SpeakableParts { titleKey, keyFact, verbatimCodes, sourcePublisher, retrievedAt, desk }`.
  `verbatimCodes` holds the strings voice must read as-is when the shown key fact is a
  code/codes value (empty otherwise).

## 6. Voice-first onboarding (§13.3)

The four questions, from the plan's "Who it is for", each ending in a real question mark
(English in `ADCore.xcstrings`, es/ht from Language):
1. `onboarding.q1` "Where are you sleeping, or where is the pin?"
2. `onboarding.q2` "Who is in your household, including you?" (one question, per Access review)
3. `onboarding.q3` "Where did this person live before, and what language do they actually think in?"
4. `onboarding.q4` "What are they here to do right now: arrive, study, work, reunite, visit, or just get through this week?"

Questions 3 and 4 are asked once per person. `OnboardingDraft.prompt` returns an
`OnboardingPrompt { question, personName, leadIn }`; the UI shows and speaks `leadIn`
(`onboarding.about_person`, "For %@:", formatted with the name exactly as given) right before the
question, so a voice-only listener knows whose question it is. Error messages never repeat the
question, because the question is asked again right after them.

```swift
public enum OnboardingStep: String, Hashable, Codable, Sendable, CaseIterable {
    case pin, people, originAndLanguage = "origin_and_language", goal
    public var prompt: StringKey { get }            // onboarding.q1 … q4, table "ADCore"
}
public struct OnboardingPerson: Hashable, Codable, Sendable { displayName: String; age: Int? }
public enum OnboardingAnswer: Hashable, Sendable, Codable {
    case pin(Pin)
    case people([OnboardingPerson])
    case originAndLanguage(origin: Origin?, thinkIn: String)   // thinkIn is BCP-47
    case goal(Goal)
    case volunteeredStatusWord(StatusWord, person: PersonID)   // never prompted
}
public enum Onboarding {
    public static func apply(_: OnboardingAnswer, to: OnboardingDraft) -> (OnboardingDraft, OnboardingOutcome)
}
public enum OnboardingOutcome { case next(OnboardingStep, person: PersonID?), complete,
                                 invalid(OnboardingError, reask: OnboardingStep?, person: PersonID?) }
```

- Order: pin → people → for each person, originAndLanguage then goal. `OnboardingDraft` is
  Codable, so a voice session can resume. `apply` is pure.
- Validation (the same step is asked again): invalid pin, no people, a name that is empty after
  trimming whitespace and newlines, an age outside 0–130, an empty language or one with no
  language code, an answer for a different step, an unknown person. Each `OnboardingError` has a
  `messageKey` (`onboarding.error.*`).
- The status word is never an `OnboardingStep` and never prompted. A person can volunteer it with
  `.volunteeredStatusWord`, which applies to that person and does not change the next step.
- Tourists answer the same four questions (the plan has no skipped question); goal `visit` makes
  the person a tourist.
- Wire: tagged JSON with snake_case keys, as it rides in `AppAction.answerOnboarding`:
  `{"type":"pin","pin":{…}}`, `{"type":"people","people":[{"display_name":"…","age":3}]}`,
  `{"type":"origin_and_language","origin_country_code":"HT","think_in":"ht"}`,
  `{"type":"goal","goal":"visit"}`,
  `{"type":"volunteered_status_word","status_word":"…","person_id":"<uuid>"}`.

## 7. Router support types (§13.y)

```swift
public struct PinID: StringIdentifier { public let rawValue: String }   // Hashable Codable Sendable, plain string on the wire
public struct CardFilter: Hashable, Codable, Sendable {
    public var subject: CardSubject?; public var stage: Stage?; public var desk: DeskID?; public var mode: Mode?
    public init(subject: CardSubject? = nil, stage: Stage? = nil, desk: DeskID? = nil, mode: Mode? = nil)
}
extension HeroPolicy {
    public static func cards(matching: CardFilter, on: CardSurface, in: Household, catalog: [Card]) -> [Card]
    public static func canShow(_: Card, on: CardSurface, in: Household) -> Bool
}
```

- `PinID` names a pin choice (e.g. one of the two demo pins in ADCityPack's fixtures). ADCore
  doesn't resolve it; the household stores the chosen `Pin`.
- `CardFilter` only narrows. Its matcher is internal, and the only public way to apply it is
  `HeroPolicy.cards(matching:…)`, which builds the surface's wallet (privacy and tourist rules)
  first. A filter can never widen what a surface may show: asking for `mode: .resident` on a
  tourist's surface still returns no immigration card. `stage` matches cards whose hero topic is
  in that stage. Wire keys: `subject`, `stage` (Int 1–10), `desk`, `mode`.

## 8. Privacy (domain layer only)

`PrivacyPolicy.isVisible(_ scope: PrivacyScope, on surface: CardSurface, in household: Household) -> Bool`
and `Household.view(for: CardSurface) -> HouseholdView?` are the only rules. Storage keeps full
data; the view filters.

| scope \ surface | household card | own card | other adult's card | child's card (not owner) |
|---|---|---|---|---|
| `.sharedAddress` (pin) | yes | yes | yes | yes |
| `.household` (rent, car, income, home language, roster) | yes | adult yes / child no | yes | no |
| `.personal(A)` (profile, papers, status word) | no | A only | no | no |
| `.sharedOnPurpose(by: A)` | yes | yes | yes | yes |
| viewer not in household | `view(for:)` is nil | | | |

- Other members appear only as id plus display name (roster). The full `PersonProfile` is on the
  person's own card only.
- A tourist viewer (a tourist's card, or an all-tourist household card) never sees a status word
  or an immigration paper, their own included. A tourist's own status word is never surfaced.
- `HouseholdView`, `MemberView`, `PersonProfile` are Encodable only (built by `view(for:)`).
  ADAgentsClient sends a view, never a `Household`.

## 9. Store and schema

- `HouseholdStore` (async, Sendable): `loadAll() -> HouseholdLoad`, `save`, `delete(id)`,
  `deleteEverything()`. No account, no network.
- `HouseholdLoad { households (sorted by id), failures [HouseholdLoadFailure{id, reason}] }`:
  each row decodes on its own, so one bad row never hides the others.
- `HouseholdCodec`: envelope `{"schemaVersion": 1, "household": {…}}`. The header is read first.
  A missing header means v0, the unversioned skeleton-stub household shape, which is migrated on
  read. Any other version throws `CodecError.unsupportedSchema(v)` without touching the body.
  Fixtures: `household-v0.json`, `household-v1.json`, `household-v2-future.json`.
- `InMemoryHouseholdStore` (actor) for tests and previews.
- `SwiftDataHouseholdStore` (`ADCoreSwiftData`, whole file under `#if canImport(SwiftData)`): one
  `StoredHousehold {id unique, payload}` row per household. There is no schemaVersion column: the
  codec envelope carries the version (review finding 13). **Not compiled yet** (Linux); it needs
  the Mac batch.
- **Ordering contract (every store):** `loadAll().households` is sorted by id (the UUID string,
  ascending), and so is `failures`. The sort lives in `HouseholdLoad`'s init, so the in-memory
  and SwiftData stores return the same order without each re-implementing it. Test:
  `StoreCodecTests.everyStoreReturnsHouseholdsSortedById`.

## 10. Wire and strings

- Every language on the wire is a plain BCP-47 string (`Locale.Language.minimalIdentifier`), e.g.
  "hi", "ht", "es-419". The nested `{"components":…}` form is rejected.
- Ids are plain strings (`RegionPackID`, `DeskID`, `CardID`, `FactID`, `PinID`) or UUID strings
  (`PersonID`, `HouseholdID`).
- `StringKey(key:table:)` defaults to table "ADCore". ADCore's keys live in
  `Resources/ADCore.xcstrings`, loaded through `Bundle.module` (`ADCoreStrings.bundle`), with
  `defaultLocalization: "en"`. On Linux SwiftPM warns "no rule to process … xcstrings" and copies
  the catalog into the bundle as-is; on Apple it compiles to .strings.
- The catalog holds en, es and ht plus a comment per key. es/ht are Language's to write; values
  Household changes are set back to needs_review for them. Keys (69):
  `stage.<slug>.title` ×10, `hero.<topic>` ×30, `onboarding.q1`–`q4`, `onboarding.about_person`, `goal.<raw>` ×6,
  `mode.resident|tourist|i_live_here_now`, `fact.status.<raw>` ×4, `fact.flag.yes|no`,
  `source_line.sourced|no_source`, `onboarding.error.*` ×7. There are no weekday strings in ADCore
  (day names and joiners are ADLocale's).
- Tests check that every ADCore StringKey is in the catalog with English and a comment, and that
  the catalog has no unused key.

## 11. Checks

- `swift test` (Linux): 76 tests in 11 suites.
- `ci-hook.sh` (offline, keyless): fails on a phone-number, price, URL, or street-address literal
  in `Sources/` (comments may cite examples), and on any literal `.adCore("key")` missing from the
  catalog.
- Mac batch: build `ADCoreSwiftData`, a SwiftData store test, an SF Symbol existence test for all
  30 names, and `swift test` on macOS.

## 12. Decisions taken from the skeleton, and open points

- Adopted from Lead: `Pin` shape, `Goal.getThroughWeek`, `OriginLens` raw values, `CardSurface`,
  `Person.displayName` and the language-tag properties.
- `Card` keeps this package's shape (§12), not §3's title/summary/body/privacyScope.
- `FactRef.ledgerFactID` is typed `FactID` (same string on the wire).
- `ADCore.xcstrings` has en, es and ht for every key (Language merged es/ht); needs_review values
  pass normal runs and fail only under `--release`.
- `Weekday.stringKey` lives in ADLocale, not ADCore. With the default table now "ADCore" it points
  at a table that has no weekday keys; Language should remove it.
- The `FactValue` discriminator key is `kind` (values are the case names). ARCHITECTURE.md §13.2
  names `"type"` only for `Destination`, `AppAction`, and `IntentResolution`, and §13.z fixes the
  FactValue tag values but not the key, so `kind` stays. `FactOutcome` and `OnboardingAnswer` use
  `type`, like the router unions. Switching FactValue to `type` is a one-line change if Lead asks.
- Open: the hero rank within a stage (lens first) is an inference from the demo; child threshold
  18 with unknown age treated as adult; where paper photos are stored; one household per device
  or several.
