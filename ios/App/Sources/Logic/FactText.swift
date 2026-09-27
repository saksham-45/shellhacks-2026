import Foundation
import ADCore
import ADLocale

/// One fact line as text for the screen and for speech: the value (typed values formatted here,
/// codes/names/numbers verbatim) plus its qualifier (status + source, or the desk it hands off to).
/// Thin adapter until ADLocale ships its formatter (gap reported to myAD Language).
public struct FactRowText: Hashable, Sendable {
    public let id: FactID
    public let value: String?
    /// BCP-47 of `value` when it is not in the surface language (a `.text` fact in English, a place name).
    public let valueLanguage: String?
    public let qualifier: String
    public let phoneDigits: String?
    public let place: Place?

    /// One combined element (A11Y-VO-04): value, then qualifier.
    public var combined: String { [value, qualifier].compactMap { $0 }.joined(separator: ". ") }
}

public enum FactText {
    public static func row(_ line: FactLine, language: String) -> FactRowText {
        let t = { (k: String) in AppStrings.text(StringKey(key: k, table: StringKey.adCoreTable), language: language) }
        switch line {
        case let .shown(fact, status):
            let value = fact.displayValue
            var parts = [AppStrings.text(status.labelKey, language: language)]
            if let publisher = fact.source?.publisher {
                var source = "\(t("source_line.sourced")): \(publisher)"
                if let at = fact.retrievedAt { source += ", " + date(at, language) }
                parts.append(source)
            }
            var phone: String?
            var place: Place?
            var valueLanguage: String?
            switch value {
            case .phone(let digits)?: phone = digits
            case .place(let p)?: place = p
            case .text(_, let lang)?: valueLanguage = lang.minimalIdentifier
            default: break
            }
            return FactRowText(id: fact.id, value: value.map { format($0, language) }, valueLanguage: valueLanguage,
                               qualifier: parts.joined(separator: " · "), phoneDigits: phone, place: place)
        case let .notApplicable(id, reason, _):
            return FactRowText(id: id, value: nil, valueLanguage: nil,
                               qualifier: AppStrings.text(reason, language: language), phoneDigits: nil, place: nil)
        case let .handedToDesk(id, desk):
            return FactRowText(id: id, value: nil, valueLanguage: nil,
                               qualifier: "\(t("fact.status.unsourced")). \(AppStrings.app("app.card.desk_label", language)): \(desk.rawValue)",
                               phoneDigits: nil, place: nil)
        case let .sourceUnavailable(id, desk):
            return FactRowText(id: id, value: nil, valueLanguage: nil,
                               qualifier: "\(AppStrings.app("app.fact.unavailable", language)) \(AppStrings.app("app.card.desk_label", language)): \(desk.rawValue)",
                               phoneDigits: nil, place: nil)
        }
    }

    public static func format(_ value: FactValue, _ language: String) -> String {
        let locale = Locale(identifier: language)
        switch value {
        case .text(let s, _): return s
        case .code(let c): return c
        case .codes(let cs): return cs.joined(separator: ", ")
        case .phone(let digits): return phone(digits)
        case .date(let d): return date(d, language)
        case let .money(amount, currency): return amount.formatted(.currency(code: currency).locale(locale))
        case let .quantity(amount, unit): return "\(amount.formatted(.number.locale(locale))) \(unit)"
        case .weekdays(let days):
            return Weekday.allCases.filter(days.contains).map { AppStrings.weekday($0, language) }.joined(separator: ", ")
        case .place(let p): return [p.name, p.address].compactMap { $0 }.joined(separator: ", ")
        case .flag(let b): return AppStrings.text(StringKey(key: b ? "fact.flag.yes" : "fact.flag.no", table: StringKey.adCoreTable), language: language)
        }
    }

    /// Digits as written in the US (NANP); anything else stays as the ledger wrote it.
    public static func phone(_ digits: String) -> String {
        let d = digits.filter(\.isNumber)
        let ten = d.count == 11 && d.hasPrefix("1") ? String(d.dropFirst()) : d
        guard ten.count == 10 else { return digits }
        let a = ten.prefix(3), b = ten.dropFirst(3).prefix(3), c = ten.suffix(4)
        return "(\(a)) \(b)-\(c)"
    }

    static func date(_ d: Date, _ language: String) -> String {
        d.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: language)))
    }
}
