// Shared types (ARCHITECTURE.md §12: ADCore's Shared/ is the contract). Everything in
// Sources/ADCore/Shared/ is replaceable as one directory.

/// A stable string identifier. Values come from other owners (content card registry,
/// research ledger, region pack manifests); ADCore only carries them. Encodes as a plain string.
public protocol StringIdentifier: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible where RawValue == String
{
    init(rawValue: String)
}

extension StringIdentifier {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }
}

/// A card registry entry id (content/cards/<id>.yaml).
public struct CardID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A research ledger fact id: dotted, lowercase, first segment is the pack id
/// ("us-fl-miamidade.311.phone").
public struct FactID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A source registry id (research/sources.yaml).
public struct SourceID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A desk id, region-scoped like facts ("us-fl-miamidade.311").
public struct DeskID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The one region pack id type. Packs nest country > state > county > city:
/// "us", "us-fl", "us-fl-miamidade", "us-fl-miami". On the wire it is this string.
public struct RegionPackID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
