// Shared type (ARCHITECTURE.md §12). Mirrors the research ledger shape
// (id, value, unit, source_id, url, quote, retrieved_at, check_every, status).
import Foundation

/// Pinned: exactly four.
public enum FactStatus: String, Codable, Sendable, CaseIterable {
    case verified, stale, unsourced, demo

    /// Label shown next to a fact ("Example", "No source", ...). Table "ADCore".
    public var labelKey: StringKey { .adCore("fact.status.\(rawValue)") }
}

/// The publisher and URL of a source registry entry.
public struct Source: Hashable, Codable, Sendable {
    public let id: SourceID
    public let url: URL
    public let publisher: String

    public init(id: SourceID, url: URL, publisher: String) {
        self.id = id
        self.url = url
        self.publisher = publisher
    }
}

/// Typed values, never preformatted strings: ADLocale formats, ADVoice speaks.
/// Final list, exactly ten cases (ARCHITECTURE.md §13.z). There is no number, url, or verbatim
/// case; "none recorded" is a `FactOutcome`, never a sentinel value.
/// JSON: an object with a "kind" discriminator whose value is the case name, e.g.
/// {"kind":"flag","value":true}, {"kind":"code","code":"01-0000-000-0000"}.
public enum FactValue: Hashable, Sendable {
    case text(String, language: Locale.Language)
    /// An identifier or proper name that is never translated or localized: a folio, a district id,
    /// a grade span, a representative's name. Shown and spoken exactly as written.
    case code(String)
    /// Several codes, e.g. the route names at a stop. Order is the source's order. ADLocale joins
    /// them for display; ADCore adds no joiner words.
    case codes([String])
    case phone(digits: String)
    case date(Date)
    /// `currency` is ISO 4217, e.g. "USD".
    case money(amount: Decimal, currency: String)
    /// A number with its unit. Year built is `.quantity(1984, unit: "year")`.
    case quantity(Decimal, unit: String)
    /// Recurring days, e.g. trash pickup "Tuesday Friday".
    case weekdays(Set<Weekday>)
    case place(Place)
    /// A true yes/no fact (e.g. the parcel's condo flag).
    case flag(Bool)

    /// Text key for values ADCore can name without formatting: a flag reads as a localized
    /// yes/no (table "ADCore"). Nil for kinds ADLocale formats (numbers, dates, days, ...).
    public var displayKey: StringKey? {
        switch self {
        case .flag(let value): .adCore(value ? "fact.flag.yes" : "fact.flag.no")
        case .text, .code, .codes, .phone, .date, .money, .quantity, .weekdays, .place: nil
        }
    }

    /// The code strings to render and speak verbatim (never localized, never looked up as a
    /// StringKey), in source order. `code` gives one element, `codes` its array; nil otherwise.
    public var verbatimCodes: [String]? {
        switch self {
        case .code(let code): [code]
        case .codes(let codes): codes
        case .text, .phone, .date, .money, .quantity, .weekdays, .place, .flag: nil
        }
    }
}

extension FactValue: Codable {
    private enum Kind: String, Codable {
        case text, code, codes, phone, date, money, quantity, weekdays, place, flag
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, language, code, codes, digits, date, amount, currency, unit, days, place, value
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try c.decode(String.self, forKey: .text), language: try c.decodeLanguage(forKey: .language))
        case .code: self = .code(try c.decode(String.self, forKey: .code))
        case .codes: self = .codes(try c.decode([String].self, forKey: .codes))
        case .phone: self = .phone(digits: try c.decode(String.self, forKey: .digits))
        case .date: self = .date(try c.decode(Date.self, forKey: .date))
        case .money: self = .money(amount: try c.decode(Decimal.self, forKey: .amount), currency: try c.decode(String.self, forKey: .currency))
        case .quantity: self = .quantity(try c.decode(Decimal.self, forKey: .amount), unit: try c.decode(String.self, forKey: .unit))
        case .weekdays: self = .weekdays(Set(try c.decode([Weekday].self, forKey: .days)))
        case .place: self = .place(try c.decode(Place.self, forKey: .place))
        case .flag: self = .flag(try c.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, language):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encodeLanguage(language, forKey: .language)
        case let .code(code):
            try c.encode(Kind.code, forKey: .kind)
            try c.encode(code, forKey: .code)
        case let .codes(codes):
            try c.encode(Kind.codes, forKey: .kind)
            try c.encode(codes, forKey: .codes)
        case let .phone(digits):
            try c.encode(Kind.phone, forKey: .kind)
            try c.encode(digits, forKey: .digits)
        case let .date(date):
            try c.encode(Kind.date, forKey: .kind)
            try c.encode(date, forKey: .date)
        case let .money(amount, currency):
            try c.encode(Kind.money, forKey: .kind)
            try c.encode(amount, forKey: .amount)
            try c.encode(currency, forKey: .currency)
        case let .quantity(amount, unit):
            try c.encode(Kind.quantity, forKey: .kind)
            try c.encode(amount, forKey: .amount)
            try c.encode(unit, forKey: .unit)
        case let .weekdays(days):
            try c.encode(Kind.weekdays, forKey: .kind)
            // Sorted by raw value only for stable output; this is not a week order.
            try c.encode(days.sorted { $0.rawValue < $1.rawValue }, forKey: .days)
        case let .place(place):
            try c.encode(Kind.place, forKey: .kind)
            try c.encode(place, forKey: .place)
        case let .flag(value):
            try c.encode(Kind.flag, forKey: .kind)
            try c.encode(value, forKey: .value)
        }
    }
}

public enum FactError: Error, Equatable, Sendable {
    case missingValue(FactID)
    case missingSource(FactID)
    case missingRetrievedAt(FactID)
    case missingQuote(FactID)
}

/// One ledger fact as the app sees it. ADCore never constructs facts with real values;
/// they arrive from the ledger through `FactResolving`.
public struct Fact: Hashable, Sendable, Identifiable {
    public let id: FactID
    /// Stored for ledger round-trip. Not public: callers read `displayValue`, which is
    /// nil for unsourced facts, so an unsourced claim cannot reach the screen by accident.
    let value: FactValue?
    public let source: Source?
    /// The quoted source text, and its language so VoiceOver can switch voice.
    public let quote: String?
    public let quoteLanguage: Locale.Language?
    public let retrievedAt: Date?
    public let status: FactStatus
    /// Ledger `check_every`, in days. Format is an open question for Research.
    public let checkEveryDays: Int?

    /// Invariants: verified/stale need value, source, quote, retrievedAt (hard rule 1).
    /// demo needs a value (and is labeled demo in the UI). unsourced needs nothing.
    public init(
        id: FactID,
        value: FactValue?,
        source: Source?,
        quote: String?,
        quoteLanguage: Locale.Language?,
        retrievedAt: Date?,
        status: FactStatus,
        checkEveryDays: Int? = nil
    ) throws(FactError) {
        switch status {
        case .verified, .stale:
            guard value != nil else { throw .missingValue(id) }
            guard source != nil else { throw .missingSource(id) }
            guard let quote, !quote.isEmpty else { throw .missingQuote(id) }
            guard retrievedAt != nil else { throw .missingRetrievedAt(id) }
        case .demo:
            guard value != nil else { throw .missingValue(id) }
        case .unsourced:
            break
        }
        self.init(unchecked: id, value: value, source: source, quote: quote, quoteLanguage: quoteLanguage,
                  retrievedAt: retrievedAt, status: status, checkEveryDays: checkEveryDays)
    }

    /// Bypasses validation. Internal: only tests use it, to prove the display backstop.
    init(unchecked id: FactID, value: FactValue?, source: Source?, quote: String?, quoteLanguage: Locale.Language?,
         retrievedAt: Date?, status: FactStatus, checkEveryDays: Int?) {
        self.id = id
        self.value = value
        self.source = source
        self.quote = quote
        self.quoteLanguage = quoteLanguage
        self.retrievedAt = retrievedAt
        self.status = status
        self.checkEveryDays = checkEveryDays
    }

    /// A verified fact past `retrievedAt + checkEvery` reads as stale on-device, even
    /// before the next ledger sync marks it.
    public func status(asOf now: Date) -> FactStatus {
        guard status == .verified, let retrievedAt, let days = checkEveryDays else { return status }
        let due = retrievedAt.addingTimeInterval(TimeInterval(days) * 86_400)
        return now > due ? .stale : .verified
    }

    /// The value the UI and voice may show. Nil when unsourced.
    public var displayValue: FactValue? { status == .unsourced ? nil : value }

    /// True when the evidence matches the status (the init's invariant).
    var hasRequiredEvidence: Bool {
        switch status {
        case .verified, .stale: value != nil && source != nil && !(quote ?? "").isEmpty && retrievedAt != nil
        case .demo: value != nil
        case .unsourced: true
        }
    }
}

extension Fact: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, value, source, quote, quoteLanguage, retrievedAt, status, checkEveryDays
    }

    /// Decodes raw fields, then runs the validating init: a "verified" fact without its
    /// evidence fails to decode instead of displaying as verified.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(FactID.self, forKey: .id),
            value: c.decodeIfPresent(FactValue.self, forKey: .value),
            source: c.decodeIfPresent(Source.self, forKey: .source),
            quote: c.decodeIfPresent(String.self, forKey: .quote),
            quoteLanguage: c.decodeLanguageIfPresent(forKey: .quoteLanguage),
            retrievedAt: c.decodeIfPresent(Date.self, forKey: .retrievedAt),
            status: c.decode(FactStatus.self, forKey: .status),
            checkEveryDays: c.decodeIfPresent(Int.self, forKey: .checkEveryDays))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(quote, forKey: .quote)
        try c.encodeLanguageIfPresent(quoteLanguage, forKey: .quoteLanguage)
        try c.encodeIfPresent(retrievedAt, forKey: .retrievedAt)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(checkEveryDays, forKey: .checkEveryDays)
    }
}

// MARK: - Lookup outcome (accepted by Lead: FactRef, FactOutcome.notApplicable(reason:deferTo:))

/// Points at a ledger fact in a region pack.
/// Wire JSON (ARCHITECTURE.md §13.z): {"pack_id":"us-fl-miami","fact_id":"us-fl-miami.trash.day"}.
public struct FactRef: Hashable, Codable, Sendable {
    /// e.g. "us-fl-miami"
    public let regionPackID: RegionPackID
    public let ledgerFactID: FactID

    public init(regionPackID: RegionPackID, ledgerFactID: FactID) {
        self.regionPackID = regionPackID
        self.ledgerFactID = ledgerFactID
    }

    private enum CodingKeys: String, CodingKey {
        case regionPackID = "pack_id"
        case ledgerFactID = "fact_id"
    }
}

/// Result of asking for a fact at a pin. "Not applicable here" is not a Fact status:
/// e.g. the county trash layer inside the City of Miami, which hauls its own.
/// Wire JSON is a tagged union, never a nullable value:
/// {"type":"fact","fact":{...}}, {"type":"not_applicable","reason":{...},"defer_to":{...}},
/// {"type":"unsourced","desk":{...}}, {"type":"unavailable","desk":{...}}.
public enum FactOutcome: Hashable, Sendable {
    case fact(Fact)
    case notApplicable(reason: StringKey, deferTo: FactRef?)
    /// No source exists for this fact. The card names the desk.
    case unsourced(desk: Desk)
    /// A source exists but could not be reached right now. The card names the desk and shows
    /// no value: a cached value appears only as a sourced `Fact` with status `.stale`.
    case unavailable(desk: Desk)
}

extension FactOutcome: Codable {
    private enum Tag: String, Codable {
        case fact, notApplicable = "not_applicable", unsourced, unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case type, fact, reason, deferTo = "defer_to", desk
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .fact: self = .fact(try c.decode(Fact.self, forKey: .fact))
        case .notApplicable:
            self = .notApplicable(reason: try c.decode(StringKey.self, forKey: .reason),
                                  deferTo: try c.decodeIfPresent(FactRef.self, forKey: .deferTo))
        case .unsourced: self = .unsourced(desk: try c.decode(Desk.self, forKey: .desk))
        case .unavailable: self = .unavailable(desk: try c.decode(Desk.self, forKey: .desk))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fact(let fact):
            try c.encode(Tag.fact, forKey: .type)
            try c.encode(fact, forKey: .fact)
        case let .notApplicable(reason, deferTo):
            try c.encode(Tag.notApplicable, forKey: .type)
            try c.encode(reason, forKey: .reason)
            try c.encodeIfPresent(deferTo, forKey: .deferTo)
        case .unsourced(let desk):
            try c.encode(Tag.unsourced, forKey: .type)
            try c.encode(desk, forKey: .desk)
        case .unavailable(let desk):
            try c.encode(Tag.unavailable, forKey: .type)
            try c.encode(desk, forKey: .desk)
        }
    }
}

/// Fact lookup for the current pin. Implemented outside ADCore (ledger + region packs).
/// Returns nil when the id is unknown; ADCore then hands the card to its desk.
public protocol FactResolving: Sendable {
    func outcome(for id: FactID) -> FactOutcome?
}
