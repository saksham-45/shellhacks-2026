import Foundation

public struct HouseholdID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Onboarding question 1: where they are sleeping, or where the pin is (ARCHITECTURE.md §3 shape).
/// Which region packs apply is resolved by ADCityPack, not stored here.
public struct Pin: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Free-text address as typed or said. Never used for resolution alone.
    public var address: String?

    public init(latitude: Double, longitude: Double, address: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }

    /// Finite and inside the lat/lon ranges.
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// Household-scoped inputs the user may give (myMiami household record). All optional.
/// These are the user's own answers, not facts.
public struct SharedHousehold: Hashable, Codable, Sendable {
    public var hasCar: Bool?
    public var hasTollSticker: Bool?
    /// Only if they want the rent line.
    public var annualIncome: Decimal?
    public var usualDrive: Pin?

    public init(hasCar: Bool? = nil, hasTollSticker: Bool? = nil, annualIncome: Decimal? = nil, usualDrive: Pin? = nil) {
        self.hasCar = hasCar
        self.hasTollSticker = hasTollSticker
        self.annualIncome = annualIncome
        self.usualDrive = usualDrive
    }
}

public enum HouseholdError: Error, Equatable, Sendable {
    case duplicatePerson(PersonID)
}

/// The household: a shared pin plus separate people, each on their own path.
public struct Household: Hashable, Sendable, Identifiable {
    public let id: HouseholdID
    /// The name they want on the card.
    public var name: String?
    public var pin: Pin?
    public var homeLanguage: Locale.Language?
    public var shared: SharedHousehold
    public private(set) var people: [Person]

    public init(id: HouseholdID = HouseholdID(), name: String? = nil, pin: Pin? = nil,
                homeLanguage: Locale.Language? = nil, shared: SharedHousehold = SharedHousehold(),
                people: [Person] = []) throws(HouseholdError) {
        self.id = id
        self.name = name
        self.pin = pin
        self.homeLanguage = homeLanguage.map(Locale.Language.normalized)
        self.shared = shared
        self.people = []
        for person in people { try add(person) }
    }

    /// BCP-47 tag of the home language, if set.
    public var homeLanguageTag: String? { homeLanguage?.minimalIdentifier }

    public func person(_ id: PersonID) -> Person? { people.first { $0.id == id } }

    /// Adding a person adds a path and a card.
    public mutating func add(_ person: Person) throws(HouseholdError) {
        guard self.person(person.id) == nil else { throw .duplicatePerson(person.id) }
        people.append(person)
    }

    public mutating func remove(_ id: PersonID) {
        people.removeAll { $0.id == id }
    }

    /// Edit one person in place; Person's own methods keep stage/mode invariants.
    @discardableResult
    public mutating func update<E: Error>(_ id: PersonID, _ body: (inout Person) throws(E) -> Void) throws(E) -> Bool {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return false }
        try body(&people[index])
        return true
    }

    /// The household card is in tourist mode only when everyone in it is a tourist.
    public var mode: Mode {
        !people.isEmpty && people.allSatisfy { $0.mode == .tourist } ? .tourist : .resident
    }
}

extension Household: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, pin, homeLanguage, shared, people }

    /// Rejects duplicate person ids; each Person re-checks its own mode/stage invariant.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        do {
            try self.init(
                id: c.decode(HouseholdID.self, forKey: .id),
                name: c.decodeIfPresent(String.self, forKey: .name),
                pin: c.decodeIfPresent(Pin.self, forKey: .pin),
                homeLanguage: c.decodeLanguageIfPresent(forKey: .homeLanguage),
                shared: c.decodeIfPresent(SharedHousehold.self, forKey: .shared) ?? SharedHousehold(),
                people: people)
        } catch let error as HouseholdError {
            throw DecodingError.dataCorruptedError(forKey: .people, in: c, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(pin, forKey: .pin)
        try c.encodeLanguageIfPresent(homeLanguage, forKey: .homeLanguage)
        try c.encode(shared, forKey: .shared)
        try c.encode(people, forKey: .people)
    }
}
