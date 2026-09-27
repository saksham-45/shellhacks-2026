/// Hero slots, one per item in the plan's "The hero is" column plus the tourist list.
/// Region-neutral names ("backToAirport", "ordinaryWeek"): the Miami wording is content's.
public enum HeroTopic: String, Hashable, Codable, Sendable, CaseIterable {
    // 1. Safe this week
    case bed, food, airport, scam
    // 2. Mail and status
    case statusWord, mailbox
    // 3. ID
    case idChecklist
    // 4. Money
    case bank, remittance, noCheckCasher
    // 5. Roof
    case rentLine, listingCheck, whichCity
    // 6. Health
    case clinicDesk
    // 7. School or allowed work
    case schoolZone, dso, eadDates
    // 8. Movement
    case transit, license, tolls, insurance
    // 9. Paper trail
    case irs, credit, deadlines
    // 10. Footing
    case ordinaryWeek
    // Tourist-only (plus airport and scam above)
    case tipping, sun, rentalCarTolls, emergency911, backToAirport
}

extension HeroTopic {
    /// Hero label text reference (table "ADCore").
    public var labelKey: StringKey { .adCore("hero.\(rawValue)") }

    /// SF Symbol name (iOS 18 / SF Symbols 6). The plans name no symbols; these are plain
    /// literal objects reviewed by myAD Access. Decorative: the UI hides them from VoiceOver
    /// (the label key carries the meaning). Existence is checked on the Mac.
    public var symbolName: String {
        switch self {
        case .bed: "bed.double"
        case .food: "fork.knife"
        case .airport: "airplane"
        case .scam: "exclamationmark.triangle"
        case .statusWord: "doc.text"
        case .mailbox: "envelope"
        case .idChecklist: "list.clipboard"
        case .bank: "building.columns"
        case .remittance: "dollarsign.arrow.circlepath"
        case .noCheckCasher: "banknote"
        case .rentLine: "house"
        case .listingCheck: "checklist"
        case .whichCity: "map"
        case .clinicDesk: "cross.case"
        case .schoolZone: "graduationcap"
        case .dso: "studentdesk"
        case .eadDates: "person.text.rectangle"
        case .transit: "bus"
        case .license: "car"
        case .tolls: "road.lanes"
        case .insurance: "checkmark.shield"
        case .irs: "archivebox"
        case .credit: "creditcard"
        case .deadlines: "alarm"
        case .ordinaryWeek: "calendar"
        case .tipping: "dollarsign.circle"
        case .sun: "sun.max"
        case .rentalCarTolls: "car.rear.road.lane"
        case .emergency911: "sos"
        case .backToAirport: "airplane.departure"
        }
    }
}
