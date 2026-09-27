import XCTest
import ADCore
@testable import ADLocale

/// Access S12 (logic part) and S6 (flags reach runs and segments).
final class AccessibilityLineTests: XCTestCase {
    func testStackedHeroLinesHaveOwnLanguageAndHeader() {
        let line = StackedLine(primary: ResolvedText("Mañana, basura", language: lang("es")),
                               companion: ResolvedText("Tomorrow · trash", language: lang("en")))
        let a = line.accessibilityLines
        XCTAssertEqual(a.map(\.speechLanguage.minimalIdentifier), ["es", "en"])
        XCTAssertEqual(a.map(\.isHeader), [true, false])
    }

    func testMissingDeskInsideSentenceMarksOnlyThatSegment() {
        let l = localizer(.es)
        let t = l.text(ADLocaleKey.handedToDesk, .text(l.text(StringKey(key: "desk.nope", table: "ADCityPack"))))
        XCTAssertTrue(t.isMissing)
        let segs = t.spoken.segments
        XCTAssertTrue(segs.contains { $0.isMissing && $0.text.contains("⟦") })
        XCTAssertTrue(segs.contains { !$0.isMissing && !$0.text.contains("⟦") })
    }

    func testFallbackChildOnlyMarksItsOwnSegment() {
        let l = localizer(.es)
        let child = l.text(StringKey(key: "only.en", table: "Cards"))
        let t = l.text(ADLocaleKey.listPair, .text(child), .name("Miami"))
        let segs = t.spoken.segments
        XCTAssertTrue(segs.contains { $0.isFallback && $0.text.contains("English only") })
        XCTAssertTrue(segs.contains { !$0.isFallback }, "\(segs)")
    }
}

/// Access round 2: R3 (extra placeholder) and R7a (lone ".").
final class AccessRound2LocaleTests: XCTestCase {
    func testExtraPlaceholderIsFlaggedMissing() {
        let reg = registry(extra: [catalog("X", ["call.two": ["es": "Llame a %1$@ o a %2$@.", "en": "Call %1$@ or %2$@.", "ht": "Rele %1$@ oswa %2$@."]])])
        let t = Localizer(registry: reg, surface: .es, timeZone: newYork).text(StringKey(key: "call.two", table: "X"), .name("311"))
        XCTAssertTrue(t.plain.contains("⟦arg2⟧"))
        XCTAssertTrue(t.isMissing)
        XCTAssertTrue(t.spoken.segments.contains { $0.isMissing && $0.text.contains("⟦arg2⟧") })
        XCTAssertFalse(t.spoken.segments.contains { !$0.isMissing && $0.text.contains("⟦") })
    }

    func testNoLonePeriodSegment() {
        let t = ResolvedText(runs: [.init("⟦Cards:card.x.title⟧", isMissing: true), .init("."), .init(" Hola.", language: nil)],
                             language: lang("es"))
        XCTAssertFalse(t.spoken.segments.contains { $0.text.trimmingCharacters(in: .whitespaces) == "." })
    }
}
