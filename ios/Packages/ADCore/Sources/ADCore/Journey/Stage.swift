/// The ten stages, myMiami plan, "Stages". One per person.
public enum Stage: Int, Hashable, Codable, Sendable, CaseIterable, Comparable {
    case safeThisWeek = 1
    case mailAndStatus = 2
    case identification = 3
    case money = 4
    case roof = 5
    case health = 6
    case schoolOrAllowedWork = 7
    case movement = 8
    case paperTrail = 9
    case footing = 10

    public var number: Int { rawValue }

    /// Stable slug for text keys ("stage.safe_this_week.title").
    public var slug: String {
        switch self {
        case .safeThisWeek: "safe_this_week"
        case .mailAndStatus: "mail_and_status"
        case .identification: "id"
        case .money: "money"
        case .roof: "roof"
        case .health: "health"
        case .schoolOrAllowedWork: "school_or_allowed_work"
        case .movement: "movement"
        case .paperTrail: "paper_trail"
        case .footing: "footing"
        }
    }

    public var labelKey: StringKey { .adCore("stage.\(slug).title") }

    public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The plan's "The hero is" column, in the plan's order.
    public var heroTopics: [HeroTopic] {
        switch self {
        case .safeThisWeek: [.bed, .food, .airport, .scam]
        case .mailAndStatus: [.statusWord, .mailbox]
        case .identification: [.idChecklist]
        case .money: [.bank, .remittance, .noCheckCasher]
        case .roof: [.rentLine, .listingCheck, .whichCity]
        case .health: [.clinicDesk]
        case .schoolOrAllowedWork: [.schoolZone, .dso, .eadDates]
        case .movement: [.transit, .license, .tolls, .insurance]
        case .paperTrail: [.irs, .credit, .deadlines]
        case .footing: [.ordinaryWeek]
        }
    }

    public var isSkippedInTouristMode: Bool { (2...9).contains(rawValue) }

    public func next(in mode: Mode) -> Stage? {
        switch (mode, self) {
        case (_, .footing): nil
        case (.tourist, _): .footing
        case (.resident, _): Stage(rawValue: rawValue + 1)
        }
    }
}
