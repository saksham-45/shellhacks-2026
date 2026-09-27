import XCTest
import ADCore
@testable import ADLocale

final class FormatterTests: XCTestCase {
    func testWeekdaysMondayFirstAsPeopleSayThem() {
        XCTAssertEqual(localizer(.es).text(.weekdays([.friday, .tuesday])).plain, "martes y viernes")
        XCTAssertEqual(localizer(.en).text(.weekdays([.friday, .tuesday])).plain, "Tuesday and Friday")
        XCTAssertEqual(localizer(.ht).text(.weekdays([.friday, .tuesday])).plain, "madi ak vandredi")
        XCTAssertEqual(localizer(.es).text(.weekdays([.sunday, .monday])).plain, "lunes y domingo")
        XCTAssertEqual(localizer(.es).text(.weekdays([.friday, .monday, .wednesday])).plain, "lunes, miércoles y viernes")
        XCTAssertEqual(localizer(.en).text(.weekdays([.friday, .monday, .wednesday])).plain, "Monday, Wednesday, and Friday")
        XCTAssertEqual(localizer(.es).text(.weekdays(Set(Weekday.allCases))).plain, "todos los días")
        XCTAssertEqual(localizer(.es).text(.weekdays([.monday, .tuesday, .wednesday, .thursday, .friday])).plain, "de lunes a viernes")
        XCTAssertEqual(localizer(.es).text(.weekdays([.saturday])).plain, "sábado")
        XCTAssertEqual(Weekday.tuesday.stringKey, StringKey(key: "weekday.tuesday", table: "ADLocale"))
    }

    func testMoneyDisplayIsMiamiNotSpain() {
        XCTAssertEqual(localizer(.es).text(.money(amount: Decimal(string: "1.32")!, currency: "USD")).plain, "$1.32")
        XCTAssertEqual(localizer(.en).text(.money(amount: Decimal(string: "1.32")!, currency: "USD")).plain, "$1.32")
        XCTAssertEqual(localizer(.ht).text(.money(amount: Decimal(string: "1.32")!, currency: "USD")).plain, "$1.32")  // D8
        XCTAssertEqual(localizer(.es).text(.money(amount: Decimal(string: "1234.5")!, currency: "USD")).plain, "$1,234.50")
        XCTAssertTrue(localizer(.es).text(.money(amount: 3, currency: "EUR")).plain.contains("EUR"))
    }

    func testMoneySpokenWithCatalogWords() {
        XCTAssertEqual(localizer(.es).speech(.money(amount: Decimal(string: "1.32")!, currency: "USD")).plain, "1 dólar con 32 centavos")
        XCTAssertEqual(localizer(.es).speech(.money(amount: Decimal(string: "0.66")!, currency: "USD")).plain, "66 centavos")
        XCTAssertEqual(localizer(.es).speech(.money(amount: 2, currency: "USD")).plain, "2 dólares")
        XCTAssertEqual(localizer(.en).speech(.money(amount: Decimal(string: "1.01")!, currency: "USD")).plain, "1 dollar and 1 cent")
        XCTAssertEqual(localizer(.ht).speech(.money(amount: Decimal(string: "1.32")!, currency: "USD")).plain, "1 dola ak 32 santim")
    }

    func testPhonesDigitByDigit() {
        let display = localizer(.es).text(.phone(digits: "3053865244"))
        XCTAssertEqual(display.plain, "305-386-5244")
        XCTAssertTrue(display.runs.allSatisfy(\.spellsOut))
        XCTAssertEqual(localizer(.es).speech(.phone(digits: "(305) 386-5244")).plain, "3 0 5, 3 8 6, 5 2 4 4")
        XCTAssertEqual(localizer(.en).speech(.phone(digits: "1-305-386-5244")).plain, "3 0 5, 3 8 6, 5 2 4 4")
        XCTAssertEqual(localizer(.en).text(.phone(digits: "311")).plain, "311")
        XCTAssertEqual(localizer(.en).speech(.phone(digits: "311")).plain, "3 1 1")
    }

    func testDatesEsEnFromFoundationHtFromCatalog() {
        XCTAssertEqual(localizer(.es).text(.date(sept25)).plain, "25 de septiembre de 2026")
        XCTAssertEqual(localizer(.en).text(.date(sept25)).plain, "September 25, 2026")
        let ht = localizer(.ht).text(.date(sept25)).plain
        XCTAssertEqual(ht, "25 septanm 2026")
        XCTAssertFalse(ht.contains("septembre"), "Creole must never get Foundation's French")
    }

    func testCreoleWordsNeverFrench() {
        let french = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "septembre", "et"]
        let words = Set(TextNormalizer.wordsKeepingDiacritics(localizer(.ht).text(.weekdays(Set(Weekday.allCases).subtracting([.sunday]))).plain))
        XCTAssertTrue(words.isDisjoint(with: french), "\(words)")
    }

    func testNamesAndCodesNeverTranslated() {
        let place = Place(name: "Claude Pepper", coordinate: Coordinate(latitude: 0, longitude: 0))
        let t = localizer(.es).text(.place(place))
        XCTAssertEqual(t.plain, "Claude Pepper")
        XCTAssertTrue(t.foreignRuns.isEmpty, "proper names are untagged; they inherit the sentence language")
        XCTAssertEqual(localizer(.ht).text(.code("01-0000-000-0000")).plain, "01-0000-000-0000")
        XCTAssertEqual(localizer(.es).text(.codes(["S", "12", "207"])).plain, "S, 12 y 207")
        XCTAssertEqual(localizer(.es).text(.quantity(1984, unit: "year")).plain, "1984")
    }

    func testQuotedTextKeepsItsOwnLanguage() {
        let t = localizer(.es).text(.text("Bulky waste", language: lang("en")))
        XCTAssertEqual(t.language.minimalIdentifier, "es")
        XCTAssertEqual(t.foreignRuns.map { $0.language?.minimalIdentifier }, ["en"])
        XCTAssertEqual(t.spoken.segments.map(\.language.minimalIdentifier), ["en"])
    }

    func testFormatStringParsing() {
        XCTAssertEqual(FormatString.parse("%1$@ y %2$@"), [.argument(index: 0, isInteger: false), .literal(" y "), .argument(index: 1, isInteger: false)])
        XCTAssertEqual(FormatString.parse("%lld dólares 100%%"), [.argument(index: 0, isInteger: true), .literal(" dólares 100%")])
        XCTAssertEqual(FormatString.signature("%2$@: %1$@"), FormatString.signature("%@ · %@"))
        XCTAssertNotEqual(FormatString.signature("%@"), FormatString.signature("%lld"))
    }
}
