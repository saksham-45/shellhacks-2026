import Foundation
import Testing
@testable import ADCore

@Suite("Facts, cards, source line, speakable parts")
struct FactCardTests {
    @Test func verifiedAndStaleRequireEvidence() {
        let id: FactID = "f"
        #expect(throws: FactError.missingSource(id)) {
            try Fact(id: id, value: .phone(digits: "0"), source: nil, quote: "q", quoteLanguage: en, retrievedAt: t0, status: .verified)
        }
        #expect(throws: FactError.missingQuote(id)) {
            try Fact(id: id, value: .phone(digits: "0"), source: placeholderSource, quote: nil, quoteLanguage: nil, retrievedAt: t0, status: .stale)
        }
        #expect(throws: FactError.missingRetrievedAt(id)) {
            try Fact(id: id, value: .phone(digits: "0"), source: placeholderSource, quote: "q", quoteLanguage: en, retrievedAt: nil, status: .verified)
        }
        #expect(throws: FactError.missingValue(id)) {
            try Fact(id: id, value: nil, source: nil, quote: nil, quoteLanguage: nil, retrievedAt: nil, status: .demo)
        }
        #expect(throws: Never.self) {
            try Fact(id: id, value: nil, source: nil, quote: nil, quoteLanguage: nil, retrievedAt: nil, status: .unsourced)
        }
    }

    // Review finding 1: synthesized Decodable bypassed the validating init.
    @Test func verifiedFactWithoutEvidenceFailsToDecode() {
        let bad = #"{"id":"test-pack.x","status":"verified","value":{"kind":"flag","value":true}}"#
        #expect(throws: FactError.missingSource("test-pack.x")) { try decode(Fact.self, bad) }
    }

    @Test func factRoundTripsWithQuoteLanguageAsBCP47() throws {
        let f = try Fact(id: "test-pack.q", value: .text("placeholder", language: ht), source: placeholderSource,
                         quote: "placeholder", quoteLanguage: Locale.Language(identifier: "es-419"),
                         retrievedAt: t0, status: .verified, checkEveryDays: 7)
        let text = try json(f)
        #expect(text.contains("\"quoteLanguage\":\"es-419\"") && text.contains("\"language\":\"ht\""))
        #expect(try decode(Fact.self, text) == f)
    }

    // Review finding 1 backstop: a fact lacking its evidence never renders as shown.
    @Test func lineBackstopHandsUnevidencedFactToDesk() {
        let forged = Fact(unchecked: "forged", value: .phone(digits: "0"), source: nil, quote: nil,
                          quoteLanguage: nil, retrievedAt: nil, status: .verified, checkEveryDays: nil)
        let c = card("c", nil, facts: ["forged"])
        let r = TestResolver(outcomes: ["forged": .fact(forged)])
        #expect(c.factLines(using: r, asOf: t0) == [.handedToDesk("forged", desk: testDesk)])
        #expect(c.sourceLine(using: r, asOf: t0) == .noSource(desk: testDesk))
    }

    @Test func verifiedGoesStaleAfterCheckEvery() throws {
        let f = try verifiedFact("f", retrievedAt: t0, checkEveryDays: 7)
        #expect(f.status(asOf: t0.addingTimeInterval(6 * 86_400)) == .verified)
        #expect(f.status(asOf: t0.addingTimeInterval(8 * 86_400)) == .stale)
    }

    @Test func unsourcedValueNeverDisplays() throws {
        let f = try Fact(id: "u", value: .quantity(1, unit: "test"), source: nil, quote: nil,
                         quoteLanguage: nil, retrievedAt: nil, status: .unsourced)
        #expect(f.displayValue == nil)
        let c = card("c", nil, facts: ["u"])
        let r = TestResolver(outcomes: ["u": .fact(f)])
        #expect(c.factLines(using: r, asOf: t0) == [.handedToDesk("u", desk: testDesk)])
        #expect(c.sourceLine(using: r, asOf: t0) == .noSource(desk: testDesk))
    }

    @Test func unsourcedOutcomeNamesItsDesk() {
        let desk = Desk(id: "test-pack.311", regionPack: testPack)
        let c = card("c", nil, facts: ["x", "missing"])
        let r = TestResolver(outcomes: ["x": .unsourced(desk: desk)])
        #expect(c.factLines(using: r, asOf: t0) == [.handedToDesk("x", desk: "test-pack.311"), .handedToDesk("missing", desk: testDesk)])
        #expect(c.sourceLine(using: r, asOf: t0) == .noSource(desk: testDesk))
    }

    @Test func cardWithNoFactsSaysNoSourceAndNamesDesk() {
        let line = card("rules", nil).sourceLine(using: TestResolver(outcomes: [:]), asOf: t0)
        #expect(line == .noSource(desk: testDesk))
        #expect(line.labelKey == StringKey(key: "source_line.no_source", table: "ADCore"))
    }

    @Test func notApplicableIsAnOutcomeWithRegionPackIDRef() {
        let ref = FactRef(regionPackID: "test-city-pack", ledgerFactID: "test-city-pack.trash")
        let reason = key("not_applicable.hauled_by_city")
        let c = card("trash", nil, subject: .household, facts: ["county-trash"])
        let r = TestResolver(outcomes: ["county-trash": .notApplicable(reason: reason, deferTo: ref)])
        #expect(c.factLines(using: r, asOf: t0) == [.notApplicable("county-trash", reason: reason, deferTo: ref)])
        #expect(ref.regionPackID == RegionPackID(rawValue: "test-city-pack"))
    }

    @Test func sourcedLineUsesOldestRetrieval() throws {
        let old = try verifiedFact("a", retrievedAt: t0)
        let new = try verifiedFact("b", retrievedAt: t0.addingTimeInterval(86_400))
        let demo = try Fact(id: "d", value: .money(amount: 1, currency: "USD"), source: nil, quote: nil,
                            quoteLanguage: nil, retrievedAt: nil, status: .demo)
        let c = card("c", nil, facts: ["b", "a", "d"])
        let r = TestResolver(outcomes: ["a": .fact(old), "b": .fact(new), "d": .fact(demo)])
        #expect(c.sourceLine(using: r, asOf: t0) == .sourced([placeholderSource], lastChecked: t0))
        #expect(c.factLines(using: r, asOf: t0).last == .shown(demo, status: .demo))
    }

    @Test func everyFactValueKindRoundTrips() throws {
        let values: [FactValue] = [
            .text("placeholder", language: es), .phone(digits: "0000000000"), .date(t0),
            .money(amount: Decimal(string: "0.01")!, currency: "USD"), .quantity(2, unit: "mi"),
            .weekdays([.tuesday, .friday]),
            .place(Place(name: "Test School", coordinate: Coordinate(latitude: 0, longitude: 0), address: "test")),
            .flag(true), .flag(false),
        ]
        for value in values {
            #expect(try decode(FactValue.self, try json(value)) == value)
        }
    }

    @Test func flagDecodesFromLiteralJSONFixture() throws {
        #expect(try decode(FactValue.self, #"{"kind":"flag","value":true}"#) == .flag(true))
        let values = try JSONDecoder().decode([FactValue].self, from: try fixture("fact-values.json"))
        #expect(values.contains(.flag(false)))
        #expect(values.contains(.weekdays([.tuesday, .friday])))
        #expect(FactValue.flag(true).displayKey == StringKey(key: "fact.flag.yes", table: "ADCore"))
        #expect(FactValue.flag(false).displayKey == StringKey(key: "fact.flag.no", table: "ADCore"))
        #expect(FactValue.phone(digits: "0").displayKey == nil)
    }

    // Review finding 9: Card decoding bypassed keyFact defaulting and validation.
    @Test func cardDecodeAppliesDefaultsAndValidates() throws {
        let minimal = #"{"id":"c","regionPack":"test-pack","subject":"person","desk":"test-pack.desk","facts":["f1","f2"]}"#
        let c = try decode(Card.self, minimal)
        #expect(c.keyFact == "f1" && c.modes == [.resident] && !c.isImmigrationContent)
        #expect(c.titleKey == StringKey(key: "card.c.title", table: "Cards"))
        #expect(throws: CardError.keyFactNotOnCard("c", "f9")) {
            try decode(Card.self, #"{"id":"c","regionPack":"p","subject":"person","desk":"d","facts":["f1"],"keyFact":"f9"}"#)
        }
        #expect(throws: CardError.emptyDesk("c")) {
            try decode(Card.self, #"{"id":"c","regionPack":"p","subject":"person","desk":" "}"#)
        }
        #expect(try decode(Card.self, try json(c)) == c)
    }

    @Test func everyCardYieldsNonEmptySpeakableParts() throws {
        let fact = try verifiedFact("v")
        let r = TestResolver(outcomes: [
            "v": .fact(fact), "u": .unsourced(desk: Desk(id: "named", regionPack: testPack)),
            "na": .notApplicable(reason: key("na"), deferTo: nil),
            "flag": .fact(try Fact(id: "flag", value: .flag(true), source: placeholderSource, quote: "q",
                                   quoteLanguage: en, retrievedAt: t0, status: .verified)),
        ])
        let catalog = catalogOnePerTopic + [
            card("sourced", nil, facts: ["v"]), card("unsourced", nil, facts: ["u"]),
            card("not-applicable", nil, subject: .household, facts: ["na"]),
            card("unknown-fact", nil, facts: ["nope"]), card("no-facts", nil), card("condo", nil, facts: ["flag"]),
        ]
        for c in catalog {
            let parts = c.speakableParts(using: r, asOf: t0)
            #expect(!parts.titleKey.key.isEmpty && !parts.titleKey.table.isEmpty, "\(c.id)")
            #expect(!parts.desk.rawValue.isEmpty, "\(c.id)")
            #expect(c.facts.isEmpty || parts.keyFact != nil, "\(c.id)")
        }
        let sourced = card("sourced", nil, facts: ["v"]).speakableParts(using: r, asOf: t0)
        #expect(sourced.sourcePublisher == "Test Publisher" && sourced.retrievedAt == t0)
    }
}
