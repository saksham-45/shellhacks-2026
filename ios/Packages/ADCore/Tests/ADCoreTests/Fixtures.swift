import Foundation
import Testing
@testable import ADCore

// Test fixtures only. Every value here is an obvious placeholder (example.org, zeros,
// "Test ..."), not a real fact, and there are no keys or tokens.

struct TestLenses: OriginLensResolving {
    func lenses(for origin: Origin) -> Set<OriginLens> {
        switch origin.countryCode {
        case "CU": [.latinAmerica]
        case "IN": [.leftDriving]
        default: []
        }
    }
}

let policy = HeroPolicy(lensResolver: TestLenses())
let testDesk: DeskID = "test-pack.desk"
let testPack: RegionPackID = "test-pack"
let es = Locale.Language(identifier: "es")
let en = Locale.Language(identifier: "en")
let hi = Locale.Language(identifier: "hi")
let ht = Locale.Language(identifier: "ht")
let testPin = Pin(latitude: 0, longitude: 0, address: "test address")

func key(_ k: String) -> StringKey { StringKey(key: k, table: "Test") }

func card(_ id: String, _ topic: HeroTopic?, subject: CardSubject = .person,
          modes: Set<Mode> = [.resident], immigration: Bool = false,
          lenses: Set<OriginLens> = [], desk: DeskID = testDesk, facts: [FactID] = []) -> Card {
    try! Card(id: CardID(rawValue: id), regionPack: testPack, subject: subject,
              titleKey: key("card.\(id).title"), heroTopic: topic, modes: modes,
              isImmigrationContent: immigration, lenses: lenses, desk: desk, facts: facts)
}

/// One person card per hero topic, id == topic name.
let catalogOnePerTopic: [Card] = HeroTopic.allCases.map { topic in
    card(topic.rawValue, topic, modes: Mode.touristHeroTopics.contains(topic) ? [.resident, .tourist] : [.resident])
}

func person(_ name: String = "A", age: Int? = 30, origin: String? = nil,
            goal: Goal = .arrive, thinkIn: Locale.Language = es) -> Person {
    Person(displayName: name, age: age, origin: origin.map(Origin.init(countryCode:)), thinkIn: thinkIn, goal: goal)
}

func household(_ people: [Person], pin: Pin? = testPin, shared: SharedHousehold = SharedHousehold()) -> Household {
    try! Household(pin: pin, homeLanguage: es, shared: shared, people: people)
}

let placeholderSource = Source(id: "test-source", url: URL(string: "https://example.org/source")!,
                               publisher: "Test Publisher")
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func verifiedFact(_ id: String, retrievedAt: Date = t0, checkEveryDays: Int? = nil) throws -> Fact {
    try Fact(id: FactID(rawValue: id), value: .phone(digits: "0000000000"), source: placeholderSource,
             quote: "placeholder quote", quoteLanguage: en, retrievedAt: retrievedAt,
             status: .verified, checkEveryDays: checkEveryDays)
}

struct TestResolver: FactResolving {
    var outcomes: [FactID: FactOutcome]
    func outcome(for id: FactID) -> FactOutcome? { outcomes[id] }
}

func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(text.utf8))
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
                           "missing fixture \(name)")
    return try Data(contentsOf: url)
}
