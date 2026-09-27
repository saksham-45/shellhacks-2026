/// Resident follows stages 1-10. Tourist skips 2-9 and never sees immigration content.
public enum Mode: String, Hashable, Codable, Sendable, CaseIterable {
    case resident, tourist

    /// Mode name (table "ADCore").
    public var labelKey: StringKey { .adCore("mode.\(rawValue)") }

    /// The switch a tourist says or taps: "I live here now" (table "ADCore").
    public static let iLiveHereNowKey: StringKey = .adCore("mode.i_live_here_now")

    /// myMiami plan, "Stages": "Tourist mode skips 2 through 9 and stays on:
    /// airport, scam, tipping, sun, rental-car tolls, 911, how to get back to MIA."
    public static let touristHeroTopics: [HeroTopic] = [
        .airport, .scam, .tipping, .sun, .rentalCarTolls, .emergency911, .backToAirport,
    ]
}
