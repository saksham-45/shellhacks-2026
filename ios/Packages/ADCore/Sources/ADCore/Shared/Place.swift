// Accepted by Lead (Place, Coordinate, Weekday). No CoreLocation, so these build on Linux.

public struct Coordinate: Hashable, Codable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A named place (school, office, gantry). The name is a proper noun: never translated.
public struct Place: Hashable, Codable, Sendable {
    public let name: String
    public let coordinate: Coordinate
    public let address: String?

    public init(name: String, coordinate: Coordinate, address: String? = nil) {
        self.name = name
        self.coordinate = coordinate
        self.address = address
    }
}

/// A day of the week for recurring facts (trash pickup). Plain identifiers only: no display
/// names, no localized strings, no first day of the week (`allCases` order means nothing).
/// All wording lives in ADLocale's catalogs.
public enum Weekday: String, Hashable, Codable, Sendable, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday
}
