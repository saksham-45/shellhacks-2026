import Foundation
import Testing
@testable import ADCore

@Suite("Cross-package contracts")
struct ContractTests {
    @Test(arguments: ["hi", "ht", "es-419", "es", "en"])
    func languagesEncodeAsPlainBCP47(_ tag: String) throws {
        var p = Person(displayName: "A", thinkIn: Locale.Language(identifier: tag), surfaceLanguage: ht, goal: .arrive)
        p.statusWord = nil
        let h = try Household(pin: testPin, homeLanguage: Locale.Language(identifier: tag), people: [p])
        let text = String(decoding: try HouseholdCodec.encode(h), as: UTF8.self)
        #expect(text.contains("\"thinkIn\":\"\(tag)\"") && text.contains("\"homeLanguage\":\"\(tag)\""))
        #expect(text.contains("\"surfaceLanguage\":\"ht\""))
        #expect(!text.contains("components") && !text.contains("languageCode"))
        let back = try HouseholdCodec.decode(Data(text.utf8))
        #expect(back == h)
        #expect(back.people[0].thinkInLanguageTag == tag && back.homeLanguageTag == tag)
    }

    @Test func languageDecodeRejectsNestedObjectForm() {
        let nested = #"{"id":"\#(UUID().uuidString)","displayName":"A","thinkIn":{"components":{"languageCode":"hi"}},"goal":"arrive","mode":"resident","stage":1}"#
        #expect(throws: DecodingError.self) { try decode(Person.self, nested) }
    }

    @Test func stringKeyDefaultTableIsADCore() {
        #expect(StringKey(key: "x").table == "ADCore")
        #expect(StringKey.adCoreTable == "ADCore")
    }

    @Test func wireIdsAndEnumsArePlainStrings() throws {
        #expect(try json(RegionPackID(rawValue: "us-fl-miami")) == #""us-fl-miami""#)
        #expect(try json(PinID(rawValue: "demo.kendall")) == #""demo.kendall""#)
        #expect(try json(Goal.getThroughWeek) == #""getThroughWeek""#)
        #expect(try json(OriginLens.internationalStudent) == #""internationalStudent""#)
        #expect(try json(FactRef(regionPackID: "us-fl-miami", ledgerFactID: "us-fl-miami.trash.day"))
                == #"{"fact_id":"us-fl-miami.trash.day","pack_id":"us-fl-miami"}"#)
    }

    @Test func cardFilterNarrowsAndNeverBypassesPrivacyOrTouristRules() throws {
        let grandmother = person("Grandmother", goal: .visit), parent = person("Parent", goal: .work)
        let h = household([grandmother, parent])
        let catalog = catalogOnePerTopic + [
            card("immigration", .statusWord, modes: [.resident, .tourist], immigration: true),
            card("clinic-other-desk", .clinicDesk, desk: "test-pack.clinic"),
            card("hh-week", nil, subject: .household, modes: [.resident, .tourist]),
        ]
        // Asking for resident-mode stage-2 cards on the tourist's surface still returns no immigration.
        let touristAsk = CardFilter(stage: .mailAndStatus, mode: .resident)
        #expect(HeroPolicy.cards(matching: touristAsk, on: .person(grandmother.id), in: h, catalog: catalog).isEmpty)
        #expect(HeroPolicy.cards(matching: touristAsk, on: .person(parent.id), in: h, catalog: catalog).map(\.id)
                == ["statusWord", "mailbox", "immigration"])
        #expect(HeroPolicy.cards(matching: CardFilter(desk: "test-pack.clinic"), on: .person(parent.id), in: h, catalog: catalog).map(\.id)
                == ["clinic-other-desk"])
        #expect(HeroPolicy.cards(matching: CardFilter(subject: .household), on: .household, in: h, catalog: catalog).map(\.id) == ["hh-week"])
        #expect(HeroPolicy.cards(matching: CardFilter(subject: .household, cardIDs: ["hh-week"]), on: .household, in: h, catalog: catalog).map(\.id) == ["hh-week"])
        #expect(HeroPolicy.cards(matching: CardFilter(subject: .household, cardIDs: ["nope"]), on: .household, in: h, catalog: catalog).isEmpty)
        #expect(HeroPolicy.cards(matching: CardFilter(), on: .person(PersonID()), in: h, catalog: catalog).isEmpty)
        #expect(try decode(CardFilter.self, try json(touristAsk)) == touristAsk)
    }

    // myAD Access: pairs must differ in outline; no abstract glyphs; all unique.
    @Test func heroSymbolsAreDistinctObjects() {
        let symbols = HeroTopic.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
        func base(_ t: HeroTopic) -> String { String(t.symbolName.split(separator: ".").first!) }
        for (a, b) in [(HeroTopic.statusWord, HeroTopic.irs), (.eadDates, .deadlines), (.scam, .insurance), (.bank, .whichCity)] {
            #expect(base(a) != base(b), "\(a) vs \(b)")
        }
        #expect(!symbols.contains("nosign") && !symbols.contains("arrow.left.arrow.right") && !symbols.contains("list.bullet"))
        #expect(!HeroTopic.scam.symbolName.contains("shield") || !HeroTopic.insurance.symbolName.contains("shield"))
    }
}

@Suite("ADCore string catalog")
struct CatalogTests {
    struct Entry: Decodable {
        struct Localization: Decodable {
            struct Unit: Decodable { let value: String }
            let stringUnit: Unit?
        }
        let comment: String?
        let localizations: [String: Localization]?
    }
    struct Catalog: Decodable { let sourceLanguage: String; let strings: [String: Entry] }

    /// Read from the source tree so the check is the same on Linux and Apple (Apple compiles the
    /// catalog into .strings; Linux copies it as-is).
    static func catalog() throws -> Catalog {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ADCore/Resources/ADCore.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    /// Every StringKey ADCore defines with table "ADCore".
    static var adCoreKeys: [StringKey] {
        var keys: [StringKey] = Stage.allCases.map(\.labelKey) + HeroTopic.allCases.map(\.labelKey)
        keys += OnboardingStep.allCases.map(\.prompt) + Goal.allCases.map(\.labelKey)
        keys += [OnboardingPrompt(question: OnboardingStep.goal.prompt, personName: "x").leadIn].compactMap { $0 }
        keys += Mode.allCases.map(\.labelKey) + [Mode.iLiveHereNowKey]
        keys += FactStatus.allCases.map(\.labelKey)
        keys += [FactValue.flag(true), .flag(false)].compactMap(\.displayKey)
        keys += [SourceLine.sourced([], lastChecked: t0), .noSource(desk: testDesk)].map(\.labelKey)
        let errors: [OnboardingError] = [.invalidPin, .noPeople, .unnamedPerson(index: 0), .invalidAge(index: 0),
                                         .invalidLanguage, .unexpectedAnswer(expected: nil), .unknownPerson(PersonID())]
        keys += errors.map(\.messageKey)
        return keys
    }

    @Test func everyADCoreKeyExistsWithEnglishAndAComment() throws {
        let catalog = try Self.catalog()
        #expect(catalog.sourceLanguage == "en")
        for key in Self.adCoreKeys {
            #expect(key.table == "ADCore", "\(key.key)")
            let entry = try #require(catalog.strings[key.key], "missing \(key.key) in ADCore.xcstrings")
            let english = entry.localizations?["en"]?.stringUnit?.value ?? ""
            let comment = entry.comment ?? ""
            #expect(!english.isEmpty, "\(key.key) has no English")
            #expect(!comment.isEmpty, "\(key.key) has no comment")
        }
    }

    @Test func catalogHasNoKeysADCoreDoesNotUseAndNoWeekdays() throws {
        let used = Set(Self.adCoreKeys.map(\.key))
        let present = Set(try Self.catalog().strings.keys)
        #expect(present.subtracting(used).isEmpty, "unused: \(present.subtracting(used).sorted())")
        #expect(!present.contains { $0.hasPrefix("weekday") })
    }

    @Test func catalogIsInTheResourceBundle() throws {
        #if canImport(Darwin)
        let value = ADCoreStrings.bundle.localizedString(forKey: "stage.safe_this_week.title", value: nil, table: "ADCore")
        #expect(value == "Safe this week")
        #else
        // Linux SwiftPM copies the catalog as-is into ADCore_ADCore.bundle.
        #expect(ADCoreStrings.bundle.url(forResource: "ADCore", withExtension: "xcstrings") != nil)
        #endif
    }
}
