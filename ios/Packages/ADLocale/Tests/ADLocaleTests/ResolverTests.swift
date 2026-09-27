import XCTest
import ADCore
@testable import ADLocale

final class ResolverTests: XCTestCase {
    func testMissingKeyAndTableAreVisible() {
        let a = localizer(.es).text(StringKey(key: "nope", table: "ADLocale"))
        XCTAssertEqual(a.plain, "⟦ADLocale:nope⟧")
        XCTAssertTrue(a.isMissing)
        XCTAssertEqual(localizer(.ht).text(StringKey(key: "x", table: "NoSuchTable")).plain, "⟦NoSuchTable:x⟧")
    }

    func testLanguageGapFallsBackToEnglishTaggedEnglish() {
        let t = localizer(.ht).text(StringKey(key: "only.en", table: "Cards"))
        XCTAssertEqual(t.plain, "English only")
        XCTAssertTrue(t.isFallback)
        XCTAssertEqual(t.language.minimalIdentifier, "en", "never tag English text as Creole")
    }

    func testExplicitLanguageLookup() {
        let l = localizer(.en)
        XCTAssertEqual(l.text(ADLocaleKey.weekday(.monday), in: .ht).plain, "lendi")
        XCTAssertEqual(l.text(ADLocaleKey.weekday(.monday), in: .ht).language.minimalIdentifier, "ht")
        XCTAssertEqual(l.with(surface: .es).text(ADLocaleKey.weekday(.monday)).plain, "lunes")
    }

    func testStackedHeroLinesAreSeparatelyTagged() {
        let es = localizer(.es).stacked(StringKey(key: "hero.test", table: "Cards"))
        XCTAssertEqual(es.primary.plain, "Mañana, basura")
        XCTAssertEqual(es.primary.language.minimalIdentifier, "es")
        XCTAssertEqual(es.companion?.plain, "Tomorrow · trash")
        XCTAssertEqual(es.companion?.language.minimalIdentifier, "en")
        let ht = localizer(.ht).stacked(StringKey(key: "hero.test", table: "Cards"))
        XCTAssertEqual(ht.primary.language.minimalIdentifier, "ht")
        XCTAssertEqual(ht.companion?.language.minimalIdentifier, "en")
    }

    func testAttributedCarriesLanguageIdentifierPerRun() {
        let key = StringKey(key: "fact.handed_to_desk", table: "ADLocale")
        let t = localizer(.es).text(key, .text(ResolvedText("Test Desk", language: lang("en"))))
        let ids = t.attributed.runs.map { $0.languageIdentifier }
        XCTAssertEqual(ids.first ?? nil, "es")
        XCTAssertTrue(ids.contains("en"))
    }

    func testPluralSelection() {
        XCTAssertEqual(localizer(.en).text(ADLocaleKey.moneyCents, .int(1)).plain, "1 cent")
        XCTAssertEqual(localizer(.en).text(ADLocaleKey.moneyCents, .int(5)).plain, "5 cents")
        XCTAssertEqual(localizer(.es).text(ADLocaleKey.moneyDollars, .int(1234)).plain, "1,234 dólares")
    }

    func testFactLinesAndSourceLines() {
        let l = localizer(.es)
        let handed = l.text(FactLine.handedToDesk("xx-test.fact", desk: testDesk))
        XCTAssertEqual(handed.plain, "No tenemos fuente para esto. Pregunte a: Oficina de prueba")
        let unavailable = l.text(FactLine.sourceUnavailable("xx-test.fact", desk: testDesk))
        XCTAssertTrue(unavailable.plain.hasSuffix("Oficina de prueba"))
        XCTAssertEqual(l.text(desk: testDesk, in: .ht).plain, "Biwo tès")
        let source = Source(id: "xx-src", url: URL(string: "https://example.invalid")!, publisher: "Test Publisher")
        let line = l.text(SourceLine.sourced([source, source], lastChecked: sept25))
        XCTAssertTrue(line.plain.contains("Test Publisher · revisado el 25 de septiembre de 2026"), line.plain)
        XCTAssertEqual(line.plain.components(separatedBy: "Test Publisher").count, 2, "publishers are deduplicated")
    }

    struct Resolver: FactResolving {
        let facts: [FactID: FactOutcome]
        func outcome(for id: FactID) -> FactOutcome? { facts[id] }
    }

    func testSpeakablePartsSpeechIsSegmentedByLanguage() throws {
        let card = try Card(id: "xx-test", regionPack: "xx-test", subject: .household,
                            titleKey: StringKey(key: "card.test.title", table: "Cards"), desk: testDesk, facts: ["xx-test.fact"])
        let spoken = localizer(.es).speech(card.speakableParts(using: Resolver(facts: [:]), asOf: sept25))
        XCTAssertEqual(spoken.plain, "Basura. No tenemos fuente para esto. Pregunte a: Oficina de prueba.")
        XCTAssertEqual(spoken.segments.map { $0.language.minimalIdentifier }, ["es"])
    }

    func testSpeakablePartsWithSourcePhoneAndPublisher() throws {
        let source = Source(id: "xx-src", url: URL(string: "https://example.invalid")!, publisher: "Test Publisher")
        let fact = try Fact(id: "xx-test.phone", value: .phone(digits: "3050000000"), source: source, quote: "test quote",
                            quoteLanguage: lang("en"), retrievedAt: sept25, status: .verified)
        let card = try Card(id: "xx-test", regionPack: "xx-test", subject: .household,
                            titleKey: StringKey(key: "card.test.title", table: "Cards"), desk: testDesk, facts: ["xx-test.phone"])
        let parts = card.speakableParts(using: Resolver(facts: ["xx-test.phone": .fact(fact)]), asOf: sept25)
        XCTAssertEqual(localizer(.es).speech(parts).plain,
                       "Basura. 3 0 5, 0 0 0, 0 0 0 0. Fuente: Test Publisher. Revisado el 25 de septiembre de 2026.")
        XCTAssertEqual(localizer(.en).speech(parts).plain,
                       "Trash. 3 0 5, 0 0 0, 0 0 0 0. Source: Test Publisher. Checked September 25, 2026.")
    }

    func testEmptyRegistryShowsMarkers() {
        let l = Localizer(registry: CatalogRegistry([]), surface: .es)
        XCTAssertEqual(l.text(.weekdays([.monday])).plain, "⟦ADLocale:weekday.monday⟧")
    }
}
