import Foundation

/// A person's own details. Appears only on that person's own card.
public struct PersonProfile: Hashable, Sendable, Encodable {
    public let displayName: String
    public let age: Int?
    public let origin: Origin?
    public let thinkIn: Locale.Language
    public let goal: Goal
    public let mode: Mode
    public let stage: Stage

    private enum CodingKeys: String, CodingKey { case displayName, age, origin, thinkIn, goal, mode, stage }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeLanguage(thinkIn, forKey: .thinkIn)
        try c.encode(goal, forKey: .goal)
        try c.encode(mode, forKey: .mode)
        try c.encode(stage, forKey: .stage)
    }
}

/// What one card surface may know about one member.
public struct MemberView: Hashable, Sendable, Identifiable, Encodable {
    public let id: PersonID
    /// Roster name: own card, household card, and adult members' cards.
    public let displayName: String?
    /// Own card only. Others never get another member's age, origin, goal, mode, or stage.
    public let profile: PersonProfile?
    /// Nil if not given, not visible, the owner is a tourist, or the viewer is a tourist.
    public let statusWord: StatusWord?
    /// Visible papers; immigration papers are stripped for a tourist viewer.
    public let papers: [Paper]
}

/// The redacted slice of a household for one card surface. The only household data cards
/// and agents should read. Encodable (to send), not Decodable: built only by `view(for:)`.
public struct HouseholdView: Hashable, Sendable, Encodable {
    public let surface: CardSurface
    public let pin: Pin?
    public let homeLanguage: Locale.Language?
    public let shared: SharedHousehold?
    public let members: [MemberView]

    private enum CodingKeys: String, CodingKey { case surface, pin, homeLanguage, shared, members }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        try c.encodeIfPresent(pin, forKey: .pin)
        try c.encodeLanguageIfPresent(homeLanguage, forKey: .homeLanguage)
        try c.encodeIfPresent(shared, forKey: .shared)
        try c.encode(members, forKey: .members)
    }
}

extension Household {
    /// Nil for a person who is not in this household.
    public func view(for surface: CardSurface) -> HouseholdView? {
        guard let viewerMode = PrivacyPolicy.viewerMode(of: surface, in: self) else { return nil }
        func visible(_ scope: PrivacyScope) -> Bool {
            PrivacyPolicy.isVisible(scope, on: surface, in: self)
        }
        let viewerIsTourist = viewerMode == .tourist
        let rosterVisible = visible(.household)
        let members: [MemberView] = people.compactMap { person in
            let isSelf = surface == .person(person.id)
            let name = (isSelf || rosterVisible) ? person.displayName : nil
            let profile = isSelf ? PersonProfile(
                displayName: person.displayName, age: person.age, origin: person.origin, thinkIn: person.thinkIn,
                goal: person.goal, mode: person.mode, stage: person.stage) : nil
            let status = (person.mode == .tourist || viewerIsTourist) ? nil
                : person.statusWord.flatMap { visible(person.statusWordScope) ? $0 : nil }
            let papers = person.papers.filter { paper in
                visible(person.scope(of: paper)) && !(viewerIsTourist && paper.isImmigrationDocument)
            }
            guard name != nil || status != nil || !papers.isEmpty else { return nil }
            return MemberView(id: person.id, displayName: name, profile: profile, statusWord: status, papers: papers)
        }
        return HouseholdView(
            surface: surface,
            pin: visible(.sharedAddress) ? pin : nil,
            homeLanguage: rosterVisible ? homeLanguage : nil,
            shared: rosterVisible ? shared : nil,
            members: members)
    }
}
