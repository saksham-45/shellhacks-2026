import Foundation
import ADCore

/// The ONLY place in the app that calls Foundation's number/currency/date formatting
/// (decision D1; ci-hook.sh fails on such calls anywhere else). Rules:
/// - es formats with es-US (Miami: `$1.32`, `25 de septiembre de 2026`), en with en-US.
/// - ht gets digits and currency from en-US (decision D8, needs review) and NEVER words:
///   Creole weekday/month/number words come from the catalogs, because Foundation's ht data
///   is French (`septembre`, `lundi`, `soixante-six`).
/// - Phone digits and proper names are never translated.
enum FactFormat {
    /// People's week: Monday first ("martes y viernes", never Sunday-first calendar order).
    static let mondayFirst: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    static func integer(_ n: Int, _ lang: SurfaceLanguage, _ mode: RenderMode) -> String {
        mode == .speech ? String(n) : n.formatted(.number.locale(lang.formattingLocale))
    }

    static func decimal(_ d: Decimal, _ lang: SurfaceLanguage, _ mode: RenderMode) -> String {
        if mode == .speech { return NSDecimalNumber(decimal: d).stringValue }
        return d.formatted(.number.locale(lang.formattingLocale))
    }

    /// USD with the symbol (`$1.32` in es-US and en-US); any other currency shows its ISO code
    /// so a symbol like "$" is never ambiguous.
    static func displayMoney(_ amount: Decimal, _ currency: String, _ lang: SurfaceLanguage) -> String {
        let code = currency.uppercased()
        if code == "USD" { return amount.formatted(.currency(code: code).locale(lang.formattingLocale)) }
        return amount.formatted(.currency(code: code).presentation(.isoCode).locale(lang.formattingLocale))
    }

    static func foundationLongDate(_ date: Date, _ lang: SurfaceLanguage, _ timeZone: TimeZone) -> String {
        precondition(lang != .ht, "Creole dates come from the catalog, never Foundation")
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: timeZone).locale(lang.formattingLocale))
    }

    /// Digits unchanged; 10-digit NANP numbers (optionally with a leading 1) read 305-386-5244.
    /// Short codes (311, 911) and anything else stay exactly as given.
    static func displayPhone(_ raw: String) -> String {
        let d = nanpDigits(raw)
        guard d.count == 10 else { return raw }
        return "\(d[0..<3].joined())-\(d[3..<6].joined())-\(d[6..<10].joined())"
    }

    /// Digit by digit, grouped 3-3-4 for NANP: "3 0 5, 3 8 6, 5 2 4 4". Short codes: "3 1 1".
    static func spokenPhone(_ raw: String) -> String {
        let d = nanpDigits(raw)
        guard d.count == 10 else { return raw.filter(\.isNumber).map(String.init).joined(separator: " ") }
        return [d[0..<3], d[3..<6], d[6..<10]].map { $0.joined(separator: " ") }.joined(separator: ", ")
    }

    private static func nanpDigits(_ raw: String) -> [String] {
        var d = raw.filter { $0.isASCII && $0.isNumber }.map(String.init)
        if d.count == 11, d.first == "1" { d.removeFirst() }
        return d
    }

    /// Splits a USD amount into whole dollars and cents (rounded to the cent). Nil if too large.
    static func dollarsAndCents(_ amount: Decimal) -> (dollars: Int, cents: Int)? {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let totalCents = NSDecimalNumber(decimal: rounded * 100)
        guard totalCents.doubleValue < Double(Int.max / 2) else { return nil }
        let cents = totalCents.intValue
        return (cents / 100, cents % 100)
    }
}
