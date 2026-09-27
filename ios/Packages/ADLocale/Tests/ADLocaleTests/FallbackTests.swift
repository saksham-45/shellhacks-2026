import XCTest
import ADCore
@testable import ADLocale

/// REVIEW-swap1: fallback flag reaches speech, `%0$@` never traps, every catalog decodes.
final class FallbackTests: XCTestCase {
    func testFallbackEnglishIsFlaggedInSpokenText() {
        let t = localizer(.es).text(StringKey(key: "only.en", table: "Cards"))
        XCTAssertTrue(t.isFallback)
        XCTAssertTrue(t.spoken.containsFallback)
        XCTAssertFalse(localizer(.es).text(StringKey(key: "card.test.title", table: "Cards")).spoken.containsFallback)
    }

    func testFallbackChildArgumentMarksTheParent() {
        let child = localizer(.es).text(StringKey(key: "only.en", table: "Cards"))
        let parent = localizer(.es).text(ADLocaleKey.listPair, .text(child), .name("Miami"))
        XCTAssertTrue(parent.isFallback)
        XCTAssertTrue(parent.spoken.containsFallback)
    }

    func testPositionZeroIsLiteralAndNeverTraps() {
        XCTAssertEqual(FormatString.parse("a %0$@ b"), [.literal("a %0$@ b")])
        let reg = registry(extra: [catalog("Bad", ["bad.zero": ["es": "Hola %0$@", "en": "Hi %0$@", "ht": "Bonjou %0$@"]])])
        let t = Localizer(registry: reg, surface: .es, timeZone: newYork).text(StringKey(key: "bad.zero", table: "Bad"), .name("Ana"))
        XCTAssertEqual(t.plain, "Hola %0$@")
    }

    func testFallbackBadgeKeysExistInAllLanguages() {
        for l in SurfaceLanguage.allCases {
            XCTAssertFalse(localizer(l).text(ADLocaleKey.fallbackEnglishBadge, in: l).isMissing)
            XCTAssertFalse(localizer(l).text(ADLocaleKey.fallbackEnglishHint, in: l).isMissing)
        }
        XCTAssertEqual(localizer(.es).text(ADLocaleKey.fallbackEnglishBadge).plain, "(en inglés)")
    }

    func testShippedCatalogsDecodeWithoutTrippingTheAssertion() throws {
        for (table, bundle) in [("ADLocale", ADLocaleResources.bundle), ("ADCore", ADCoreStrings.bundle)] {
            let url = try XCTUnwrap(bundle.url(forResource: table, withExtension: "xcstrings"), table)
            XCTAssertNotNil(CatalogRegistration.decode(table: table, data: try Data(contentsOf: url)), table)
        }
    }
}
