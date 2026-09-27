import Foundation
import ADCore

// Wire format for the intent contract (ARCHITECTURE.md §13.2, §13.z): tagged JSON with a "type"
// discriminator, snake_case keys spelled out explicitly, BCP-47 language strings, ids as plain strings.
//
// Every key is written by hand in this file's helpers, so use a PLAIN JSONEncoder/JSONDecoder
// (`IntentWire.encoder` / `.decoder`). A `convertFromSnakeCase` key strategy would break decoding,
// because it rewrites "card_id" to "cardId" before matching the explicit keys.

public enum IntentWire {
    /// Plain encoder: sorted keys so output is stable; no key strategy.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// Plain decoder: no key strategy.
    public static var decoder: JSONDecoder { JSONDecoder() }
}

/// A string coding key, so every wire key is spelled exactly once, at the call site.
struct WireKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { self.stringValue = value }
}

typealias WireEncoding = KeyedEncodingContainer<WireKey>
typealias WireDecoding = KeyedDecodingContainer<WireKey>

extension KeyedEncodingContainer where K == WireKey {
    mutating func put<T: Encodable>(_ value: T, _ key: WireKey) throws { try encode(value, forKey: key) }

    /// Optionals are always written, as JSON null when absent, so goldens show every field.
    mutating func putNullable<T: Encodable>(_ value: T?, _ key: WireKey) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    mutating func putID<T: StringIdentifier>(_ id: T, _ key: WireKey) throws { try encode(id.rawValue, forKey: key) }
    mutating func putID<T: StringIdentifier>(_ id: T?, _ key: WireKey) throws { try putNullable(id?.rawValue, key) }
    mutating func putPerson(_ id: PersonID, _ key: WireKey) throws { try encode(id.rawValue.uuidString, forKey: key) }
    mutating func putPerson(_ id: PersonID?, _ key: WireKey) throws { try putNullable(id?.rawValue.uuidString, key) }
    mutating func putKey(_ value: StringKey, _ key: WireKey) throws { try encode(WireStringKey(value), forKey: key) }
    mutating func putRef(_ value: FactRef, _ key: WireKey) throws { try encode(WireFactRef(value), forKey: key) }
}

extension KeyedDecodingContainer where K == WireKey {
    func get<T: Decodable>(_ type: T.Type, _ key: WireKey) throws -> T { try decode(type, forKey: key) }
    func getNullable<T: Decodable>(_ type: T.Type, _ key: WireKey) throws -> T? { try decodeIfPresent(type, forKey: key) }
    func getID<T: StringIdentifier>(_ type: T.Type, _ key: WireKey) throws -> T {
        T(rawValue: try decode(String.self, forKey: key))
    }
    func getNullableID<T: StringIdentifier>(_ type: T.Type, _ key: WireKey) throws -> T? {
        try decodeIfPresent(String.self, forKey: key).map(T.init(rawValue:))
    }
    func getPerson(_ key: WireKey) throws -> PersonID {
        let raw = try decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a UUID: \(raw)")
        }
        return PersonID(uuid)
    }
    func getNullablePerson(_ key: WireKey) throws -> PersonID? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try getPerson(key)
    }
    func getKey(_ key: WireKey) throws -> StringKey { try decode(WireStringKey.self, forKey: key).value }
    func getRef(_ key: WireKey) throws -> FactRef { try decode(WireFactRef.self, forKey: key).value }
    func type(_ key: WireKey = "type") throws -> String { try decode(String.self, forKey: key) }
}

func unknownType(_ c: WireDecoding, _ value: String) -> DecodingError {
    DecodingError.dataCorruptedError(forKey: "type", in: c, debugDescription: "unknown type \"\(value)\"")
}

/// `{"key": ..., "table": ...}`
struct WireStringKey: Codable {
    let value: StringKey
    init(_ value: StringKey) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        value = StringKey(key: try c.get(String.self, "key"), table: try c.get(String.self, "table"))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.put(value.key, "key")
        try c.put(value.table, "table")
    }
}

/// `{"pack_id": ..., "fact_id": ...}` (ARCHITECTURE.md §13.z). Written here so the router's wire
/// shape does not depend on how ADCore spells its own CodingKeys.
struct WireFactRef: Codable {
    let value: FactRef
    init(_ value: FactRef) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        value = FactRef(regionPackID: try c.getID(RegionPackID.self, "pack_id"),
                        ledgerFactID: try c.getID(FactID.self, "fact_id"))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putID(value.regionPackID, "pack_id")
        try c.putID(value.ledgerFactID, "fact_id")
    }
}
