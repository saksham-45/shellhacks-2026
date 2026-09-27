import XCTest
import ADCore
@testable import ADLocale

/// FactValue.date is a calendar day (midnight UTC); last checked / retrieved at are moments.
final class DateZoneTests: XCTestCase {
    let day29UTC = Date(timeIntervalSince1970: 1_790_640_000)        // 2026-09-29T00:00:00Z
    let moment = Date(timeIntervalSince1970: 1_790_640_000 + 7_200)  // 2026-09-29T02:00:00Z = 28th, 10 PM in Miami

    func testFactDateIsTheSameCalendarDayInMiami() {
        for s in SurfaceLanguage.allCases {
            let shown = localizer(s).text(FactValue.date(day29UTC)).plain
            XCTAssertTrue(shown.contains("29"), "\(s): \(shown)")
            XCTAssertFalse(shown.contains("28"), "\(s): \(shown)")
            XCTAssertTrue(localizer(s).speech(FactValue.date(day29UTC)).plain.contains("29"), "\(s) speech")
        }
    }

    func testRetrievedAtAndLastCheckedStayInTheDeviceZone() throws {
        let source = Source(id: "xx-src", url: URL(string: "https://example.invalid")!, publisher: "Test Publisher")
        let fact = try Fact(id: "xx-test.phone", value: .phone(digits: "3050000000"), source: source, quote: "test quote",
                            quoteLanguage: lang("en"), retrievedAt: moment, status: .verified)
        let card = try Card(id: "xx-test", regionPack: "xx-test", subject: .household,
                            titleKey: StringKey(key: "card.test.title", table: "Cards"), desk: testDesk, facts: ["xx-test.phone"])
        let parts = card.speakableParts(using: ResolverTests.Resolver(facts: ["xx-test.phone": .fact(fact)]), asOf: moment)
        XCTAssertNotNil(parts.retrievedAt)
        for s in SurfaceLanguage.allCases {
            let spoken = localizer(s).speech(parts).plain
            XCTAssertTrue(spoken.contains("28"), "\(s): \(spoken)")
            XCTAssertFalse(spoken.contains("29"), "\(s): \(spoken)")
            let line = localizer(s).text(SourceLine.sourced([source], lastChecked: moment)).plain
            XCTAssertTrue(line.contains("28"), "\(s): \(line)")
        }
    }
}
