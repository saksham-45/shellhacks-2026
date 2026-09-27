# myAmericanDream — architecture

Owner: myAD Lead. Interface-first: this file is the contract; code under it fills in bodies.
Sources: `FM-MYAD-FOUND-spec.md` and the three plans (`myamericandream-plan.md` wins on conflict).

## 1. Framing

An agentic harness inside an app that guides a person through a new country, state, county, or city.
**A region is data plus adapters.** Miami is the first pack, not the product. Household, person,
stages, privacy, language, and the agents are the same everywhere; a new place adds a pack
(manifest + deterministic adapters + sourced facts + desks), never a rewrite.

Two independent axes: **region pack** (where the person is now, from the pin) and **origin lens**
(where they came from). Neither reads the other.

Hard rules that shape every interface: never invent a fact (every figure resolves to a ledger fact
with source); privacy scopes decide visibility in one place; tourist mode hides immigration;
es/en/ht parity or the string does not ship; accessibility from day one.

## 2. Module map and dependency direction

```
ios/Packages
  ADCore            (no deps)          model, privacy, facts, store protocol
  ADLocale          -> ADCore          surface/think-in languages, StringKey resolution, weekday wording
  ADVoice           -> ADLocale        speech in/out following the sentence spoken
  ADCityPack        -> ADCore          RegionPack protocol, manifest, pin -> pack chain resolution
  ADRouter          -> ADCore, ADLocale   ONE router: Destination, AppAction, intent contract, command matcher (§13)
  ADAgentsClient    -> ADCore, ADLocale, ADRouter   /v1 wire models + client
  ADAccessibility   -> ADCore          (owner Access) identifiers, 44pt target, SpokenRepresentable
ios/App             -> all packages    thin basic test UI (replaceable)
server/             FastAPI + ADK graph; server/regionpacks/<pack>/ (manifests, adapters, fixtures)
research/           sources.yaml, facts/*.json (ledger), reports/
content/            cards/<id>.yaml, lenses/, facts-requested.yaml
contracts/intent/   golden JSON for Destination/AppAction/IntentResolution; Swift and server both test against it (§13)
tools/              ci.sh, checks, snapshot/diff
```

ADCore never imports another AD package. No cycles. Every package: swift-tools-version 6.0,
iOS 18 / macOS 15, Swift 6 language mode, own `Localizable.xcstrings` via `Bundle.module`.
Apple-only frameworks (SwiftUI, SwiftData, Speech, AVFoundation) sit behind `#if canImport`, so
every package builds and tests on Linux.

## 3. Type signatures (bodies minimal; owners fill in)

### ADCore (owner: Household)
```swift
struct StringKey { key: String; table: String }          // every user-facing text ref; ADCore holds no display strings
struct Pin { latitude, longitude: Double; address: String? }
enum Mode: String { resident, tourist }                   // tourist: stages 2-9 hidden, no immigration
enum Goal { arrive, study, work, reunite, visit, getThroughWeek }
struct Household { id: UUID; name; pin: Pin?; people: [Person]; homeLanguageTag: String? }
struct Person { id; displayName; age?; origin: Origin; surfaceLanguageTag; thinkInLanguageTag;
                stage: Stage; mode: Mode; goal: Goal; statusWord: String?; sharesPapersWithHousehold: Bool }
enum Stage: Int { safeThisWeek=1 ... footing=10; isShownInTouristMode }
protocol HeroSelecting { func hero(for: Person, in: Household, cards: [Card]) -> Card.ID? }  // hero follows stage
struct StageHeroSelector: HeroSelecting
struct Origin { countryCode: String?; lenses: Set<OriginLens> }
enum OriginLens { latinAmerica, haiti, leftDriving, internationalStudent, tourist, questionnaire }
struct Card { id; title, summary, body: StringKey  /* table "Cards", card.<id>.title|summary|body */;
              desk: Desk.ID?; privacyScope; stages: Set<Stage>; modes: Set<Mode>; regionPack: String;
              factRefs: [FactRef]; isImmigration: Bool }
struct Desk { id /* "us-fl-miamidade.311" */; name: StringKey; factRefs: [FactRef] }  // phone/url are facts
struct FactRef { regionPackID; ledgerFactID }            // wire: {"pack_id","fact_id"}; fact_id = full ledger id
struct Place { name: String; latitude, longitude: Double; address: String? }  // no CoreLocation; name never translated
enum Weekday: String { sunday ... saturday }              // no firstWeekday, no display names (ADLocale owns wording)
enum FactValue { text(String, language:), code(String), codes([String]), phone(digits:), date(Date),
                 money(amount:, currency:), quantity(Decimal, unit:), weekdays(Set<Weekday>), place(Place), flag(Bool) }
enum FactOutcome { fact(Fact); notApplicable(reason: StringKey, deferTo: FactRef?); unsourced(desk: Desk);
                   unavailable(desk: Desk) /* source exists but unreachable */ }
struct Fact { id: FactRef; claim; value; unit?; jurisdiction; sourceID; url?; quote?; retrievedAt?;
              checkEvery?; status: FactStatus; typedValue: FactValue; outcome: FactOutcome }
enum FactStatus { verified, stale, unsourced, demo }
enum PrivacyScope: String { household, person, personPapers = "person-papers" }
enum CardSurface { household, person(Person.ID) }
enum PrivacyPolicy { static func isVisible(card:ownedBy:on:viewerMode:) -> Bool }  // the only visibility decision
protocol HouseholdStore { loadAll(); save(_:); delete(_:) }  // async throws; SwiftDataHouseholdStore behind it
actor InMemoryHouseholdStore: HouseholdStore
```

### ADLocale (owner: Language)
```swift
enum SurfaceLanguage: String { case es, en, ht }          // three full surfaces; autonym; locale
struct SpokenLanguage { bcp47: String; surface: SurfaceLanguage? }   // "language I think in", any tag
@Observable @MainActor final class LanguageSettings { var surface: SurfaceLanguage; var thinkIn: SpokenLanguage }
extension View { func surfaceLanguage(_: LanguageSettings) -> some View }  // live switch via \.locale
extension StringKey { func resolve(in: Bundle, surface: SurfaceLanguage) -> String }
extension Weekday { var stringKey: StringKey }            // owned by ADLocale (ADCore ships no weekday strings)
```
Buttons follow `surface`; spoken explanations follow `thinkIn`.

### ADVoice (owner: Language)
```swift
struct Utterance { text; language: SpokenLanguage }
protocol SpeechRecognizing { recognize(candidates: [SpokenLanguage]) async throws -> Utterance }
protocol SpeechSpeaking { speak(_: Utterance) async throws }
protocol VoiceRouting { route(for: SpokenLanguage) -> VoiceRoute }   // onDevice | cloudFallback (Creole measured first)
func replyLanguage(for heard: Utterance) -> SpokenLanguage          // reply follows the sentence spoken
SystemRecognizer / SystemSpeaker behind #if canImport(Speech / AVFoundation)
```

### ADCityPack (owner: Regions)
```swift
struct Question: RawRepresentable<String>                 // "trash.schedule", "government.which"
struct AdapterDescriptor: Codable { id; answers: [Question]; sources: [String] }
struct RegionPackManifest: Codable { id; parent: String?; adapters; sources: [String]; desks: [Desk.ID]; languages: [String] }
protocol RegionPack { manifest; contains(_ pin) async throws -> Bool; answer(_ q, at pin) async throws -> [FactOutcome] }
struct RegionPackRegistry { applicablePacks(for pin) /* country first */; owner(of q, at pin) /* most local */ }
```

### ADAgentsClient (owner: Agents) and ADAccessibility (owner: Lead code, Access standard)
`AgentsClient` protocol + `HTTPAgentsClient` (snake_case JSON) mirroring `server/src/myad_server/models.py`.
`ADAccessibility.identifier(forCard:)`, `minimumTapTarget = 44`, `SpokenRepresentable`, `View.adTapTarget()`.

## 4. Region packs: nesting and resolution

`us` > `us-fl` > `us-fl-miamidade` > `us-fl-miami`. Each pack is `server/regionpacks/<id>/manifest.json`
(decodes as `RegionPackManifest`), its adapters, and offline fixtures. Resolution for a pin:
1. every pack whose boundary contains the pin (point-in-polygon, never "nearby") applies, ordered by depth;
2. per question, the **most local applicable pack declaring an adapter for it wins**;
3. a pack that has a layer but no answer returns `notApplicable(reason:, deferTo:)` (county trash inside
   the City of Miami defers to the city's fact), never a guess;
4. no source anywhere returns `unsourced(ref, desk:)`: the card says so and names the desk.
Unincorporated pins simply have no city pack in the chain. Country rules (911, notario warning, SSN/ITIN,
tipping, driving ethics) live in `us` and do not change when the pin moves.

## 5. Agents graph and the /v1 contract (owner: Agents)

Google ADK 2.x graph `Workflow` + Gemini, FastAPI, Python 3.12. (ADK 2.x deprecates ParallelAgent,
SequentialAgent and LoopAgent; the behaviour below is what matters, built on graph nodes.) Graph per request:
1. **planner**: turns the request (household week / person next steps / ask) into questions + card ids;
2. **parallel research** over the resolved pack chain's **deterministic adapters** (no LLM-made facts);
3. **verifier loop** with an exit route: drops every claim without a ledger fact ref and repeats until all
   remaining claims are sourced; reports `dropped_claims`;
4. **presenter** (deterministic): fills Content's reviewed es/en/ht copy with the verified facts in the
   requested language. The model only ranks and classifies; **no endpoint returns model-written prose.**
   The screen and the voice read the same claims.

Household agent sees shared context only (pin, packs, rent, car, home language). Person agent sees one
person (age, origin lenses, stage, mode, goal, opt-in status word) and never another person's papers.

| Route | Request | Response | Now |
| --- | --- | --- | --- |
| `GET /healthz` | – | `{status: ok}` | 200 |
| `POST /v1/household-week` | household_id, pin, surface_language, think_in?, mode | household_id, language, pack_ids, items[card_id, date?, claims], dropped_claims | 501 |
| `POST /v1/person-next-steps` | person{person_id, age?, origin_lenses, stage 1-10, mode, goal, status_word?}, pin?, surface_language, think_in? | person_id, language, steps (≤3), origin_comparison, dropped_claims | 501 |
| `POST /v1/ask` | text, spoken_language, surface_language, household_id?, person_id?, pin?, mode | language, card_id?, claims, desk_id?, dropped_claims | 501 |

`Claim { text, fact_refs (≥1 ledger id), desk_id? }`. The server is stateless: nothing is stored.

## 6. Privacy

- No account; no status question required; the household lives on the phone (`HouseholdStore`,
  SwiftData adapter). The backend receives only what a request needs and stores nothing.
- `PrivacyPolicy.isVisible` is the single decision point: `household` shows everywhere; `person` only on
  that person's card; `person-papers` only on the owner's card, and on the household card only if the
  owner opted in. Papers never show on another person's card.
- Tourist mode hides every `isImmigration` card and stages 2-9.

## 7. Conventions

- **Fact ids**: dotted, lowercase, region-scoped, first segment is the pack id (`us-fl-miamidade.311.phone`).
- **Ledger** (`research/facts/*.json`, arrays): `id, claim, value, unit, jurisdiction, source_id, url, quote,
  retrieved_at, check_every, status (verified|stale|unsourced|demo)`. Publisher lives in `research/sources.yaml`.
  Only `verified` or labeled `demo` facts render as figures.
- **Cards** (`content/cards/<id>.yaml`): `id`, `title/summary/body` each `{es, en, ht}`, `desk`,
  `privacy_scope household|person|person-papers`, `stages`, `modes resident|tourist`, `region_pack`, `fact_refs`.
  Copy uses `{fact:<id>}` placeholders, never inline numbers. The card copy compiles to the "Cards" string table
  (`card.<id>.title|summary|body`) that ADCore `StringKey`s point at.
- Missing facts: Content lists them in `content/facts-requested.yaml`; Research fulfils.
- **Desk ids** are region-scoped like facts (`us-fl-miamidade.311`).
- **Targets**: app `MyAmericanDream` (`com.saksham45.myamericandream`), UI tests `MyAmericanDreamUITests`
  (sources `ios/Tests/Accessibility/`), generated from `ios/project.yml` with XcodeGen on the captain's Mac.

## 8. No secrets in the tree

The tree is laid out to go, unchanged, into the public repo `saksham-45/shellhacks-2026` when the captain
says so. Until then nothing touches that repo. Because it will be public:
- keys come from environment variables only (e.g. `GEMINI_API_KEY`), never files in the tree;
- `.env*` is ignored (only `.env.example`, with empty values, may exist) and excluded from snapshots;
- `tools/check_no_secrets.py` (a CI step) fails on Google keys (`AIza…`), `sk-…` keys, `ghp_/gho_…`
  tokens, private key blocks, and any `.env` file.

## 9. Local CI

`tools/ci.sh` runs, and prints a PASS/FAIL/SKIP line per step, exiting nonzero on any FAIL:
server pytest, tools pytest, string parity (`check_string_parity.py`: every `.xcstrings` key has es, en,
ht), fact coverage (`check_fact_coverage.py`: every card placeholder is in `fact_refs` and every ref is in
the ledger), no secrets, and `swift test` per package (SKIP when `swift` is not on PATH). Python venvs
(3.12) are created on first run in `server/.venv` and `tools/.venv`.

**Area hooks.** Any locked folder may ship an executable `ci-hook.sh` at its root (`research/ci-hook.sh`,
`content/ci-hook.sh`, `server/ci-hook.sh`, `ios/Packages/<Pkg>/ci-hook.sh`, …). `ci.sh` discovers every
one, runs each from its own directory, and reports it as its own step (`hook <path>`). A non-executable
hook is a FAIL. Hooks must be fast, offline by default, and touch only their own folder.

## 10. WORKFLOW

Plain folders, no version control, until the captain says otherwise. One tree:
`/workspace/myamericandream`. Each crewmate edits only its locked subfolder:

| Crewmate | Lock |
| --- | --- |
| Household | `ios/Packages/ADCore` |
| Language | `ios/Packages/ADLocale`, `ios/Packages/ADVoice` |
| Regions | `ios/Packages/ADCityPack`, `server/regionpacks/` |
| Agents | `server/` except `regionpacks/`, `ios/Packages/ADAgentsClient` |
| Research | `research/` |
| Content | `content/` |
| Access | `docs/accessibility.md`, `ios/Tests/Accessibility/` |
| Lead | everything else: `ios/App`, `ios/project.yml`, `ios/Packages/ADAccessibility`, `tools/`, `ARCHITECTURE.md`, `README.md` |

- A change needed outside your lock goes to that lock's owner; you do not make it.
- When a piece is ready: run `tools/ci.sh`; get a fresh adversarial review of your folder diff
  (`tools/diff_since_snapshot.sh <your-folder>`); myAD Access reviews the same folder diff for
  accessibility; then tell Lead.
- Lead integrates: reads `tools/diff_since_snapshot.sh <folder>` against the latest snapshot, runs
  `tools/ci.sh`, and takes a new snapshot with `tools/snapshot.sh`. That snapshot
  (`/workspace/myad-snapshots/<UTC stamp>/`, `latest` symlink) is the accepted integration point.
- Xcode and simulator runs happen on the captain's Mac, batched through Lead.

## 11. Conflicts and gaps between plans and spec

1. Spec's version-control, hosted-CI, per-crewmate worktree, and commit-author sections are suspended by the
   captain's order; replaced by locked folders, `tools/ci.sh`, and snapshots. (`/workspace/myad-wt/*` untouched.)
2. `mymiami-plan` puts Creole after es/en; the primary plan makes Kreyòl a third full surface. Primary wins: es/en/ht.
3. ADCore "holds no display strings" vs "each package ships a catalog": ADCore ships an empty `Localizable.xcstrings`.
4. Groceries: `mymiami-plan` puts demo-basket prices on the card; `mymiami-public-data` says keep grocery prices off
   until a real source answers; the primary plan requires the card. Decision: card exists; prices only as
   `demo`-status facts labeled demo, else `unsourced` + desk. Captain to confirm.
5. Power range: "a 2/2 held warm around $230" (mymiami-plan) vs "a 2/2 at 77–79° around $231" (public-data).
   Research reconciles; both are neighbor reports, never "this meter".
6. Every figure in the plans (rent lines, tolls, parking cap and stories, pedestrian totals, school phone,
   two-mile rule, tipping range) is unverified until Research ledgers it. None is written into code or content.
7. Spec lists `ADCityPack (+ MiamiPack)` in Swift; this skeleton keeps packs as data + adapters under
   `server/regionpacks/`, with ADCityPack as the generic protocol and resolver (offline fixtures can load
   the same manifests). Regions + Lead to confirm whether any adapter runs on-device.
8. "Data stays on the phone" vs agents that need the pin and person context: the server is stateless and stores
   nothing; the status word is sent only if the person chose to. Captain to confirm this reading.
9. Spec's fact schema lists `publisher` per fact and no `jurisdiction`; the ledger here has `jurisdiction` and
   keeps publisher in `sources.yaml`.
10. Locks leave `ios/Packages/ADAccessibility` unowned in the crew list; Lead owns its code, Access owns the standard.
11. Info.plist usage strings (microphone, speech) are English-only build settings; they need an
    `InfoPlist.xcstrings` with es/en/ht before shipping (Lead + Language).
12. The architect skill's multi-model arena was not run (speed order); the sketch comes from the plans, the
    interrupted run's packages, and the crew-agreed ADCore shapes.

## 12. Decisions log (Lead, 2026-09-25)

Accepted from Household (FM-MYAD-HH), these override §3 where they differ:
- ADCore's shared types (`Sources/ADCore/Shared/`) are the contract: id types, `Fact`, `FactValue` (ten typed cases, see 13.z), `FactStatus`, `Source`, `Desk`, `Card`, `FactLine`, `SourceLine`, `SpeakableParts`. Household's staged package replaces the ADCore stub wholesale.
- An unsourced fact has no public display value. Every `Card` names a `desk`.
- `FactRef`, `Card`, and `Desk` all use `RegionPackID` (defined in ADCore). ADCityPack imports it; no second pack-id type.
- Persistence: separate target `ADCoreSwiftData` behind `#if canImport(SwiftData)`, one versioned JSON row per household. The row carries a schema version and a test decodes an older version. Privacy scopes are enforced in ADCore's domain layer (`PrivacyPolicy`), never by storage.
- Wire format: every language in an agent/backend payload is a plain BCP-47 string (`Locale.Language.minimalIdentifier`, e.g. `"es"`, `"ht"`, `"hi"`), never the nested `Locale.Language` JSON. Pack ids on the wire are the `RegionPackID` string.
- String tables: one catalog per package named after its table (ADCore's keys use `table: "ADCore"`, file `ADCore.xcstrings`, loaded via `Bundle.module`). Language supplies es/ht for UI strings; Content writes card copy only. `tools/check_string_parity.py` scans every catalog in the tree.

Resolved gaps from §11:
- §11.4 Groceries: no price appears unless it is a ledger fact. Until a real source exists the card shows a `demo`-status fact (visibly labelled demo) or an unsourced outcome that names the desk.
- §11.7 Where adapters run: adapters run on the server (`server/regionpacks/`). The phone never calls ArcGIS directly. ADCityPack holds the `RegionPack` protocol, manifest types, and resolution, plus cached fixture answers for both demo pins so the demo works offline.
- **Demo-only waiver (Firstmate, FM-MYAD-DEMO-SHELL, 2026-09-25 7:07 PM ET), overrides §11.7 for the demo build only:** Fee Check, Listing Check and Address Check may call the Miami-Dade ArcGIS layers directly from the phone for the ShellHacks demo. Conditions: the fetcher stays injectable (`ParcelFetching` and its siblings), a 4 s race falls back to the timestamped cached answer for the demo address only, typed names and addresses never leave the device beyond the layer query and are never logged or cached, and owner names stay in memory only. After the demo, a server proxy in `server/regionpacks/` replaces the direct calls and this waiver is removed.
- §11.8 Data on the phone: the household lives on the phone. The server is stateless and stores nothing. A request carries only the pin and the fields that answer needs; a status word is sent only if that person chose to enter it.
- `RegionPackManifest` (ADCityPack, owner Regions) gains `level` (country|state|county|city), `boundary` (the layer and field that decide a pin is inside the pack), and a per-adapter `facts` list naming the ledger fact ids each adapter can produce. Pack membership for a pin comes from the server's result; the phone does no point-in-polygon.
- `FactValue.flag(Bool)` is approved as an eighth case for true yes/no facts (e.g. condo). Household adds it in ADCore; until then Regions uses `.verbatim` with the county's own wording.
- Plan lines are never copy. Where a plan and the ledger disagree the ledger wins (e.g. 111 NW 1st St: county parcel says built 1984, not the plan's "1925 building").
- Fixtures that go in the tree are minimized: no owner names, mailing addresses, or other personal data from parcel records, and no raw third-party HTML or page keys. Raw captures stay outside the tree.

## 13. Voice-first: one router, one intent contract (captain order 2026-09-25 5:26 PM ET)

Every screen, card and action is a typed value in ONE router. Touch, voice, App Intents/Siri, VoiceOver custom actions, Voice Control, and UI tests all call `Router.perform(_:)`. A control that does anything without going through the router is a bug. Nothing is touch-only or voice-only.

### 13.1 Package `ADRouter` (owner: Lead; pure Swift, builds and tests on Linux)
Depends on ADCore and ADLocale. ADAgentsClient depends on ADRouter to decode resolutions. ADVoice does NOT depend on ADRouter (it only produces transcripts and speaks).

```swift
public enum Destination: Hashable, Codable, Sendable {
    case household                          // the household and its week
    case person(PersonID)
    case addPerson
    case onboarding(OnboardingStep)         // OnboardingStep from ADCore
    case stage(PersonID, Stage)             // hero for that stage
    case card(CardID, person: PersonID?)
    case cards(CardFilter)                  // by desk, stage, or mode
    case desk(DeskID)                       // desk handoff: phone/address/hours come only from ledger facts
    case pin                                // choose between the two demo pins
    case settings
    case language
    case voice
}

public enum AppAction: Hashable, Codable, Sendable {
    case navigate(Destination)
    case back, home
    case readAloud(ReadTarget)              // .screen, .card(CardID), .step
    case stopSpeaking, repeatLast
    case nextStep, previousStep
    case callDesk(DeskID), openMap(DeskID)  // leave the app: always confirmed first (spoken yes/no or a button)
    case setSurfaceLanguage(SurfaceLanguage)
    case setThinkIn(SpokenLanguage)
    case answerOnboarding(OnboardingAnswer) // Household: every onboarding question answerable by voice
    case choose(ClarifyOptionID)            // answer to a clarifying question
    case setPin(PinID)
    case setMode(Mode)                      // tourist / "I live here now"
    case confirm(Bool)
}

public enum ActionSource: Sendable { case touch, voice, appIntent, voiceOver, uiTest }

@MainActor @Observable
public final class Router {
    public private(set) var path: [Destination]
    public private(set) var pendingClarification: Clarification?
    public private(set) var pendingConfirmation: AppAction?
    public func perform(_ action: AppAction, from source: ActionSource) -> ActionOutcome
}
```
- The router checks ADCore's `PrivacyPolicy` before every navigation. A destination the active person may not see (another person's papers, immigration cards in tourist mode) is refused with `ActionOutcome.refused(reason: StringKey)`, whatever the source.
- `ActionSource` exists only for the confirmation policy (for example, a voice `callDesk` needs a spoken "yes"). It is never logged or sent anywhere.
- Every outcome has a speakable confirmation (`SpeakableParts` from ADCore), so every step can be read aloud.

### 13.2 Intent contract
```swift
public struct Utterance: Codable, Sendable {
    public var text: String
    public var language: String             // BCP-47 of the sentence just spoken (from ADVoice), e.g. "es", "ht"
    public var context: RouteContext        // current destination, active PersonID, visible CardID; ids only
}

public struct IntentResolution: Codable, Sendable {
    public var action: AppAction?           // a destination arrives as .navigate
    public var grounding: Grounding?        // .card(CardID, facts: [FactRef]) or .desk(DeskID, reason: StringKey)
    public var confidence: Double           // 0...1
    public var clarification: Clarification?
    public var replyLanguage: String        // BCP-47; defaults to Utterance.language
}

public struct Clarification: Codable, Sendable {
    public var question: StringKey          // or verified card text; never free-form model prose
    public var options: [ClarifyOption]     // exactly 2 or 3
}
public struct ClarifyOption: Codable, Sendable, Identifiable {
    public var id: ClarifyOptionID
    public var label: StringKey
    public var action: AppAction
}

public protocol CommandMatcher: Sendable {  // on-device, deterministic, no network
    func match(_ u: Utterance) -> IntentResolution?
}
```
Resolution order:
1. The on-device `CommandMatcher` handles navigation and control verbs ("go back", "read this", "next step", "call the desk", "switch to Spanish", "yes", "the second one", option labels, card utterances). A match returns confidence 1.0.
2. Anything else goes to Agents' `POST /v1/ask`. It returns an `IntentResolution`, and nothing else: never a free-form answer. Content shown to the person is a card whose facts are all ledger `FactRef`s, or a desk handoff. The verifier drops anything unsourced.
3. Policy: confidence ≥ 0.75 performs the action. From 0.40 to 0.75, or ambiguous, it asks ONE clarifying question with 2 or 3 options, spoken and shown as buttons. Below 0.40 it offers the closest desk and says it doesn't have this. The phone applies the policy, so the server can't bypass it.
4. Offline or server error: the matcher still works, and open questions get "I can't look that up right now" plus the offices card.

Wire format: `Destination`, `AppAction`, and `IntentResolution` encode as tagged JSON (`{"type":"card","card_id":"…","person_id":null}`), snake_case keys, BCP-47 language strings, and ids as plain strings. Golden JSON examples live in `contracts/intent/*.json` (owner Lead). Swift tests (ADRouter, ADAgentsClient) and server tests (pydantic) both decode every golden file, so the two sides can't drift. `/v1/ask` requests carry only the utterance, its language, route-context ids, and the active person's stage and mode. They never include papers or another person's data.

### 13.3 Who supplies what
- **Language (ADVoice, ADLocale):** speech in, returning a transcript plus a detected BCP-47 language; speech out that follows `replyLanguage`. The command lexicon lives in ADLocale as `Commands/{es,en,ht}.json` (command key to phrases), exposed as `CommandLexicon`; ADRouter's matcher reads it. **Creole rule:** if no Haitian Creole voice is available, ADVoice returns `.unavailable`, the UI shows a clear Creole notice, and Creole text is NEVER read with a Spanish or English voice. The chosen STT/TTS path comes from Language's report.
- **Agents (server, ADAgentsClient):** `POST /v1/ask` returns `IntentResolution` as specified above; pydantic models mirror the golden files. ADAgentsClient decodes it into ADRouter types.
- **Content (content/):** every card declares `utterances: {es: [...], en: [...], ht: [...]}` (natural ways a person asks for that card) and optional `actions` (for example `call_desk`). `tools/build_content_bundle.py` (Lead) compiles cards into the app bundle for on-device matching.
- **Household (ADCore):** `OnboardingStep` and `OnboardingAnswer` are typed so each of the four questions can be answered by voice (choices plus free text where needed; the status word stays optional and is never asked by voice unless the person offers it).
- **Access (ios/Tests/Accessibility):** no-touch flow tests for onboarding, the hero card, desk handoff, and language switch. Pure-Swift script tests drive `Utterance` through the matcher and router on Linux; XCUITests use `-myadVoiceStub` plus `-myadVoiceScript <name>` to inject transcripts with no taps.
- **Lead (ios/App):** App Intents and App Shortcuts for the top actions (open this week, read my next step, call a desk, open a card, switch language). Each one builds an `AppAction` and calls the router. VoiceOver custom actions and Voice Control input labels come from the same actions and utterances. The test UI has a mic button on every screen and hands-free flows for onboarding, the hero card, desk handoff, and language switch.

### 13.x Decisions from the Intel room (2026-09-25)
- Household week endpoint takes `address` plus optional `lat`/`lon` from the phone. With coordinates the server skips geocoding and records `method=device_coords` in `basis`. Coordinates and address are request-only: never logged, never stored (server stays stateless). `/v1/ask` takes no pin and runs no adapters; it only resolves where to go.
- `tools/build_content_bundle.py` writes ONE canonical compiled bundle, `contracts/content/cards.json` (plus `contracts/content/cards.schema.json`), and copies it byte-identical into `ios/App/Resources/Generated/cards.json`. The server reads the `contracts/` copy (path overridable by env `MYAD_CARDS_BUNDLE`). The bundle is checked in; `ci.sh` rebuilds it and fails if the checked-in copy is stale.
- `research/topics.yaml` is the only topic vocabulary. Facts, pack manifests, cards and the bundle may use only its slugs; each owner's validator fails on unknown tags. `municipality` is a topic.
- Desk handoff reads only `<desk-id>.{name,phone,url,address,hours,languages}` ledger facts. Desk ids are final only once Research posts them.

### 13.y Decisions from the Build room (2026-09-25)
- `AppAction.openMap` takes a `MapTarget`: `.desk(DeskID)` or `.place(FactRef)`, where the fact's value must be `.place`. Anything else is refused. Both need a spoken or tapped yes before leaving the app. `callDesk` stays desk-only.
- The canonical command keys live in `contracts/intent/command_keys.json`. ADLocale's `CommandLexicon` files must have exactly these keys (Language's ci-hook checks this), and ADRouter maps them to actions. Adding a key means editing that file first.
- `PinID` and `CardFilter` live in ADCore. Filters are applied only through the privacy and tourist rules. ADRouter imports them and has no copies of its own.
- There are no weekday strings in ADCore. Day names and joiners belong to ADLocale.
- Voice accessibility, all required:
  - With `-myadVoiceStub -myadVoiceScript <name>`, the script starts at launch with no tap.
  - Magic Tap (the VoiceOver two-finger double-tap) toggles listening on every screen.
  - A clarification or leave-app confirmation is spoken aloud and moves VoiceOver focus to the question. It can be answered by voice (yes, no, or an ordinal) or with 44pt buttons, and it never times out.
  - A screen change made by voice posts a VoiceOver screen announcement in the surface language.
  - An ADVoice `.unavailable` notice is shown on screen and also posted as a VoiceOver announcement.

### 13.z Decisions for Agents' harness questions (2026-09-25)
- **FactValue, final list (ADCore wins, ten cases):** `text(String, language)`, `code(String)` (never translated: folio, district id, grade span, member and route names), `codes([String])`, `phone(digits)`, `date`, `money(amount, currency)`, `quantity(Decimal, unit)` (year built is `quantity(1984, unit: "year")`), `weekdays`, `place`, `flag(Bool)`. There is no `number`, `url`, or `verbatim`. A "none recorded" value is a `FactOutcome`, never a sentinel like 0. Wire tags are exactly those names in snake_case.
- **FactRef wire JSON:** `{"pack_id": "us-fl-miami", "fact_id": "us-fl-miami.trash.day"}`. ADCore adds CodingKeys; every producer uses these two keys.
- **FactOutcome** gains `unavailable(desk)` for a source that exists but could not be reached. That is different from `unsourced`, which means no source exists. The wire never carries a nullable value: an outcome is a tagged union.
- **/v1 wire additions:** each response carries a typed `facts` map keyed by fact_id, `is_demo` per fact and `has_demo` per response (from ledger status `demo`), desk handoff objects built only from `<desk-id>.*` facts, and a random per-request `request_id` that is echoed, never stored, and never tied to a household. Agents owns the `/v1` golden files under `contracts/v1/`; Lead reviews them.
- **Logging:** the server never logs utterance text, addresses, coordinates, or request or response bodies. It logs only request_id, route, status, latency and counts.
- **Jurisdiction beats plan text:** a figure applies only inside the jurisdiction its ledger fact names. City of Miami rent lines never appear for an unincorporated pin, and the verifier drops them. The unincorporated pin uses Miami-Dade County's own table once Research has sourced it; until then the card names the county housing desk.
- **Cross-folder reads:** anyone may read `contracts/` and another package's public API. The server imports Regions' runtime from `server/regionpacks` read-only through its documented entry points, and Regions' tests run only in Regions' hook.
- **/v1/ask stays pinless:** `RouteContext` does not get `pack_ids`, because they reveal where the household lives. `navigate(card)` plus `Grounding.card(facts:)` pointing at adapter fact ids is enough. The destination screen gets the pin-specific values from household-week. Places use `openMap(.place(FactRef))`.
- **Versions:** pin exact versions in the server lockfile. Use google-adk 2.10.0 only if the full server suite passes on it, otherwise 2.9.2. Model ids come from env, with defaults set to the current stable ids in Google's docs. CI never calls a model (stub only).

### 13.w String catalog rules (2026-09-25)
- `tools/check_string_parity.py` is Language's merged rule set. It covers missing languages, empty values, untranslated copies of the English, placeholders, verbatim values, needs_review, raw keys, accessibility labels, hints and Voice Control phrases, and plural groups without an `other` case. Its tests and fixtures are in `tools/tests/`.
- Every package catalog is named after its table (`<Package>.xcstrings`). Owners rename their `Localizable.xcstrings` in their own folders. The app target alone keeps `Localizable`. Once the renames land, the checker enforces the rule.
- To mark a string that must not be translated, use comment markers (`[name]`, `[phone]`, `[number]`, `[do-not-translate]`, `[same:es]`, `[same:ht]`), not Xcode's "Don't translate".
- A missing `en` always fails, because keys are semantic. A value with no state counts as unreviewed. needs_review is only reported on normal runs and fails under `--release`. A non-blocking release-report step comes later. Language's own ci-hook will carry the Spain-only glossary check.
