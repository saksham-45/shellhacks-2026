import Foundation
import ADCore
import ADLocale
@testable import ADRouter

// TEST-ONLY data. The Spanish and Creole phrases below exist only to drive tests; the shipping
// lexicon is myAD Language's `CommandLexicon` (ADLocale). No real people, facts, or phone numbers.

enum Paths {
    /// <root>/contracts/intent, found from this file's location.
    static var intent: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // ADRouter
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // root
            .appendingPathComponent("contracts/intent")
    }
}

let testLexicon = InMemoryCommandLexicon([
    "en": [
        "back": ["go back", "back"], "home": ["home", "go home"], "read_this": ["read this", "read it"],
        "stop": ["stop"], "repeat": ["repeat", "say it again"], "next_step": ["next step"],
        "previous_step": ["previous step"], "call_desk": ["call the desk", "call them"], "open_map": ["open the map"],
        "switch_language_es": ["switch to spanish"], "switch_language_en": ["switch to english"],
        "switch_language_ht": ["switch to creole"], "switch_language_pt": ["switch to portuguese"],
        "switch_language_fr": ["switch to french"], "switch_language_ar": ["switch to arabic"],
        "switch_language_zh": ["switch to chinese"], "switch_language_ru": ["switch to russian"],
        "switch_language_tl": ["switch to tagalog"], "switch_language_vi": ["switch to vietnamese"],
        "yes": ["yes"], "no": ["no"],
        "ordinal_first": ["the first one", "first"], "ordinal_second": ["the second one", "second"],
        "ordinal_third": ["the third one", "third"],
    ],
    "es": [
        "back": ["atrás", "regresar"], "home": ["inicio"], "read_this": ["léelo", "lee esto"], "stop": ["para", "detente"],
        "repeat": ["repite"], "next_step": ["siguiente paso"], "previous_step": ["paso anterior"],
        "call_desk": ["llama a la oficina", "llámalos"], "open_map": ["abre el mapa"],
        "switch_language_es": ["cambia a español"], "switch_language_en": ["cambia a inglés"],
        "switch_language_ht": ["cambia a criollo"], "switch_language_pt": ["cambia a portugués"],
        "switch_language_fr": ["cambia a francés"], "switch_language_ar": ["cambia a árabe"],
        "switch_language_zh": ["cambia a chino"], "switch_language_ru": ["cambia a ruso"],
        "switch_language_tl": ["cambia a tagalo"], "switch_language_vi": ["cambia a vietnamita"],
        "yes": ["sí"], "no": ["no"],
        "ordinal_first": ["la primera", "el primero"], "ordinal_second": ["la segunda", "el segundo"],
        "ordinal_third": ["la tercera", "el tercero"],
    ],
    "ht": [
        "back": ["tounen"], "home": ["akèy"], "read_this": ["li sa a"], "stop": ["kanpe"], "repeat": ["repete"],
        "next_step": ["pwochen etap"], "previous_step": ["etap anvan"], "call_desk": ["rele biwo a"],
        "open_map": ["louvri kat la"], "switch_language_es": ["pase an panyòl"], "switch_language_en": ["pase an angle"],
        "switch_language_ht": ["pase an kreyòl"], "switch_language_pt": ["pase an pòtigè"],
        "switch_language_fr": ["pase an franse"], "switch_language_ar": ["pase an arab"],
        "switch_language_zh": ["pase an chinwa"], "switch_language_ru": ["pase an ris"],
        "switch_language_tl": ["pase an tagalog"], "switch_language_vi": ["pase an vyetnamyen"],
        "yes": ["wi"], "no": ["non"],
        "ordinal_first": ["premye a"], "ordinal_second": ["dezyèm lan"], "ordinal_third": ["twazyèm lan"],
    ],
])

/// Label text for tests: goal names and card titles in three languages; verbatim table passes through.
struct TestLabels: LabelTextResolving {
    let table: [String: [String: String]] = [
        "goal.study": ["en": "study", "es": "estudiar", "ht": "etidye"],
        "goal.arrive": ["en": "arrive", "es": "llegar", "ht": "rive"],
        "goal.work": ["en": "work", "es": "trabajar", "ht": "travay"],
        "goal.reunite": ["en": "reunite with family", "es": "reunirme con mi familia", "ht": "rejwenn fanmi"],
        "goal.visit": ["en": "visit", "es": "visitar", "ht": "vizite"],
        "goal.getThroughWeek": ["en": "get through this week", "es": "pasar esta semana", "ht": "pase semèn sa a"],
        "card.tolls.title": ["en": "tolls", "es": "peajes", "ht": "peyaj"],
        "card.license-checklist.title": ["en": "license checklist", "es": "licencia", "ht": "lisans"],
    ]
    func text(for key: StringKey, language: String) -> String? {
        if key.table == RouterText.verbatimTable { return key.key }
        return table[key.key]?[String(language.prefix(2))]
    }
}

struct NoLenses: OriginLensResolving {
    func lenses(for origin: Origin) -> Set<OriginLens> { [] }
}

/// Test fact resolver: one place fact, one phone-kind fact (placeholder digits), nothing else.
struct TestFacts: FactResolving {
    static let placeID: FactID = "test.place.example"
    static let notPlaceID: FactID = "test.desk.phone"
    func outcome(for id: FactID) -> FactOutcome? {
        switch id {
        case Self.placeID:
            let place = Place(name: "Example Place", coordinate: Coordinate(latitude: 0, longitude: 0))
            return (try? Fact(id: id, value: .place(place), source: nil, quote: nil, quoteLanguage: nil,
                              retrievedAt: nil, status: .demo)).map(FactOutcome.fact)
        case Self.notPlaceID:
            return (try? Fact(id: id, value: .phone(digits: "0000000000"), source: nil, quote: nil, quoteLanguage: nil,
                              retrievedAt: nil, status: .demo)).map(FactOutcome.fact)
        default:
            return nil
        }
    }
}

@MainActor
final class RecordingEffects: RouterEffects {
    var spoken: [ReadContent] = []
    var exits: [AppExit] = []
    var stops = 0
    var households: [Household?] = []
    var languageChanges: [(SurfaceLanguage, SpokenLanguage)] = []
    var outcomes: [(AppAction?, ActionOutcome, ActionSource, Bool)] = []

    func speak(_ content: ReadContent, language: String) { spoken.append(content) }
    func stopSpeaking() { stops += 1 }
    func leaveApp(_ exit: AppExit) { exits.append(exit) }
    func householdChanged(_ household: Household?) { households.append(household) }
    func languagesChanged(surface: SurfaceLanguage, thinkIn: SpokenLanguage) { languageChanges.append((surface, thinkIn)) }
    func didPerform(_ action: AppAction?, outcome: ActionOutcome, source: ActionSource, screenChanged: Bool, language: String) {
        outcomes.append((action, outcome, source, screenChanged))
    }
}

enum Fixture {
    static let desk311: DeskID = "test.desk.311"
    static let deskDSO: DeskID = "test.desk.dso"
    static let kendall: PinID = "kendall"
    static let downtown: PinID = "downtown"

    /// Placeholder coordinates (0,0): test values, not a geocode.
    static let pins = [
        PinChoice(id: kendall, label: RouterText.verbatim("11200 SW 137th Ave, Miami, FL 33186"),
                  pin: Pin(latitude: 0, longitude: 0, address: "11200 SW 137th Ave, Miami, FL 33186")),
        PinChoice(id: downtown, label: RouterText.verbatim("111 NW 1st St, Miami, FL 33128"),
                  pin: Pin(latitude: 0, longitude: 0, address: "111 NW 1st St, Miami, FL 33128")),
    ]

    static func card(_ id: CardID, subject: CardSubject = .person, topic: HeroTopic? = nil, modes: Set<Mode> = [.resident],
                     immigration: Bool = false, desk: DeskID = desk311, facts: [FactID] = []) -> Card {
        try! Card(id: id, regionPack: "us", subject: subject, heroTopic: topic, modes: modes,
                  isImmigrationContent: immigration, desk: desk, facts: facts)
    }

    static let catalog: [Card] = [
        card("license-checklist", topic: .license, desk: deskDSO, facts: ["us-fl.license.i20-required"]),
        card("transit", topic: .transit),
        card("tolls", topic: .tolls, facts: ["us-fl-miamidade.tolls.dolphin-97-ave.sunpass"]),
        card("notario-warning", topic: .scam, modes: [.resident, .tourist]),
        card("bed-tonight", topic: .bed),
        card("status-word", topic: .statusWord, immigration: true),
        card("tipping", topic: .tipping, modes: [.tourist]),
        card("offices", subject: .household, modes: [.resident, .tourist]),
        card("trash-week", subject: .household),
    ]

    static let cardUtterances = [
        CardUtterances(cardID: "tolls", phrases: ["en": ["tolls", "the toll"], "es": ["el peaje", "peajes"], "ht": ["peyaj"]]),
        CardUtterances(cardID: "license-checklist", phrases: ["en": ["license"], "es": ["licencia"], "ht": ["lisans"]]),
        CardUtterances(cardID: "transit", phrases: ["en": ["bus", "school bus"], "es": ["guagua"], "ht": ["bis"]]),
        CardUtterances(cardID: "bed-tonight", phrases: ["en": ["a bed", "school bus shelter"], "es": ["cama"], "ht": ["kabann"]]),
        CardUtterances(cardID: "trash-week", phrases: ["en": ["school bus route"], "es": ["basura"], "ht": ["fatra"]]),
    ]

    static let matcher = LexiconCommandMatcher(lexicon: testLexicon, cards: cardUtterances, labels: TestLabels())

    /// A student (20, stage movement), a parent (58), and a child (8). Example names only.
    static func household() -> (Household, student: PersonID, parent: PersonID, child: PersonID) {
        var student = Person(displayName: "Example Student", age: 20, origin: Origin(countryCode: "IN"),
                             thinkIn: Locale.Language(identifier: "hi"), goal: .study)
        try! student.setStage(.movement)
        var parent = Person(displayName: "Example Parent", age: 58, origin: Origin(countryCode: "CU"),
                            thinkIn: Locale.Language(identifier: "es"), goal: .reunite)
        parent.papers = [Paper(kind: "passport", isImmigrationDocument: true)]
        let child = Person(displayName: "Example Child", age: 8, thinkIn: Locale.Language(identifier: "es"), goal: .arrive)
        let h = try! Household(pin: pins[0].pin, people: [student, parent, child])
        return (h, student.id, parent.id, child.id)
    }

    @MainActor
    static func router(household: Household?, effects: RecordingEffects, surface: SurfaceLanguage = .en) -> Router {
        Router(household: household, catalog: catalog, surface: surface, pins: pins, facts: TestFacts(),
               lensResolver: NoLenses(), matcher: matcher,
               config: RouterConfig(officesCard: "offices", fallbackDesk: desk311), effects: effects)
    }
}

/// JSON compared as values (key order and number spelling do not matter).
indirect enum JSONValue: Equatable, Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
}
