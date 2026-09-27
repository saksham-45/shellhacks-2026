/// Who may see a piece of household data, by card surface. Enforced only here, in the domain
/// layer (`PrivacyPolicy`, `Household.view(for:)`); storage keeps full data.
public enum PrivacyScope: Hashable, Codable, Sendable {
    /// The household pin. Every card, including a child's.
    case sharedAddress
    /// Rent, car, income, usual drive, home language, and the roster (other members' id and
    /// display name). The household card and adult members' cards. Not a child's card.
    case household
    /// A person's profile (age, origin, goal, mode, stage), papers, and status word. Only
    /// that person's own card.
    case personal(PersonID)
    /// A personal item its owner put on the household on purpose. Every card (a tourist
    /// viewer still never sees immigration content).
    case sharedOnPurpose(by: PersonID)
}

/// The card a piece of data would appear on.
public enum CardSurface: Hashable, Codable, Sendable {
    case household
    case person(PersonID)
}

public enum PrivacyPolicy {
    /// The single visibility rule. People not in the household see nothing.
    public static func isVisible(_ scope: PrivacyScope, on surface: CardSurface, in household: Household) -> Bool {
        let viewer: Person?
        switch surface {
        case .household:
            viewer = nil
        case .person(let id):
            guard let person = household.person(id) else { return false }
            viewer = person
        }
        switch scope {
        case .sharedAddress, .sharedOnPurpose:
            return true
        case .household:
            return !(viewer?.isChild ?? false)
        case .personal(let owner):
            return viewer?.id == owner
        }
    }

    /// The mode a surface is viewed in: the person's own mode, or the household's.
    public static func viewerMode(of surface: CardSurface, in household: Household) -> Mode? {
        switch surface {
        case .household: household.mode
        case .person(let id): household.person(id)?.mode
        }
    }
}

extension Person {
    public var statusWordScope: PrivacyScope {
        statusWordSharedWithHousehold ? .sharedOnPurpose(by: id) : .personal(id)
    }

    public func scope(of paper: Paper) -> PrivacyScope {
        paper.sharedWithHousehold ? .sharedOnPurpose(by: id) : .personal(id)
    }
}
