/// The identity of a pin choice the router can set (e.g. one of the two demo pins that
/// ADCityPack's fixtures name). ADCore does not resolve it; the chosen `Pin` is what the
/// household stores.
public struct PinID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A typed narrowing of the wallet (router `Destination.cards`). Every field is optional and
/// only narrows. There is no public way to apply it except `HeroPolicy.cards(matching:on:in:catalog:)`,
/// which applies the privacy and tourist rules first, so a filter can never widen what a
/// surface may show.
public struct CardFilter: Hashable, Codable, Sendable {
    public var subject: CardSubject?
    /// Cards whose hero topic belongs to this stage.
    public var stage: Stage?
    public var desk: DeskID?
    /// Cards content declared for this mode.
    public var mode: Mode?
    /// Explicit ids; still applied only after privacy and tourist rules.
    public var cardIDs: Set<CardID>?

    public init(subject: CardSubject? = nil, stage: Stage? = nil, desk: DeskID? = nil, mode: Mode? = nil,
                cardIDs: Set<CardID>? = nil) {
        self.subject = subject
        self.stage = stage
        self.desk = desk
        self.mode = mode
        self.cardIDs = cardIDs
    }

    func matches(_ card: Card) -> Bool {
        if let subject, card.subject != subject { return false }
        if let stage, !(card.heroTopic.map(stage.heroTopics.contains) ?? false) { return false }
        if let desk, card.desk != desk { return false }
        if let mode, !card.modes.contains(mode) { return false }
        if let cardIDs, !cardIDs.contains(card.id) { return false }
        return true
    }
}

extension HeroPolicy {
    /// The wallet for the surface (privacy + tourist rules), then narrowed by the filter.
    public static func cards(matching filter: CardFilter, on surface: CardSurface, in household: Household,
                             catalog: [Card]) -> [Card] {
        wallet(for: surface, in: household, catalog: catalog).filter(filter.matches)
    }

    /// Whether a surface may show this card (the router's check before `.card` navigation).
    public static func canShow(_ card: Card, on surface: CardSurface, in household: Household) -> Bool {
        !wallet(for: surface, in: household, catalog: [card]).isEmpty
    }
}
