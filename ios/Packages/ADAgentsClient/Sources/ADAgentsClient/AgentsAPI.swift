import ADCore
import ADLocale
import ADRouter
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// This file is the typed, snake_case /v1 wire surface. The response value types are local because
// the server's JSON discriminator is `type` (ADCore's internal FactValue uses `kind`) and the
// server's Place carries an optional language.

public enum AgentsClientError: Error, Sendable, Equatable {
  case invalidBaseURL
  case invalidResponse
  case http(status: Int)
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

/// Reject contract drift instead of silently discarding fields added by the server.
private func rejectUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
  let container = try decoder.container(keyedBy: AnyCodingKey.self)
  let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
  guard unknown.isEmpty else {
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: container.codingPath,
        debugDescription: "unknown keys: \(unknown.sorted().joined(separator: ", "))"
      ))
  }
}

/// URLSession-shaped transport injection. Tests can provide an actor-backed stub and never open a socket.
public protocol AgentsTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: AgentsTransport, Sendable {
  public let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

public struct AgentPin: Hashable, Codable, Sendable {
  public var address: String
  public var lat: Double?
  public var lon: Double?

  public init(address: String, lat: Double? = nil, lon: Double? = nil) {
    self.address = address
    self.lat = lat
    self.lon = lon
  }

  private enum CodingKeys: String, CodingKey { case address, lat, lon }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    address = try c.decode(String.self, forKey: .address)
    lat = try c.decodeIfPresent(Double.self, forKey: .lat)
    lon = try c.decodeIfPresent(Double.self, forKey: .lon)
    guard (lat == nil) == (lon == nil) else {
      throw DecodingError.dataCorruptedError(
        forKey: .lat, in: c, debugDescription: "lat and lon must appear together")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(address, forKey: .address)
    try c.encode(lat, forKey: .lat)
    try c.encode(lon, forKey: .lon)
  }
}

public struct HouseholdMoney: Hashable, Codable, Sendable {
  public var amount: Double
  public var currency: String
  public init(amount: Double, currency: String) {
    self.amount = amount
    self.currency = currency
  }
}

public struct HouseholdCar: Hashable, Codable, Sendable {
  public var gantryIDs: [String]
  public init(gantryIDs: [String] = []) { self.gantryIDs = gantryIDs }
  private enum CodingKeys: String, CodingKey { case gantryIDs = "gantry_ids" }
}

public struct HouseholdInputs: Hashable, Codable, Sendable {
  public var homeLanguage: String?
  public var rent: HouseholdMoney?
  public var car: HouseholdCar?
  public var childAges: [Int]

  public init(
    homeLanguage: String? = nil, rent: HouseholdMoney? = nil,
    car: HouseholdCar? = nil, childAges: [Int] = []
  ) {
    self.homeLanguage = homeLanguage
    self.rent = rent
    self.car = car
    self.childAges = childAges
  }

  private enum CodingKeys: String, CodingKey {
    case homeLanguage = "home_language"
    case rent, car
    case childAges = "child_ages"
  }
}

public struct HouseholdWeekRequest: Hashable, Codable, Sendable {
  public var requestID: String?
  public var pin: AgentPin
  public var surfaceLanguage: SurfaceLanguage
  public var thinkIn: String?
  public var mode: Mode
  public var household: HouseholdInputs

  public init(
    requestID: String? = nil, pin: AgentPin, surfaceLanguage: SurfaceLanguage,
    thinkIn: String? = nil, mode: Mode, household: HouseholdInputs = HouseholdInputs()
  ) {
    self.requestID = requestID
    self.pin = pin
    self.surfaceLanguage = surfaceLanguage
    self.thinkIn = thinkIn
    self.mode = mode
    self.household = household
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case pin
    case surfaceLanguage = "surface_language"
    case thinkIn = "think_in"
    case mode, household
  }
}

public struct PersonContext: Hashable, Codable, Sendable {
  public var personID: String
  public var age: Int?
  public var originLenses: [OriginLens]
  public var stage: Stage
  public var mode: Mode
  public var goal: Goal
  public var statusWord: String?

  public init(
    personID: String, age: Int? = nil, originLenses: [OriginLens] = [], stage: Stage,
    mode: Mode, goal: Goal, statusWord: String? = nil
  ) {
    self.personID = personID
    self.age = age
    self.originLenses = originLenses
    self.stage = stage
    self.mode = mode
    self.goal = goal
    self.statusWord = statusWord
  }

  private enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case age
    case originLenses = "origin_lenses"
    case stage, mode, goal
    case statusWord = "status_word"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(personID, forKey: .personID)
    try c.encode(age, forKey: .age)
    try c.encode(originLenses, forKey: .originLenses)
    try c.encode(stage, forKey: .stage)
    try c.encode(mode, forKey: .mode)
    try c.encode(goal, forKey: .goal)
    try c.encode(statusWord, forKey: .statusWord)
  }
}

public struct PersonNextStepsRequest: Hashable, Codable, Sendable {
  public var requestID: String?
  public var person: PersonContext
  public var pin: AgentPin?
  public var surfaceLanguage: SurfaceLanguage
  public var thinkIn: String?

  public init(
    requestID: String? = nil, person: PersonContext, pin: AgentPin? = nil,
    surfaceLanguage: SurfaceLanguage, thinkIn: String? = nil
  ) {
    self.requestID = requestID
    self.person = person
    self.pin = pin
    self.surfaceLanguage = surfaceLanguage
    self.thinkIn = thinkIn
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case person, pin
    case surfaceLanguage = "surface_language"
    case thinkIn = "think_in"
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(requestID, forKey: .requestID)
    try c.encode(person, forKey: .person)
    try c.encode(pin, forKey: .pin)
    try c.encode(surfaceLanguage, forKey: .surfaceLanguage)
    try c.encode(thinkIn, forKey: .thinkIn)
  }
}

public struct WireFactRef: Hashable, Codable, Sendable {
  public var packID: String
  public var factID: String
  public init(packID: String, factID: String) {
    self.packID = packID
    self.factID = factID
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case packID = "pack_id"
    case factID = "fact_id"
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    packID = try c.decode(String.self, forKey: .packID)
    factID = try c.decode(String.self, forKey: .factID)
    guard factID.hasPrefix(packID + ".") else {
      throw DecodingError.dataCorruptedError(
        forKey: .factID, in: c, debugDescription: "fact_id must belong to pack_id")
    }
  }
}

public struct WireCoordinate: Hashable, Codable, Sendable {
  public var latitude: Double
  public var longitude: Double
  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
  private enum CodingKeys: String, CodingKey, CaseIterable { case latitude, longitude }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    latitude = try c.decode(Double.self, forKey: .latitude)
    longitude = try c.decode(Double.self, forKey: .longitude)
  }
}

/// Server Place. `language` is optional because a source may not identify the language.
public struct WirePlace: Hashable, Codable, Sendable {
  public var name: String
  public var coordinate: WireCoordinate
  public var address: String?
  public var language: String?
  public init(
    name: String, coordinate: WireCoordinate, address: String? = nil, language: String? = nil
  ) {
    self.name = name
    self.coordinate = coordinate
    self.address = address
    self.language = language
  }

  private enum CodingKeys: String, CodingKey, CaseIterable { case name, coordinate, address, language }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    name = try c.decode(String.self, forKey: .name)
    coordinate = try c.decode(WireCoordinate.self, forKey: .coordinate)
    address = try c.decodeIfPresent(String.self, forKey: .address)
    language = try c.decodeIfPresent(String.self, forKey: .language)
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(name, forKey: .name)
    try c.encode(coordinate, forKey: .coordinate)
    try c.encode(address, forKey: .address)
    try c.encodeIfPresent(language, forKey: .language)
  }
}

public typealias Place = WirePlace

public enum FactValue: Hashable, Codable, Sendable {
  case text(String, language: String)
  case code(String)
  case codes([String])
  case phone(digits: String)
  case date(Date)
  case money(amount: Decimal, currency: String)
  case quantity(Decimal, unit: String)
  case weekdays([Weekday])
  case place(WirePlace)
  case flag(Bool)

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case type, text, language, code, codes, digits, date, amount, currency, unit, days, place, value
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    let allowed: Set<String>
    switch type {
    case "text": allowed = ["type", "text", "language"]
    case "code": allowed = ["type", "code"]
    case "codes": allowed = ["type", "codes"]
    case "phone": allowed = ["type", "digits"]
    case "date": allowed = ["type", "date"]
    case "money": allowed = ["type", "amount", "currency"]
    case "quantity": allowed = ["type", "amount", "unit"]
    case "weekdays": allowed = ["type", "days"]
    case "place": allowed = ["type", "place"]
    case "flag": allowed = ["type", "value"]
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "unknown FactValue type \(type)")
    }
    try rejectUnknownKeys(decoder, allowed: allowed)
    switch type {
    case "text":
      self = .text(
        try c.decode(String.self, forKey: .text),
        language: try c.decode(String.self, forKey: .language))
    case "code": self = .code(try c.decode(String.self, forKey: .code))
    case "codes": self = .codes(try c.decode([String].self, forKey: .codes))
    case "phone": self = .phone(digits: try c.decode(String.self, forKey: .digits))
    case "date":
      let raw = try c.decode(String.self, forKey: .date)
      guard let date = Self.parseDate(raw) else {
        throw DecodingError.dataCorruptedError(
          forKey: .date, in: c, debugDescription: "date must be YYYY-MM-DD")
      }
      self = .date(date)
    case "money":
      self = .money(
        amount: try c.decode(Decimal.self, forKey: .amount),
        currency: try c.decode(String.self, forKey: .currency))
    case "quantity":
      self = .quantity(
        try c.decode(Decimal.self, forKey: .amount), unit: try c.decode(String.self, forKey: .unit))
    case "weekdays": self = .weekdays(try c.decode([Weekday].self, forKey: .days))
    case "place": self = .place(try c.decode(WirePlace.self, forKey: .place))
    case "flag": self = .flag(try c.decode(Bool.self, forKey: .value))
    default:
      // The discriminator was validated above; this is unreachable.
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "unknown FactValue type \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text, let language):
      try c.encode("text", forKey: .type)
      try c.encode(text, forKey: .text)
      try c.encode(language, forKey: .language)
    case .code(let code):
      try c.encode("code", forKey: .type)
      try c.encode(code, forKey: .code)
    case .codes(let codes):
      try c.encode("codes", forKey: .type)
      try c.encode(codes, forKey: .codes)
    case .phone(let digits):
      try c.encode("phone", forKey: .type)
      try c.encode(digits, forKey: .digits)
    case .date(let date):
      try c.encode("date", forKey: .type)
      try c.encode(Self.formatDate(date), forKey: .date)
    case .money(let amount, let currency):
      try c.encode("money", forKey: .type)
      try c.encode(amount, forKey: .amount)
      try c.encode(currency, forKey: .currency)
    case .quantity(let amount, let unit):
      try c.encode("quantity", forKey: .type)
      try c.encode(amount, forKey: .amount)
      try c.encode(unit, forKey: .unit)
    case .weekdays(let days):
      try c.encode("weekdays", forKey: .type)
      try c.encode(days, forKey: .days)
    case .place(let place):
      try c.encode("place", forKey: .type)
      try c.encode(place, forKey: .place)
    case .flag(let value):
      try c.encode("flag", forKey: .type)
      try c.encode(value, forKey: .value)
    }
  }

  private static func parseDate(_ raw: String) -> Date? {
    guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
      return nil
    }
    let parts = raw.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    guard let date = calendar.date(from: components) else { return nil }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    guard actual.year == components.year, actual.month == components.month,
      actual.day == components.day else {
      return nil
    }
    return date
  }

  private static func formatDate(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}

public enum WireFactStatus: String, Codable, Sendable { case verified, demo }

public enum JSONValue: Hashable, Codable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
      return
    }
    if let v = try? c.decode(Bool.self) {
      self = .bool(v)
      return
    }
    if let v = try? c.decode(Double.self) {
      self = .number(v)
      return
    }
    if let v = try? c.decode(String.self) {
      self = .string(v)
      return
    }
    if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
      return
    }
    self = .object(try c.decode([String: JSONValue].self))
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

public struct WireFact: Hashable, Codable, Sendable {
  public var factID: String
  public var packID: String
  public var value: FactValue
  public var status: WireFactStatus
  public var isDemo: Bool
  public var sourceID: String
  public var sourceName: String?
  public var sourceLanguage: String?
  public var url: String
  public var quote: String
  public var retrievedAt: String
  public var jurisdiction: String
  public var basis: [String: JSONValue]?

  public init(
    factID: String, packID: String, value: FactValue, status: WireFactStatus, isDemo: Bool,
    sourceID: String, sourceName: String? = nil, sourceLanguage: String? = nil, url: String,
    quote: String, retrievedAt: String, jurisdiction: String, basis: [String: JSONValue]? = nil
  ) {
    self.factID = factID
    self.packID = packID
    self.value = value
    self.status = status
    self.isDemo = isDemo
    self.sourceID = sourceID
    self.sourceName = sourceName
    self.sourceLanguage = sourceLanguage
    self.url = url
    self.quote = quote
    self.retrievedAt = retrievedAt
    self.jurisdiction = jurisdiction
    self.basis = basis
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case factID = "fact_id"
    case packID = "pack_id"
    case value, status
    case isDemo = "is_demo"
    case sourceID = "source_id"
    case
      sourceName = "source_name"
    case sourceLanguage = "source_language"
    case url, quote
    case retrievedAt = "retrieved_at"
    case jurisdiction, basis
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    factID = try c.decode(String.self, forKey: .factID)
    packID = try c.decode(String.self, forKey: .packID)
    value = try c.decode(FactValue.self, forKey: .value)
    status = try c.decode(WireFactStatus.self, forKey: .status)
    isDemo = try c.decode(Bool.self, forKey: .isDemo)
    guard isDemo == (status == .demo) else {
      throw DecodingError.dataCorruptedError(
        forKey: .isDemo, in: c, debugDescription: "is_demo must match status")
    }
    sourceID = try c.decode(String.self, forKey: .sourceID)
    sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
    sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
    url = try c.decode(String.self, forKey: .url)
    quote = try c.decode(String.self, forKey: .quote)
    retrievedAt = try c.decode(String.self, forKey: .retrievedAt)
    jurisdiction = try c.decode(String.self, forKey: .jurisdiction)
    basis = try c.decodeIfPresent([String: JSONValue].self, forKey: .basis)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(factID, forKey: .factID)
    try c.encode(packID, forKey: .packID)
    try c.encode(value, forKey: .value)
    try c.encode(status, forKey: .status)
    try c.encode(isDemo, forKey: .isDemo)
    try c.encode(sourceID, forKey: .sourceID)
    try c.encode(sourceName, forKey: .sourceName)
    try c.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
    try c.encode(url, forKey: .url)
    try c.encode(quote, forKey: .quote)
    try c.encode(retrievedAt, forKey: .retrievedAt)
    try c.encode(jurisdiction, forKey: .jurisdiction)
    try c.encode(basis, forKey: .basis)
  }
}

public enum FactOutcome: Hashable, Codable, Sendable {
  case fact(WireFact)
  case notApplicable(factID: String, reason: StringKey, deskID: String)
  case deferred(factID: String, reason: StringKey, deferTo: WireFactRef, deskID: String)
  case unsourced(factID: String, deskID: String)
  case unavailable(factID: String, deskID: String)

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case type, fact, factID = "fact_id", reason, deferTo = "defer_to", deskID = "desk_id"
  }
  private static func strictStringKey(
    _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) throws -> StringKey {
    let nested = try c.superDecoder(forKey: key)
    try rejectUnknownKeys(nested, allowed: ["key", "table"])
    return try StringKey(from: nested)
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    let allowed: Set<String> = switch type {
    case "fact": ["type", "fact"]
    case "not_applicable": ["type", "fact_id", "reason", "desk_id"]
    case "deferred": ["type", "fact_id", "reason", "defer_to", "desk_id"]
    case "unsourced", "unavailable": ["type", "fact_id", "desk_id"]
    default: throw DecodingError.dataCorruptedError(
      forKey: .type, in: c, debugDescription: "unknown FactOutcome type")
    }
    try rejectUnknownKeys(decoder, allowed: allowed)
    switch type {
    case "fact": self = .fact(try c.decode(WireFact.self, forKey: .fact))
    case "not_applicable":
      self = .notApplicable(
        factID: try c.decode(String.self, forKey: .factID),
        reason: try Self.strictStringKey(c, forKey: .reason),
        deskID: try c.decode(String.self, forKey: .deskID))
    case "deferred":
      self = .deferred(
        factID: try c.decode(String.self, forKey: .factID),
        reason: try Self.strictStringKey(c, forKey: .reason),
        deferTo: try c.decode(WireFactRef.self, forKey: .deferTo),
        deskID: try c.decode(String.self, forKey: .deskID))
    case "unsourced":
      self = .unsourced(
        factID: try c.decode(String.self, forKey: .factID),
        deskID: try c.decode(String.self, forKey: .deskID))
    case "unavailable":
      self = .unavailable(
        factID: try c.decode(String.self, forKey: .factID),
        deskID: try c.decode(String.self, forKey: .deskID))
    default: fatalError("FactOutcome type was validated above")
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .fact(let value):
      try c.encode("fact", forKey: .type)
      try c.encode(value, forKey: .fact)
    case .notApplicable(let id, let reason, let desk):
      try c.encode("not_applicable", forKey: .type)
      try c.encode(id, forKey: .factID)
      try c.encode(reason, forKey: .reason)
      try c.encode(desk, forKey: .deskID)
    case .deferred(let id, let reason, let ref, let desk):
      try c.encode("deferred", forKey: .type)
      try c.encode(id, forKey: .factID)
      try c.encode(reason, forKey: .reason)
      try c.encode(ref, forKey: .deferTo)
      try c.encode(desk, forKey: .deskID)
    case .unsourced(let id, let desk):
      try c.encode("unsourced", forKey: .type)
      try c.encode(id, forKey: .factID)
      try c.encode(desk, forKey: .deskID)
    case .unavailable(let id, let desk):
      try c.encode("unavailable", forKey: .type)
      try c.encode(id, forKey: .factID)
      try c.encode(desk, forKey: .deskID)
    }
  }
}

public struct Claim: Hashable, Codable, Sendable {
  public var copyKey: StringKey
  public var factRefs: [WireFactRef]
  public var deskID: String?
  public init(copyKey: StringKey, factRefs: [WireFactRef], deskID: String? = nil) {
    self.copyKey = copyKey
    self.factRefs = factRefs
    self.deskID = deskID
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case copyKey = "copy_key"
    case factRefs = "fact_refs"
    case deskID = "desk_id"
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    let copyKeyDecoder = try c.superDecoder(forKey: .copyKey)
    try rejectUnknownKeys(copyKeyDecoder, allowed: ["key", "table"])
    copyKey = try StringKey(from: copyKeyDecoder)
    factRefs = try c.decode([WireFactRef].self, forKey: .factRefs)
    deskID = try c.decodeIfPresent(String.self, forKey: .deskID)
  }
}

public struct Handoff: Hashable, Codable, Sendable {
  public var deskID: String
  public var reason: StringKey
  public var contact: [WireFactRef]
  public init(deskID: String, reason: StringKey, contact: [WireFactRef] = []) {
    self.deskID = deskID
    self.reason = reason
    self.contact = contact
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case deskID = "desk_id"
    case reason, contact
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    let reasonDecoder = try c.superDecoder(forKey: .reason)
    try rejectUnknownKeys(reasonDecoder, allowed: ["key", "table"])
    deskID = try c.decode(String.self, forKey: .deskID)
    reason = try StringKey(from: reasonDecoder)
    contact = try c.decode([WireFactRef].self, forKey: .contact)
  }
}

public struct WeekItem: Hashable, Codable, Sendable {
  public var cardID: String
  public var date: String?
  public var claims: [Claim]
  public init(cardID: String, date: String? = nil, claims: [Claim]) {
    self.cardID = cardID
    self.date = date
    self.claims = claims
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case cardID = "card_id"
    case date, claims
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    cardID = try c.decode(String.self, forKey: .cardID)
    date = try c.decodeIfPresent(String.self, forKey: .date)
    claims = try c.decode([Claim].self, forKey: .claims)
  }
}

private enum EnvelopeCodingKey: String, CodingKey {
  case requestID = "request_id"
  case language, facts, handoffs
  case hasDemo = "has_demo"
  case droppedClaims = "dropped_claims"
}

private struct DecodedEnvelopeFields {
  let requestID: String
  let language: String
  let facts: [String: FactOutcome]
  let handoffs: [Handoff]
  let hasDemo: Bool
  let droppedClaims: Int
}

extension FactOutcome {
  fileprivate var outcomeFactID: String {
    switch self {
    case .fact(let fact): return fact.factID
    case .notApplicable(let factID, _, _), .deferred(let factID, _, _, _),
      .unsourced(let factID, _), .unavailable(let factID, _):
      return factID
    }
  }
}

private func decodeEnvelopeFields(from decoder: any Decoder) throws -> DecodedEnvelopeFields {
  let c = try decoder.container(keyedBy: EnvelopeCodingKey.self)
  let facts = try c.decode([String: FactOutcome].self, forKey: .facts)
  for (key, outcome) in facts where key != outcome.outcomeFactID {
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: c.codingPath,
        debugDescription:
          "facts key \(key) does not match its outcome's fact_id \(outcome.outcomeFactID)"
      ))
  }
  let hasDemo = try c.decode(Bool.self, forKey: .hasDemo)
  let containsDemo = facts.values.contains { outcome in
    if case .fact(let fact) = outcome { return fact.status == .demo }
    return false
  }
  guard hasDemo == containsDemo else {
    throw DecodingError.dataCorruptedError(
      forKey: .hasDemo, in: c,
      debugDescription: "has_demo must be true exactly when a fact is demo")
  }
  let droppedClaims = try c.decode(Int.self, forKey: .droppedClaims)
  guard droppedClaims >= 0 else {
    throw DecodingError.dataCorruptedError(
      forKey: .droppedClaims, in: c, debugDescription: "dropped_claims must not be negative")
  }
  return DecodedEnvelopeFields(
    requestID: try c.decode(String.self, forKey: .requestID),
    language: try c.decode(String.self, forKey: .language),
    facts: facts,
    handoffs: try c.decode([Handoff].self, forKey: .handoffs),
    hasDemo: hasDemo,
    droppedClaims: droppedClaims
  )
}

public struct HouseholdWeekResponse: Hashable, Codable, Sendable {
  public var requestID: String
  public var language: String
  public var facts: [String: FactOutcome]
  public var handoffs: [Handoff]
  public var hasDemo: Bool
  public var droppedClaims: Int
  public var packIDs: [String]
  public var items: [WeekItem]
  public init(
    requestID: String, language: String, facts: [String: FactOutcome] = [:],
    handoffs: [Handoff] = [], hasDemo: Bool = false, droppedClaims: Int = 0, packIDs: [String],
    items: [WeekItem]
  ) {
    self.requestID = requestID
    self.language = language
    self.facts = facts
    self.handoffs = handoffs
    self.hasDemo = hasDemo
    self.droppedClaims = droppedClaims
    self.packIDs = packIDs
    self.items = items
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case requestID = "request_id"
    case language, facts, handoffs
    case hasDemo = "has_demo"
    case droppedClaims = "dropped_claims"
    case packIDs = "pack_ids"
    case items
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    let common = try decodeEnvelopeFields(from: decoder)
    requestID = common.requestID
    language = common.language
    facts = common.facts
    handoffs = common.handoffs
    hasDemo = common.hasDemo
    droppedClaims = common.droppedClaims
    packIDs = try c.decode([String].self, forKey: .packIDs)
    items = try c.decode([WeekItem].self, forKey: .items)
  }
}

public struct NextStep: Hashable, Codable, Sendable {
  public var cardID: String
  public var claims: [Claim]
  public init(cardID: String, claims: [Claim]) {
    self.cardID = cardID
    self.claims = claims
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case cardID = "card_id"
    case claims
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    cardID = try c.decode(String.self, forKey: .cardID)
    claims = try c.decode([Claim].self, forKey: .claims)
  }
}

public struct PersonNextStepsResponse: Hashable, Codable, Sendable {
  public var requestID: String
  public var language: String
  public var facts: [String: FactOutcome]
  public var handoffs: [Handoff]
  public var hasDemo: Bool
  public var droppedClaims: Int
  public var personID: String
  public var steps: [NextStep]
  public var originComparison: [Claim]
  public init(
    requestID: String, language: String, facts: [String: FactOutcome] = [:],
    handoffs: [Handoff] = [], hasDemo: Bool = false, droppedClaims: Int = 0, personID: String,
    steps: [NextStep], originComparison: [Claim] = []
  ) {
    self.requestID = requestID
    self.language = language
    self.facts = facts
    self.handoffs = handoffs
    self.hasDemo = hasDemo
    self.droppedClaims = droppedClaims
    self.personID = personID
    self.steps = steps
    self.originComparison = originComparison
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case requestID = "request_id"
    case language, facts, handoffs
    case hasDemo = "has_demo"
    case droppedClaims = "dropped_claims"
    case personID = "person_id"
    case steps
    case originComparison = "origin_comparison"
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
    let common = try decodeEnvelopeFields(from: decoder)
    requestID = common.requestID
    language = common.language
    facts = common.facts
    handoffs = common.handoffs
    hasDemo = common.hasDemo
    droppedClaims = common.droppedClaims
    personID = try c.decode(String.self, forKey: .personID)
    steps = try c.decode([NextStep].self, forKey: .steps)
    guard steps.count <= 3 else {
      throw DecodingError.dataCorruptedError(
        forKey: .steps, in: c, debugDescription: "steps must contain at most three items")
    }
    originComparison = try c.decode([Claim].self, forKey: .originComparison)
  }
}


// ADRouter owns IntentResolution's Codable implementation and intentionally has no strict-key mode.
// Validate the raw response here, before handing it to IntentWire.decoder.
func validateIntentResolutionResponse(_ data: Data) throws {
  let raw = try JSONSerialization.jsonObject(with: data)
  try validateIntentResolution(raw, path: "$" )
}

private func intentObject(_ raw: Any, allowed: Set<String>, path: String) throws -> [String: Any] {
  guard let object = raw as? [String: Any] else {
    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "expected object at \(path)"))
  }
  let unknown = Set(object.keys).subtracting(allowed)
  guard unknown.isEmpty else {
    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown intent keys at \(path): \(unknown.sorted())"))
  }
  return object
}

private func intentValue(_ object: [String: Any], _ key: String, path: String) -> Any? {
  object[key].flatMap { $0 is NSNull ? nil : $0 }
}

private func validateStringKey(_ raw: Any, path: String) throws {
  _ = try intentObject(raw, allowed: ["key", "table"], path: path)
}

private func validateFactRef(_ raw: Any, path: String) throws {
  _ = try intentObject(raw, allowed: ["pack_id", "fact_id"], path: path)
}

private func validateAppAction(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["type", "destination", "target", "desk_id", "language", "answer", "option_id", "pin_id", "mode", "value", "person_id", "person"], path: path)
  guard let type = base["type"] as? String else { return }
  let allowed: Set<String>
  switch type {
  case "navigate": allowed = ["type", "destination"]
  case "back", "home", "stop_speaking", "repeat_last", "next_step", "previous_step", "undo": allowed = ["type"]
  case "read_aloud":
    allowed = ["type", "target"]
    if let target = intentValue(base, "target", path: path) { try validateReadTarget(target, path: path + ".target") }
  case "call_desk": allowed = ["type", "desk_id"]
  case "open_map":
    allowed = ["type", "target"]
    if let target = intentValue(base, "target", path: path) { try validateMapTarget(target, path: path + ".target") }
  case "set_surface_language", "set_think_in": allowed = ["type", "language"]
  case "answer_onboarding":
    allowed = ["type", "answer"]
    if let answer = intentValue(base, "answer", path: path) { try validateOnboardingAnswer(answer, path: path + ".answer") }
  case "choose": allowed = ["type", "option_id"]
  case "set_pin": allowed = ["type", "pin_id"]
  case "set_mode": allowed = ["type", "mode"]
  case "confirm": allowed = ["type", "value"]
  case "delete_person": allowed = ["type", "person_id"]
  case "save_person":
    allowed = ["type", "person"]
    if let person = intentValue(base, "person", path: path) {
      let p = try intentObject(person, allowed: ["display_name", "age", "goal", "mode", "origin", "person_id", "stage", "status_word", "surface_language", "think_in"], path: path + ".person")
      if let origin = intentValue(p, "origin", path: path) { try validateOrigin(origin, path: path + ".person.origin") }
    }
  default: allowed = ["type"]
  }
  _ = try intentObject(raw, allowed: allowed, path: path)
  if type == "navigate", let destination = intentValue(base, "destination", path: path) {
    try validateDestination(destination, path: path + ".destination")
  }
}

private func validateOnboardingAnswer(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["type", "pin", "people", "origin", "think_in", "goal", "status_word", "person_id"], path: path)
  guard let type = base["type"] as? String else { return }
  let allowed: Set<String>
  switch type {
  case "pin":
    allowed = ["type", "pin"]
    if let pin = intentValue(base, "pin", path: path) { _ = try intentObject(pin, allowed: ["latitude", "longitude", "address"], path: path + ".pin") }
  case "people":
    allowed = ["type", "people"]
    if let people = base["people"] as? [Any] {
      for (i, person) in people.enumerated() { _ = try intentObject(person, allowed: ["display_name", "age"], path: path + ".people[\(i)]") }
    }
  case "origin_and_language":
    allowed = ["type", "origin", "think_in"]
    if let origin = intentValue(base, "origin", path: path) { try validateOrigin(origin, path: path + ".origin") }
  case "goal": allowed = ["type", "goal"]
  case "volunteered_status_word": allowed = ["type", "status_word", "person_id"]
  default: allowed = ["type"]
  }
  _ = try intentObject(raw, allowed: allowed, path: path)
}

private func validateOrigin(_ raw: Any, path: String) throws {
  _ = try intentObject(raw, allowed: ["country_code"], path: path)
}

private func validateDestination(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["type", "person_id", "step", "stage", "card_id", "filter", "desk_id"], path: path)
  guard let type = base["type"] as? String else { return }
  let allowed: Set<String>
  switch type {
  case "household", "add_person", "pin", "settings", "language", "voice": allowed = ["type"]
  case "person", "edit_person": allowed = ["type", "person_id"]
  case "onboarding": allowed = ["type", "step"]
  case "stage": allowed = ["type", "person_id", "stage"]
  case "card": allowed = ["type", "card_id", "person_id"]
  case "cards":
    allowed = ["type", "filter"]
    if let filter = intentValue(base, "filter", path: path) { _ = try intentObject(filter, allowed: ["subject", "stage", "desk", "mode"], path: path + ".filter") }
  case "desk": allowed = ["type", "desk_id"]
  default: allowed = ["type"]
  }
  _ = try intentObject(raw, allowed: allowed, path: path)
}

private func validateReadTarget(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["type", "card_id"], path: path)
  guard let type = base["type"] as? String else { return }
  _ = try intentObject(raw, allowed: type == "card" ? ["type", "card_id"] : ["type"], path: path)
}

private func validateMapTarget(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["type", "desk_id", "fact"], path: path)
  guard let type = base["type"] as? String else { return }
  let allowed: Set<String>
  switch type {
  case "desk": allowed = ["type", "desk_id"]
  case "place":
    allowed = ["type", "fact"]
    if let fact = intentValue(base, "fact", path: path) { try validateFactRef(fact, path: path + ".fact") }
  default: allowed = ["type"]
  }
  _ = try intentObject(raw, allowed: allowed, path: path)
}

private func validateGrounding(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["type", "card_id", "facts", "desk_id", "reason"], path: path)
  guard let type = base["type"] as? String else { return }
  let allowed: Set<String>
  switch type {
  case "card":
    allowed = ["type", "card_id", "facts"]
    if let facts = base["facts"] as? [Any] {
      for (i, fact) in facts.enumerated() { try validateFactRef(fact, path: path + ".facts[\(i)]") }
    }
  case "desk":
    allowed = ["type", "desk_id", "reason"]
    if let reason = intentValue(base, "reason", path: path) { try validateStringKey(reason, path: path + ".reason") }
  default: allowed = ["type"]
  }
  _ = try intentObject(raw, allowed: allowed, path: path)
}

private func validateClarification(_ raw: Any, path: String) throws {
  let base = try intentObject(raw, allowed: ["question", "options"], path: path)
  if let question = intentValue(base, "question", path: path) { try validateStringKey(question, path: path + ".question") }
  if let options = base["options"] as? [Any] {
    for (i, option) in options.enumerated() {
      let object = try intentObject(option, allowed: ["id", "label", "action"], path: path + ".options[\(i)]")
      if let label = intentValue(object, "label", path: path) { try validateStringKey(label, path: path + ".options[\(i)].label") }
      if let action = intentValue(object, "action", path: path) { try validateAppAction(action, path: path + ".options[\(i)].action") }
    }
  }
}

private func validateIntentResolution(_ raw: Any, path: String) throws {
  let object = try intentObject(raw, allowed: ["action", "grounding", "confidence", "clarification", "reply_language"], path: path)
  if let action = intentValue(object, "action", path: path) { try validateAppAction(action, path: path + ".action") }
  if let grounding = intentValue(object, "grounding", path: path) { try validateGrounding(grounding, path: path + ".grounding") }
  if let clarification = intentValue(object, "clarification", path: path) { try validateClarification(clarification, path: path + ".clarification") }
}

public protocol AgentsClient: Sendable {
  func resolve(
    utterance: String, language: String, routeContext: RouteContext,
    stage: Stage?, mode: Mode
  ) async throws -> IntentResolution
  func householdWeek(request: HouseholdWeekRequest) async throws -> HouseholdWeekResponse
  func personNextSteps(request: PersonNextStepsRequest) async throws -> PersonNextStepsResponse
}

/// The API client. It does not apply confidence thresholds; `phoneIntentPolicy` is an explicit helper
/// for callers that want ADRouter's 0.75/0.40 policy at the app boundary.
public struct AgentsAPI: Sendable, AgentsClient {
  public typealias Transport = AgentsTransport
  public let baseURL: URL
  private let transport: any AgentsTransport

  public init(baseURL: URL, transport: any AgentsTransport = URLSessionTransport()) {
    self.baseURL = baseURL
    self.transport = transport
  }

  public static let phoneIntentPolicy = IntentPolicy(performThreshold: 0.75, clarifyThreshold: 0.40)
  public static func applyPhoneConfidencePolicy(_ resolution: IntentResolution)
    -> IntentPolicy.Decision
  {
    phoneIntentPolicy.decide(resolution)
  }

  public func resolve(
    utterance: String, language: String, routeContext: RouteContext,
    stage: Stage?, mode: Mode
  ) async throws -> IntentResolution {
    let request = ResolveRequest(
      text: utterance, language: language, context: routeContext, stage: stage, mode: mode)
    return try await post(
      "/v1/ask", request, decoder: IntentWire.decoder, encoder: IntentWire.encoder,
      validateResponse: validateIntentResolutionResponse)
  }

  public func householdWeek(request: HouseholdWeekRequest) async throws -> HouseholdWeekResponse {
    try await post("/v1/household-week", request, decoder: JSONDecoder(), encoder: JSONEncoder())
  }

  public func personNextSteps(request: PersonNextStepsRequest) async throws
    -> PersonNextStepsResponse
  {
    try await post("/v1/person-next-steps", request, decoder: JSONDecoder(), encoder: JSONEncoder())
  }

  private func post<Request: Encodable, Response: Decodable>(
    _ path: String, _ body: Request,
    decoder: JSONDecoder, encoder: JSONEncoder,
    validateResponse: ((Data) throws -> Void)? = nil
  ) async throws -> Response {
    let url = baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(body)
    let (data, response) = try await transport.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AgentsClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw AgentsClientError.http(status: http.statusCode)
    }
    if let validateResponse { try validateResponse(data) }
    return try decoder.decode(Response.self, from: data)
  }
}

struct ResolveRequest: Encodable {
  let requestID: String?
  let text: String
  let language: String
  let context: RouteContext
  let stage: Stage?
  let mode: Mode

  init(
    requestID: String? = nil, text: String, language: String, context: RouteContext,
    stage: Stage?, mode: Mode
  ) {
    self.requestID = requestID
    self.text = text
    self.language = language
    self.context = context
    self.stage = stage
    self.mode = mode
  }

  private enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case utterance, stage, mode
  }
  private enum UtteranceKeys: String, CodingKey { case text, language, context }
  private enum ContextKeys: String, CodingKey {
    case destination
    case personID = "person_id"
    case cardID = "card_id"
    case deskID = "desk_id"
    case stage, mode
    case
      choiceIDs = "choice_ids"
    case awaitingConfirmation = "awaiting_confirmation"
  }

  func encode(to encoder: any Encoder) throws {
    var outer = encoder.container(keyedBy: CodingKeys.self)
    try outer.encodeIfPresent(requestID, forKey: .requestID)
    var u = outer.nestedContainer(keyedBy: UtteranceKeys.self, forKey: .utterance)
    try u.encode(text, forKey: .text)
    try u.encode(language, forKey: .language)
    var c = u.nestedContainer(keyedBy: ContextKeys.self, forKey: .context)
    try c.encodeIfPresent(context.destination, forKey: .destination)
    try c.encodeIfPresent(context.personID?.rawValue.uuidString, forKey: .personID)
    try c.encodeIfPresent(context.cardID?.rawValue, forKey: .cardID)
    try c.encodeIfPresent(context.deskID?.rawValue, forKey: .deskID)
    try c.encodeIfPresent(context.stage, forKey: .stage)
    try c.encodeIfPresent(context.mode, forKey: .mode)
    if !context.choiceIDs.isEmpty {
      try c.encode(context.choiceIDs.map(\.rawValue), forKey: .choiceIDs)
    }
    if context.awaitingConfirmation { try c.encode(true, forKey: .awaitingConfirmation) }
    try outer.encodeIfPresent(stage, forKey: .stage)
    try outer.encode(mode, forKey: .mode)
  }
}

/// Compatibility name for callers of the original skeleton.
public typealias HTTPAgentsClient = AgentsAPI
