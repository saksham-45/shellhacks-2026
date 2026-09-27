import Foundation
import Testing
@testable import ADCore

/// ARCHITECTURE.md §13.z: final FactValue list, FactRef wire keys, FactOutcome.unavailable.
@Suite("Fact wire contract")
struct FactWireTests {
    /// Exhaustive on purpose: adding an eleventh case fails to compile here.
    static func caseName(_ v: FactValue) -> String {
        switch v {
        case .text: "text"
        case .code: "code"
        case .codes: "codes"
        case .phone: "phone"
        case .date: "date"
        case .money: "money"
        case .quantity: "quantity"
        case .weekdays: "weekdays"
        case .place: "place"
        case .flag: "flag"
        }
    }

    static let oneOfEach: [FactValue] = [
        .text("placeholder", language: ht), .code("00-0000-000-0000"), .codes(["Test Route B", "Test Route A"]),
        .phone(digits: "0000000000"), .date(t0), .money(amount: Decimal(string: "0.01")!, currency: "USD"),
        .quantity(1984, unit: "year"), .weekdays([.tuesday]),
        .place(Place(name: "Test Place", coordinate: Coordinate(latitude: 0, longitude: 0))), .flag(true),
    ]

    @Test func exactlyTenCasesAndTagsAreCaseNames() throws {
        #expect(Self.oneOfEach.count == 10)
        for value in Self.oneOfEach {
            let object = try JSONSerialization.jsonObject(with: Data(try json(value).utf8)) as? [String: Any]
            #expect(object?["kind"] as? String == Self.caseName(value))
            #expect(try decode(FactValue.self, try json(value)) == value)
        }
        #expect(Set(Self.oneOfEach.map(Self.caseName)).count == 10)
        for gone in ["number", "url", "verbatim"] {
            #expect(throws: DecodingError.self) { try decode(FactValue.self, #"{"kind":"\#(gone)","value":"x"}"#) }
        }
    }

    @Test func codeValuesRoundTripAndStayVerbatim() throws {
        #expect(try json(FactValue.code("00-0000-000-0000")) == #"{"code":"00-0000-000-0000","kind":"code"}"#)
        #expect(try json(FactValue.codes(["Test Route B", "Test Route A"])) == #"{"codes":["Test Route B","Test Route A"],"kind":"codes"}"#)
        let fixtures = try JSONDecoder().decode([FactValue].self, from: try fixture("fact-values.json"))
        #expect(fixtures.contains(.code("00-0000-000-0000")))
        // Source order kept: ADCore neither sorts nor joins; ADLocale owns joiners.
        #expect(fixtures.contains(.codes(["Test Route B", "Test Route A"])))
        #expect(FactValue.codes(["Test Route B", "Test Route A"]).verbatimCodes == ["Test Route B", "Test Route A"])
        #expect(FactValue.code("K-5").verbatimCodes == ["K-5"])
        // Never localized: no StringKey for codes.
        #expect(FactValue.code("K-5").displayKey == nil && FactValue.codes(["A"]).displayKey == nil)
        #expect(FactValue.text("x", language: en).verbatimCodes == nil && FactValue.flag(true).verbatimCodes == nil)
    }

    @Test func yearBuiltIsQuantityWithUnitYear() throws {
        let fixtures = try JSONDecoder().decode([FactValue].self, from: try fixture("fact-values.json"))
        #expect(fixtures.contains(.quantity(1984, unit: "year")))
        #expect(try json(FactValue.quantity(1984, unit: "year")) == #"{"amount":1984,"kind":"quantity","unit":"year"}"#)
    }

    @Test func speakablePartsMarkCodesToReadAsIs() throws {
        let fact = try Fact(id: "test-pack.parcel.folio", value: .codes(["Test Route B", "Test Route A"]),
                            source: placeholderSource, quote: "placeholder quote", quoteLanguage: en,
                            retrievedAt: t0, status: .verified)
        let c = try Card(id: "stop", regionPack: testPack, subject: .household, desk: testDesk, facts: [fact.id])
        let parts = c.speakableParts(using: TestResolver(outcomes: [fact.id: .fact(fact)]), asOf: t0)
        #expect(parts.verbatimCodes == ["Test Route B", "Test Route A"])
        let plain = try verifiedFact("test-pack.phone")
        let c2 = try Card(id: "p", regionPack: testPack, subject: .household, desk: testDesk, facts: [plain.id])
        #expect(c2.speakableParts(using: TestResolver(outcomes: [plain.id: .fact(plain)]), asOf: t0).verbatimCodes.isEmpty)
    }

    @Test func factRefUsesPackIdAndFactIdOnTheWire() throws {
        let golden = #"{"fact_id":"test-pack.trash.day","pack_id":"test-pack"}"#
        let ref = try decode(FactRef.self, golden)
        #expect(ref == FactRef(regionPackID: "test-pack", ledgerFactID: "test-pack.trash.day"))
        #expect(try json(ref) == golden)
        let fromFile = try JSONDecoder().decode(FactRef.self, from: try fixture("fact-ref.json"))
        #expect(try json(fromFile) == String(decoding: try fixture("fact-ref.json"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(throws: DecodingError.self) {
            try decode(FactRef.self, #"{"regionPackID":"test-pack","ledgerFactID":"x"}"#)
        }
    }

    @Test func unavailableHandsOffToDeskAndShowsNoValue() throws {
        let desk = Desk(id: "test-pack.clinic", regionPack: testPack)
        let c = try Card(id: "c", regionPack: testPack, subject: .household, desk: testDesk, facts: ["f"])
        let resolver = TestResolver(outcomes: ["f": .unavailable(desk: desk)])
        let line = try #require(c.factLines(using: resolver, asOf: t0).first)
        #expect(line == .sourceUnavailable("f", desk: "test-pack.clinic"))
        #expect(line.handoffDesk == "test-pack.clinic")
        #expect(c.sourceLine(using: resolver, asOf: t0) == .noSource(desk: testDesk))
        let parts = c.speakableParts(using: resolver, asOf: t0)
        #expect(parts.sourcePublisher == nil && parts.retrievedAt == nil && parts.verbatimCodes.isEmpty)
        // Distinct from unsourced (no source exists), which hands off the same way.
        let unsourced = c.factLines(using: TestResolver(outcomes: ["f": .unsourced(desk: desk)]), asOf: t0).first
        #expect(unsourced == .handedToDesk("f", desk: "test-pack.clinic") && unsourced?.handoffDesk == "test-pack.clinic")
        #expect(FactOutcome.unavailable(desk: desk) != .unsourced(desk: desk))
    }

    @Test func oldDataShowsOnlyAsSourcedStaleFact() throws {
        // A cached value is shown only as a sourced Fact marked stale, labelled stale.
        let stale = try Fact(id: "f", value: .code("00-0000-000-0000"), source: placeholderSource, quote: "placeholder quote",
                             quoteLanguage: en, retrievedAt: t0, status: .stale)
        let c = try Card(id: "c", regionPack: testPack, subject: .household, desk: testDesk, facts: ["f"])
        #expect(c.factLines(using: TestResolver(outcomes: ["f": .fact(stale)]), asOf: t0) == [.shown(stale, status: .stale)])
        // A verified fact past its check window also reads as stale, never as live.
        let due = try verifiedFact("f", retrievedAt: t0, checkEveryDays: 1)
        #expect(c.factLines(using: TestResolver(outcomes: ["f": .fact(due)]), asOf: t0.addingTimeInterval(3 * 86_400))
                == [.shown(due, status: .stale)])
        // A stale fact without its source never shows.
        let unsourcedStale = Fact(unchecked: "f", value: .code("x"), source: nil, quote: nil, quoteLanguage: nil,
                                  retrievedAt: t0, status: .stale, checkEveryDays: nil)
        #expect(c.factLines(using: TestResolver(outcomes: ["f": .fact(unsourcedStale)]), asOf: t0).first?.handoffDesk == testDesk)
    }

    @Test func factOutcomeIsATaggedUnionOnTheWire() throws {
        let desk = Desk(id: "test-pack.desk", regionPack: testPack)
        let outcomes: [FactOutcome] = [
            .fact(try verifiedFact("f")),
            .notApplicable(reason: key("reason"), deferTo: FactRef(regionPackID: "test-pack", ledgerFactID: "g")),
            .notApplicable(reason: key("reason"), deferTo: nil),
            .unsourced(desk: desk), .unavailable(desk: desk),
        ]
        for o in outcomes { #expect(try decode(FactOutcome.self, try json(o)) == o) }
        let text = try json(FactOutcome.unavailable(desk: desk))
        #expect(text.hasPrefix(#"{"desk":{"#) && text.contains(#""type":"unavailable""#))
        #expect(try json(outcomes[1]).contains(#""defer_to":{"fact_id":"g","pack_id":"test-pack"}"#))
        #expect(try json(outcomes[1]).contains(#""type":"not_applicable""#))
        #expect(!(try json(outcomes[2])).contains("null"))
    }
}
