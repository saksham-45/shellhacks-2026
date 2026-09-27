import Foundation
import ADCore

/// One fact result from server/regionpacks (CONTRACT.md §2), decoded as sent (snake_case keys).
public struct RegionFactResult: Hashable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable {
        case ok
        case notApplicable = "not_applicable"
        /// The source exists but could not be reached or timed out.
        case unavailable
        /// The source answered with something unusable (e.g. an unmapped TRASHDAY code).
        case error
        /// No source exists yet.
        case unsourced
    }

    public struct NotApplicable: Hashable, Codable, Sendable {
        public var reason: String
        public var deferTo: FactRef?
        private enum CodingKeys: String, CodingKey { case reason, deferTo = "defer_to" }
    }

    public struct Basis: Hashable, Codable, Sendable {
        /// "device_coords", "county_locator" or "census_geocoder": how the pin became a point.
        public var method: String?
        /// "point_in_polygon", "address_match", "nearest_polygon", "buffer_then_haversine", ...
        public var lookup: String?
        /// Straight-line metres from the pin, where the lookup measures one.
        public var distanceM: Double?
        private enum CodingKeys: String, CodingKey { case method, lookup, distanceM = "distance_m" }
    }

    /// Stable lookup id (the address cards and the router use).
    public var factID: FactID
    /// Ledger entry behind this answer: `<fact_id>.demo.<pin>` for fixtures, equal to `factID` live.
    public var ledgerID: String
    public var pack: RegionPackID
    public var status: Status
    public var isDemo: Bool
    public var value: RegionValue?
    public var sourceID: SourceID?
    public var publisher: String?
    public var url: String?
    public var retrievedAt: String?
    public var quote: String?
    public var jurisdiction: RegionPackID
    public var desk: DeskID
    public var basis: Basis?
    public var notApplicable: NotApplicable?
    public var error: String?
    public var checkEvery: String?

    private enum CodingKeys: String, CodingKey {
        case factID = "fact_id", ledgerID = "ledger_id", pack, status, isDemo = "is_demo", value
        case sourceID = "source_id", publisher, url, retrievedAt = "retrieved_at", quote, jurisdiction, desk, basis
        case notApplicable = "not_applicable", error, checkEvery = "check_every"
    }
}

/// The wire value: exactly ADCore's ten FactValue cases, tagged by `type` (ARCHITECTURE.md §13.z).
/// Any other tag fails to decode.
public enum RegionValue: Hashable, Codable, Sendable {
    case text(String, language: String)
    case code(String)
    case codes([String])
    case phone(digits: String)
    case date(String)
    case money(amount: Decimal, currency: String)
    case quantity(amount: Decimal, unit: String)
    case weekdays([String])
    case place(name: String, lat: Double, lon: Double, address: String?)
    case flag(Bool)

    private enum Tag: String, Codable { case text, code, codes, phone, date, money, quantity, weekdays, place, flag }
    private enum CodingKeys: String, CodingKey {
        case type, text, language, code, codes, digits, date, amount, currency, value, unit, days, place
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .text: self = .text(try c.decode(String.self, forKey: .text), language: try c.decode(String.self, forKey: .language))
        case .code: self = .code(try c.decode(String.self, forKey: .code))
        case .codes: self = .codes(try c.decode([String].self, forKey: .codes))
        case .phone: self = .phone(digits: try c.decode(String.self, forKey: .digits))
        case .date: self = .date(try c.decode(String.self, forKey: .date))
        case .money: self = .money(amount: try c.decode(Decimal.self, forKey: .amount), currency: try c.decode(String.self, forKey: .currency))
        case .quantity: self = .quantity(amount: try c.decode(Decimal.self, forKey: .amount), unit: try c.decode(String.self, forKey: .unit))
        case .weekdays: self = .weekdays(try c.decode([String].self, forKey: .days))
        case .place:
            let p = try c.decode(WirePlace.self, forKey: .place)
            self = .place(name: p.name, lat: p.coordinate.latitude, lon: p.coordinate.longitude, address: p.address)
        case .flag: self = .flag(try c.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(t, lang): try c.encode(Tag.text, forKey: .type); try c.encode(t, forKey: .text); try c.encode(lang, forKey: .language)
        case let .code(v): try c.encode(Tag.code, forKey: .type); try c.encode(v, forKey: .code)
        case let .codes(v): try c.encode(Tag.codes, forKey: .type); try c.encode(v, forKey: .codes)
        case let .phone(d): try c.encode(Tag.phone, forKey: .type); try c.encode(d, forKey: .digits)
        case let .date(d): try c.encode(Tag.date, forKey: .type); try c.encode(d, forKey: .date)
        case let .money(a, cur): try c.encode(Tag.money, forKey: .type); try c.encode(a, forKey: .amount); try c.encode(cur, forKey: .currency)
        case let .quantity(v, u): try c.encode(Tag.quantity, forKey: .type); try c.encode(v, forKey: .amount); try c.encode(u, forKey: .unit)
        case let .weekdays(d): try c.encode(Tag.weekdays, forKey: .type); try c.encode(d, forKey: .days)
        case let .place(n, lat, lon, a):
            try c.encode(Tag.place, forKey: .type)
            try c.encode(WirePlace(name: n, coordinate: .init(latitude: lat, longitude: lon), address: a), forKey: .place)
        case let .flag(v): try c.encode(Tag.flag, forKey: .type); try c.encode(v, forKey: .value)
        }
    }

    /// /v1 PlaceValue body: {name, coordinate: {latitude, longitude}, address}.
    private struct WirePlace: Codable {
        struct Coord: Codable { var latitude: Double; var longitude: Double }
        var name: String
        var coordinate: Coord
        var address: String?
    }

    /// ADCore's value. Nil when the wire value cannot be represented faithfully (bad date, unknown weekday).
    public var factValue: FactValue? {
        switch self {
        case let .text(t, lang): return .text(t, language: Locale.Language(identifier: lang))
        case let .code(v): return .code(v)
        case let .codes(v): return .codes(v)
        case let .phone(d): return .phone(digits: d)
        case let .date(d): return RegionDates.day(d).map(FactValue.date)
        case let .money(a, cur): return .money(amount: a, currency: cur)
        case let .quantity(v, u): return .quantity(v, unit: u)
        case let .weekdays(d):
            let days = d.compactMap(Weekday.init(rawValue:))
            return days.count == d.count && !days.isEmpty ? .weekdays(Set(days)) : nil
        case let .place(n, lat, lon, a): return .place(Place(name: n, coordinate: Coordinate(latitude: lat, longitude: lon), address: a))
        case let .flag(v): return .flag(v)
        }
    }
}

enum RegionDates {
    /// ISO 8601 with offset, e.g. "2026-09-25T17:19:00-04:00".
    static func timestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func day(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    /// "P30D" -> 30. Other durations are not guessed.
    static func days(_ iso: String?) -> Int? {
        guard let iso, iso.hasPrefix("P"), iso.hasSuffix("D") else { return nil }
        return Int(iso.dropFirst().dropLast())
    }
}

/// Maps a server result to ADCore's FactOutcome. The only place that decision is made.
public enum RegionOutcomeMapper {
    public static func outcome(for r: RegionFactResult) -> FactOutcome {
        let desk = Desk(id: r.desk, regionPack: r.pack)
        switch r.status {
        case .ok:
            guard let value = r.value?.factValue, let sourceID = r.sourceID, let publisher = r.publisher,
                  let urlString = r.url, let url = URL(string: urlString),
                  let retrievedAt = RegionDates.timestamp(r.retrievedAt) else {
                return .unavailable(desk: desk)  // a value without its evidence never reaches the screen
            }
            do {
                let fact = try Fact(id: r.factID, value: value,
                                    source: Source(id: sourceID, url: url, publisher: publisher),
                                    quote: r.quote, quoteLanguage: Locale.Language(identifier: "en"),
                                    retrievedAt: retrievedAt, status: r.isDemo ? .demo : .verified,
                                    checkEveryDays: RegionDates.days(r.checkEvery))
                return .fact(fact)
            } catch {
                return .unavailable(desk: desk)
            }
        case .notApplicable:
            guard let na = r.notApplicable else { return .unavailable(desk: desk) }
            return .notApplicable(reason: RegionStrings.key(na.reason), deferTo: na.deferTo)
        case .unsourced:
            return .unsourced(desk: desk)
        case .unavailable, .error:
            return .unavailable(desk: desk)
        }
    }
}

/// The server's answers for one pin: pack membership plus every fact result.
public struct RegionPinAnswers: Hashable, Codable, Sendable {
    public struct PinInfo: Hashable, Codable, Sendable {
        public var address: String?
        public var lat: Double
        public var lon: Double
    }

    public var pinID: PinID
    public var pin: PinInfo
    public var packIDs: [RegionPackID]
    public var results: [RegionFactResult]

    private enum CodingKeys: String, CodingKey { case pinID = "pin_id", pin, packIDs = "pack_ids", results }

    public var asPin: Pin { Pin(latitude: pin.lat, longitude: pin.lon, address: pin.address) }

    func matches(_ other: Pin) -> Bool {
        abs(other.latitude - pin.lat) < 1e-6 && abs(other.longitude - pin.lon) < 1e-6
    }
}
