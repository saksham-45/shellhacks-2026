/// Where a person lived before. An axis independent of the region pack (where they are now).
public struct Origin: Hashable, Sendable {
    /// ISO 3166-1 alpha-2 country code, uppercased: "CU", "HT", "IN".
    public let countryCode: String

    public init(countryCode: String) { self.countryCode = countryCode.uppercased() }
}

extension Origin: Codable {
    private enum CodingKeys: String, CodingKey { case countryCode }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(countryCode: try c.decode(String.self, forKey: .countryCode))
    }
}

/// The origin lenses the plan ships first (ARCHITECTURE.md §3; same raw values as the
/// server's `OriginLens`). Content owns the copy and the country -> lens mapping.
public enum OriginLens: String, Hashable, Codable, Sendable, CaseIterable {
    /// Latin America, especially Cuba: the notario warning.
    case latinAmerica
    /// Haiti: Creole everywhere, deadlines on a calendar, the notario warning.
    case haiti
    /// India and any left-driving country: driving rules and the state license list.
    case leftDriving
    /// International students (derived from `Goal.study`): the school's office is the desk.
    case internationalStudent
    /// Tourists (derived from `Mode.tourist`): airport, scam, tipping, tolls, emergency.
    case tourist
    /// Any other origin: a short questionnaire, not a guessed culture.
    case questionnaire
}

/// Maps an origin to lenses (which countries are Latin America, left-driving, ...).
/// That mapping is data; content implements it. ADCore holds no country lists.
public protocol OriginLensResolving: Sendable {
    func lenses(for origin: Origin) -> Set<OriginLens>
}
