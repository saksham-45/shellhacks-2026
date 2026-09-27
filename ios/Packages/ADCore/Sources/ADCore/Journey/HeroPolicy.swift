/// Picks the hero and the next three steps for one person, and the cards a card
/// context may show. Pure and deterministic.
public struct HeroPolicy: Sendable {
    private let lensResolver: any OriginLensResolving

    public init(lensResolver: some OriginLensResolving) {
        self.lensResolver = lensResolver
    }

    /// Hard rule plus content's declared modes.
    public static func isAllowed(_ card: Card, in mode: Mode) -> Bool {
        guard card.modes.contains(mode) else { return false }
        return !(mode == .tourist && card.isImmigrationContent)
    }

    /// Topics the hero may come from: the stage's column, or the tourist list.
    public static func heroTopics(for person: Person) -> [HeroTopic] {
        person.mode == .tourist ? Mode.touristHeroTopics : person.stage.heroTopics
    }

    public func lenses(for person: Person) -> Set<OriginLens> {
        var lenses = person.origin.map(lensResolver.lenses(for:)) ?? []
        if person.goal == .study { lenses.insert(.internationalStudent) }
        if person.mode == .tourist { lenses.insert(.tourist) }
        return lenses
    }

    /// Candidates: person cards for this person's hero topics, allowed in their mode,
    /// not completed. Order: lens match first, then the plan's topic order, then id.
    public func nextSteps(for person: Person, catalog: [Card], limit: Int = 3) -> [Card] {
        let topics = Self.heroTopics(for: person)
        let lenses = lenses(for: person)
        func rank(_ card: Card) -> (Int, Int, String) {
            let lensMiss = card.lenses.isDisjoint(with: lenses) ? 1 : 0
            let topicIndex = card.heroTopic.flatMap(topics.firstIndex(of:)) ?? Int.max
            return (lensMiss, topicIndex, card.id.rawValue)
        }
        return catalog
            .filter { card in
                card.subject == .person
                    && card.heroTopic.map(topics.contains) == true
                    && Self.isAllowed(card, in: person.mode)
                    && !person.completedCards.contains(card.id)
            }
            .sorted { rank($0) < rank($1) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func hero(for person: Person, catalog: [Card]) -> Card? {
        nextSteps(for: person, catalog: catalog, limit: 1).first
    }

    /// The wallet for a card context: person cards in that person's mode, household
    /// cards in the household's mode. A tourist's wallet never holds immigration content,
    /// whatever the card's subject (a tourist in a mixed household included).
    public static func wallet(for surface: CardSurface, in household: Household, catalog: [Card]) -> [Card] {
        switch surface {
        case .household:
            return catalog.filter { $0.subject == .household && isAllowed($0, in: household.mode) }
        case .person(let id):
            guard let person = household.person(id) else { return [] }
            return catalog.filter { card in
                if person.mode == .tourist, card.isImmigrationContent { return false }
                return isAllowed(card, in: card.subject == .person ? person.mode : household.mode)
            }
        }
    }
}
