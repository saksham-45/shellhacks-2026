import Foundation
import ADCore

/// An argument substituted into a catalog format (`%@`, `%1$@`, `%lld`).
public enum LocalizedArgument: Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    /// Already-resolved text; keeps its own language tags.
    case text(ResolvedText)
    /// A proper name or code (school, office, publisher, "311"): never translated, untagged.
    case name(String)
    /// A count. Selects the plural form; shown with the surface's digits.
    case int(Int)
    /// A fact value, formatted by the same rules as a fact row.
    case value(FactValue)

    public init(stringLiteral value: String) { self = .name(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
}

/// Display vs spoken rules (phones digit by digit, money read in words of the catalog).
enum RenderMode: Sendable { case display, speech }

/// The one deep module callers use: hand it ADCore data, get text back tagged with its language.
/// A cheap value; derive a new one when the surface changes.
public struct Localizer: Sendable {
    public let surface: SurfaceLanguage
    public let registry: CatalogRegistry
    public let timeZone: TimeZone
    public let deskNaming: DeskNaming

    public init(registry: CatalogRegistry, surface: SurfaceLanguage,
                timeZone: TimeZone = .autoupdatingCurrent, deskNaming: DeskNaming = DeskNaming()) {
        self.registry = registry
        self.surface = surface
        self.timeZone = timeZone
        self.deskNaming = deskNaming
    }

    public func with(surface: SurfaceLanguage) -> Localizer {
        Localizer(registry: registry, surface: surface, timeZone: timeZone, deskNaming: deskNaming)
    }

    // MARK: Display

    public func text(_ key: StringKey, _ args: LocalizedArgument..., in language: SurfaceLanguage? = nil) -> ResolvedText {
        render(key, args, language ?? surface, .display)
    }

    public func text(_ key: StringKey, arguments: [LocalizedArgument], in language: SurfaceLanguage? = nil) -> ResolvedText {
        render(key, arguments, language ?? surface, .display)
    }

    public func text(_ value: FactValue, in language: SurfaceLanguage? = nil) -> ResolvedText {
        renderValue(value, language ?? surface, .display)
    }

    public func text(_ line: FactLine, in language: SurfaceLanguage? = nil) -> ResolvedText {
        renderLine(line, language ?? surface, .display)
    }

    public func text(_ line: SourceLine, in language: SurfaceLanguage? = nil) -> ResolvedText {
        let lang = language ?? surface
        switch line {
        case let .sourced(sources, lastChecked):
            let publishers = joinList(unique(sources.map(\.publisher)).map { ResolvedText(runs: [.init($0)], language: lang.language) }, lang, .display)
            // A real moment: the device time zone (not the UTC calendar-day rule of FactValue.date).
            let checked = render(ADLocaleKey.lastChecked, [.text(renderDate(lastChecked, lang, timeZone: timeZone))], lang, .display)
            return render(ADLocaleKey.sourceLine, [.text(render(line.labelKey, [], lang, .display)), .text(publishers), .text(checked)], lang, .display)
        case let .noSource(desk):
            return render(ADLocaleKey.noSource, [.text(render(line.labelKey, [], lang, .display)), .text(deskName(desk, lang))], lang, .display)
        }
    }

    /// The desk's name (decision D5 key convention).
    public func text(desk: DeskID, in language: SurfaceLanguage? = nil) -> ResolvedText {
        deskName(desk, language ?? surface)
    }

    /// The hero line in the surface, with the companion language under it (D3).
    public func stacked(_ key: StringKey, _ args: LocalizedArgument...) -> StackedLine {
        StackedLine(primary: render(key, args, surface, .display),
                    companion: surface.heroCompanion.map { render(key, args, $0, .display) })
    }

    // MARK: Speech

    public func speech(_ key: StringKey, _ args: LocalizedArgument..., in language: SurfaceLanguage? = nil) -> SpokenText {
        render(key, args, language ?? surface, .speech).spoken
    }

    public func speech(_ value: FactValue, in language: SurfaceLanguage? = nil) -> SpokenText {
        renderValue(value, language ?? surface, .speech).spoken
    }

    public func speech(_ line: FactLine, in language: SurfaceLanguage? = nil) -> SpokenText {
        renderLine(line, language ?? surface, .speech).spoken
    }

    /// "<title>. <key fact>. Source: <publisher>. Checked <date>." The publisher is never translated.
    public func speech(_ parts: SpeakableParts, in language: SurfaceLanguage? = nil) -> SpokenText {
        let lang = language ?? surface
        var pieces: [ResolvedText] = [sentence(render(parts.titleKey, [], lang, .speech))]
        if let line = parts.keyFact { pieces.append(sentence(renderLine(line, lang, .speech))) }
        if let publisher = parts.sourcePublisher { pieces.append(render(ADLocaleKey.speechSource, [.name(publisher)], lang, .speech)) }
        if let date = parts.retrievedAt { pieces.append(render(ADLocaleKey.speechChecked, [.text(renderDate(date, lang, timeZone: timeZone))], lang, .speech)) }
        var runs: [ResolvedText.Run] = []
        for (i, p) in pieces.enumerated() {
            if i > 0 { runs.append(.init(" ")) }
            runs += p.runs.map { .init($0.text, language: $0.language ?? p.language, spellsOut: $0.spellsOut,
                                       isFallback: $0.isFallback || p.isFallback, isMissing: $0.isMissing) }
        }
        return ResolvedText(runs: runs, language: lang.language, isMissing: pieces.contains { $0.isMissing }).spoken
    }

    // MARK: Resolution

    func render(_ key: StringKey, _ args: [LocalizedArgument], _ lang: SurfaceLanguage, _ mode: RenderMode) -> ResolvedText {
        let count = args.lazy.compactMap { if case .int(let n) = $0 { n } else { nil } }.first
        if let loc = registry.localization(key.table, key.key, lang), let format = loc.string(pluralCount: count) {
            return substitute(format, args, lang, mode, isFallback: false)
        }
        // A gap in one language falls back to English, tagged English (never tagged as the
        // requested language). A missing key or table shows ⟦table:key⟧ so the gap is visible.
        if lang != .en, let loc = registry.localization(key.table, key.key, .en), let format = loc.string(pluralCount: count) {
            return substitute(format, args, .en, mode, isFallback: true)
        }
        return ResolvedText(runs: [.init("⟦\(key.table):\(key.key)⟧", isMissing: true)], language: lang.language, isMissing: true)
    }

    private func substitute(_ format: String, _ args: [LocalizedArgument], _ lang: SurfaceLanguage,
                            _ mode: RenderMode, isFallback: Bool) -> ResolvedText {
        var runs: [ResolvedText.Run] = []
        var childFallback = false
        var childMissing = false
        for piece in FormatString.parse(format) {
            switch piece {
            case .literal(let s):
                runs.append(.init(s, language: lang.language, isFallback: isFallback))
            case .argument(let index, _):
                // An extra placeholder in a translation: visible marker, flagged missing (never read).
                guard index >= 0, index < args.count else {
                    runs.append(.init("⟦arg\(index + 1)⟧", isMissing: true))
                    childMissing = true
                    continue
                }
                let child = argumentText(args[index], lang, mode)
                childFallback = childFallback || child.isFallback
                childMissing = childMissing || child.isMissing
                runs += child.runs.map { r in
                    // Untagged runs of a child in another language keep that language.
                    let tag = r.language ?? (child.language.minimalIdentifier == lang.language.minimalIdentifier ? nil : child.language)
                    return .init(r.text, language: tag, spellsOut: r.spellsOut,
                                 isFallback: isFallback || child.isFallback || r.isFallback, isMissing: r.isMissing)
                }
            }
        }
        return ResolvedText(runs: runs, language: lang.language, isFallback: isFallback || childFallback, isMissing: childMissing)
    }

    private func argumentText(_ arg: LocalizedArgument, _ lang: SurfaceLanguage, _ mode: RenderMode) -> ResolvedText {
        switch arg {
        case .text(let t): return t
        case .name(let s): return ResolvedText(runs: [.init(s)], language: lang.language)
        case .int(let n): return ResolvedText(runs: [.init(FactFormat.integer(n, lang, mode))], language: lang.language)
        case .value(let v): return renderValue(v, lang, mode)
        }
    }

    func renderValue(_ value: FactValue, _ lang: SurfaceLanguage, _ mode: RenderMode) -> ResolvedText {
        let base = lang.language
        switch value {
        case let .text(s, language):
            return ResolvedText(runs: [.init(s, language: language)], language: base)
        case let .phone(digits):
            let s = mode == .display ? FactFormat.displayPhone(digits) : FactFormat.spokenPhone(digits)
            return ResolvedText(runs: [.init(s, spellsOut: true)], language: base)
        case let .date(date):
            // ADCore decodes "YYYY-MM-DD" to midnight UTC: a calendar day, so format it in UTC
            // (in Miami the device zone would show the day before).
            return renderDate(date, lang, timeZone: Localizer.calendarDayZone)
        case let .money(amount, currency):
            if mode == .speech, let spoken = spokenMoney(amount, currency, lang) { return spoken }
            return ResolvedText(runs: [.init(FactFormat.displayMoney(amount, currency, lang))], language: base)
        case let .code(code):
            return ResolvedText(runs: [.init(code)], language: base)
        case let .codes(codes):
            return joinList(codes.map { ResolvedText(runs: [.init($0)], language: base) }, lang, mode)
        case let .quantity(amount, unit) where unit == "year":
            // A calendar year (ADCore: year built is .quantity(1984, unit: "year")): digits as
            // written, no grouping ("1984", never "1,984"), no unit word.
            return ResolvedText(runs: [.init(NSDecimalNumber(decimal: amount).stringValue)], language: base)
        case let .quantity(amount, unit):
            let number = ResolvedText(runs: [.init(FactFormat.decimal(amount, lang, mode))], language: base)
            return render(ADLocaleKey.quantity, [.text(number), .text(render(ADLocaleKey.unit(unit), [], lang, mode))], lang, mode)
        case let .weekdays(days):
            return renderWeekdays(days, lang, mode)
        case let .place(place):
            guard let address = place.address, !address.isEmpty else { return ResolvedText(runs: [.init(place.name)], language: base) }
            return render(ADLocaleKey.placeWithAddress, [.name(place.name), .name(address)], lang, mode)
        case .flag:
            // ADCore names the key ("fact.flag.yes|no", table "ADCore").
            guard let key = value.displayKey else { return ResolvedText(runs: [], language: base) }
            return render(key, [], lang, mode)
        }
    }

    func renderLine(_ line: FactLine, _ lang: SurfaceLanguage, _ mode: RenderMode) -> ResolvedText {
        switch line {
        case let .shown(fact, status):
            guard let value = fact.displayValue else {
                return render(FactStatus.unsourced.labelKey, [], lang, mode)
            }
            let valueText = renderValue(value, lang, mode)
            switch status {
            case .demo, .stale:
                let label = render(status.labelKey, [], lang, mode)
                let key = mode == .display ? ADLocaleKey.factLabeled : ADLocaleKey.factLabeledSpoken
                return render(key, [.text(valueText), .text(label)], lang, mode)
            case .verified, .unsourced:
                return valueText
            }
        case let .notApplicable(_, reason, _):
            return render(reason, [], lang, mode)
        case let .handedToDesk(_, desk):
            return render(ADLocaleKey.handedToDesk, [.text(deskName(desk, lang))], lang, mode)
        case let .sourceUnavailable(_, desk):
            return render(ADLocaleKey.sourceUnavailable, [.text(deskName(desk, lang))], lang, mode)
        }
    }

    func deskName(_ desk: DeskID, _ lang: SurfaceLanguage) -> ResolvedText {
        render(deskNaming.key(for: desk), [], lang, .display)
    }

    // MARK: Rules

    /// Monday first, as people say them; catalog words and joiners, never Foundation's.
    func renderWeekdays(_ days: Set<Weekday>, _ lang: SurfaceLanguage, _ mode: RenderMode) -> ResolvedText {
        let ordered = FactFormat.mondayFirst.filter(days.contains)
        if ordered.count == 7 { return render(ADLocaleKey.everyDay, [], lang, mode) }
        if ordered == [.monday, .tuesday, .wednesday, .thursday, .friday] { return render(ADLocaleKey.mondayToFriday, [], lang, mode) }
        return joinList(ordered.map { render(ADLocaleKey.weekday($0), [], lang, mode) }, lang, mode)
    }

    /// "a", "a y b", "a, b y c" with the catalog's joiners.
    func joinList(_ items: [ResolvedText], _ lang: SurfaceLanguage, _ mode: RenderMode) -> ResolvedText {
        switch items.count {
        case 0: return ResolvedText(runs: [], language: lang.language)
        case 1: return items[0]
        case 2: return render(ADLocaleKey.listPair, [.text(items[0]), .text(items[1])], lang, mode)
        default:
            var head = items[0]
            for item in items[1..<(items.count - 1)] { head = render(ADLocaleKey.listMiddle, [.text(head), .text(item)], lang, mode) }
            return render(ADLocaleKey.listEnd, [.text(head), .text(items[items.count - 1])], lang, mode)
        }
    }

    /// Zone for `FactValue.date` (calendar days stored as midnight UTC).
    static let calendarDayZone = TimeZone(identifier: "UTC")!

    /// es/en: Foundation long date in es-US / en-US. ht: catalog month words, never Foundation.
    /// `timeZone`: `calendarDayZone` for fact dates, the device zone for real moments
    /// (last checked, retrieved at).
    func renderDate(_ date: Date, _ lang: SurfaceLanguage, timeZone: TimeZone) -> ResolvedText {
        switch lang {
        case .ht:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let c = cal.dateComponents([.day, .month, .year], from: date)
            let month = render(ADLocaleKey.month(c.month ?? 1), [], lang, .display)
            return render(ADLocaleKey.dateLong, [.name(String(c.day ?? 1)), .text(month), .name(String(c.year ?? 0))], lang, .display)
        default:
            return ResolvedText(runs: [.init(FactFormat.foundationLongDate(date, lang, timeZone))], language: lang.language)
        }
    }

    /// USD read with the catalog's plural words: "1 dólar con 32 centavos". Digits stay numerals
    /// for a voice of the same language. Other currencies: nil (the display form is read).
    func spokenMoney(_ amount: Decimal, _ currency: String, _ lang: SurfaceLanguage) -> ResolvedText? {
        guard currency.uppercased() == "USD", amount >= 0, let parts = FactFormat.dollarsAndCents(amount) else { return nil }
        let dollars = render(ADLocaleKey.moneyDollars, [.int(parts.dollars)], lang, .speech)
        let cents = render(ADLocaleKey.moneyCents, [.int(parts.cents)], lang, .speech)
        if parts.cents == 0 { return dollars }
        if parts.dollars == 0 { return cents }
        return render(ADLocaleKey.moneyDollarsAndCents, [.text(dollars), .text(cents)], lang, .speech)
    }

    private func sentence(_ t: ResolvedText) -> ResolvedText {
        let trimmed = t.plain.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !".?!…".contains(last) else { return t }
        // The period belongs to the run it ends: a fallback or missing title keeps its "." with it.
        let end = t.runs.last
        return ResolvedText(runs: t.runs + [.init(".", language: end?.language, isFallback: end?.isFallback ?? false,
                                                  isMissing: end?.isMissing ?? false)],
                            language: t.language, isFallback: t.isFallback, isMissing: t.isMissing)
    }

    private func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }
}

/// Parses the subset of printf formats catalogs use: %@, %n$@, %lld/%ld/%d/%i/%u (optionally
/// positional), and %%. Arguments are substituted run by run so language tags survive.
enum FormatString {
    enum Piece: Hashable { case literal(String), argument(index: Int, isInteger: Bool) }

    static func parse(_ format: String) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        var next = 0
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "%", i + 1 < chars.count else { literal.append(c); i += 1; continue }
            if chars[i + 1] == "%" { literal.append("%"); i += 2; continue }
            var j = i + 1
            var position: Int?
            var digits = ""
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { digits.append(chars[j]); j += 1 }
            if !digits.isEmpty, j < chars.count, chars[j] == "$" { position = Int(digits); j += 1 } else { j = i + 1 }
            // `%0$@` is not a valid position (would index -1): keep it as literal text.
            if let p = position, p < 1 { literal.append(contentsOf: String(chars[i..<min(j + 1, chars.count)])); i = j + 1; continue }
            while j < chars.count, chars[j] == "l" || chars[j] == "h" || chars[j] == "q" { j += 1 }
            guard j < chars.count else { literal.append(contentsOf: String(chars[i...])); break }
            let conv = chars[j]
            guard "@diu".contains(conv) else { literal.append(c); i += 1; continue }
            if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
            let index: Int
            if let position { index = position - 1 } else { index = next; next += 1 }
            pieces.append(.argument(index: index, isInteger: conv != "@"))
            i = j + 1
        }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    /// Format specifiers as a sorted multiset, for parity checks ("%1$@", "%lld" -> "1@", "i").
    static func signature(_ format: String) -> [String] {
        parse(format).compactMap { if case let .argument(i, isInt) = $0 { "\(i + 1)\(isInt ? "d" : "@")" } else { nil } }.sorted()
    }
}
