// Shared type (ARCHITECTURE.md §12). Card metadata only; copy is content's, facts are
// research's, rendering is ADLocale/ADVoice's.
import Foundation

/// Whether a card is about the household (address, the week) or about one person.
public enum CardSubject: String, Hashable, Codable, Sendable {
    case household
    case person
}

public enum CardError: Error, Equatable, Sendable {
    case emptyDesk(CardID)
    case keyFactNotOnCard(CardID, FactID)
}

/// A card registry entry (content/cards) as ADCore needs it for hero selection,
/// mode filtering, the source line, and speech.
public struct Card: Hashable, Sendable, Identifiable {
    public let id: CardID
    public let regionPack: RegionPackID
    public let subject: CardSubject
    /// Title text reference, by convention ("card.<id>.title", table "Cards").
    public let titleKey: StringKey
    /// The hero slot this card can fill, if any.
    public let heroTopic: HeroTopic?
    /// Modes in which content wants the card shown. Default: resident only.
    public let modes: Set<Mode>
    /// Hard rule: immigration content is never shown in tourist mode, whatever `modes` says.
    public let isImmigrationContent: Bool
    /// Origin lenses this card speaks to. Used to rank within a stage.
    public let lenses: Set<OriginLens>
    /// Every card ends at a desk. Non-optional and non-empty.
    public let desk: DeskID
    public let facts: [FactID]
    /// The one fact spoken first. Defaults to the first fact; must be one of `facts`.
    public let keyFact: FactID?

    public init(
        id: CardID,
        regionPack: RegionPackID,
        subject: CardSubject,
        titleKey: StringKey? = nil,
        heroTopic: HeroTopic? = nil,
        modes: Set<Mode> = [.resident],
        isImmigrationContent: Bool = false,
        lenses: Set<OriginLens> = [],
        desk: DeskID,
        facts: [FactID] = [],
        keyFact: FactID? = nil
    ) throws(CardError) {
        guard !desk.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyDesk(id) }
        let key = keyFact ?? facts.first
        if let key, !facts.contains(key) { throw .keyFactNotOnCard(id, key) }
        self.id = id
        self.regionPack = regionPack
        self.subject = subject
        self.titleKey = titleKey ?? Card.defaultTitleKey(for: id)
        self.heroTopic = heroTopic
        self.modes = modes
        self.isImmigrationContent = isImmigrationContent
        self.lenses = lenses
        self.desk = desk
        self.facts = facts
        self.keyFact = key
    }

    /// ARCHITECTURE.md §7: card copy compiles to the "Cards" table as card.<id>.title.
    public static func defaultTitleKey(for id: CardID) -> StringKey {
        StringKey(key: "card.\(id.rawValue).title", table: "Cards")
    }
}

extension Card: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, regionPack, subject, titleKey, heroTopic, modes, isImmigrationContent, lenses, desk, facts, keyFact
    }

    /// Same rules as the init: keyFact defaults to facts.first and must be on the card; the desk
    /// must be non-empty; absent modes mean resident only; absent immigration flag means false.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(CardID.self, forKey: .id),
            regionPack: c.decode(RegionPackID.self, forKey: .regionPack),
            subject: c.decode(CardSubject.self, forKey: .subject),
            titleKey: c.decodeIfPresent(StringKey.self, forKey: .titleKey),
            heroTopic: c.decodeIfPresent(HeroTopic.self, forKey: .heroTopic),
            modes: c.decodeIfPresent(Set<Mode>.self, forKey: .modes) ?? [.resident],
            isImmigrationContent: c.decodeIfPresent(Bool.self, forKey: .isImmigrationContent) ?? false,
            lenses: c.decodeIfPresent(Set<OriginLens>.self, forKey: .lenses) ?? [],
            desk: c.decode(DeskID.self, forKey: .desk),
            facts: c.decodeIfPresent([FactID].self, forKey: .facts) ?? [],
            keyFact: c.decodeIfPresent(FactID.self, forKey: .keyFact))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(regionPack, forKey: .regionPack)
        try c.encode(subject, forKey: .subject)
        try c.encode(titleKey, forKey: .titleKey)
        try c.encodeIfPresent(heroTopic, forKey: .heroTopic)
        try c.encode(modes.sorted { $0.rawValue < $1.rawValue }, forKey: .modes)
        try c.encode(isImmigrationContent, forKey: .isImmigrationContent)
        try c.encode(lenses.sorted { $0.rawValue < $1.rawValue }, forKey: .lenses)
        try c.encode(desk, forKey: .desk)
        try c.encode(facts, forKey: .facts)
        try c.encodeIfPresent(keyFact, forKey: .keyFact)
    }
}

/// How one fact on a card is presented.
public enum FactLine: Hashable, Sendable {
    /// verified, stale, or demo (the UI must label demo and stale via `FactStatus.labelKey`).
    case shown(Fact, status: FactStatus)
    /// The fact does not apply at this pin; someone else answers.
    case notApplicable(FactID, reason: StringKey, deferTo: FactRef?)
    /// Unsourced, unknown, or lacking its evidence: the card says so and names the desk.
    case handedToDesk(FactID, desk: DeskID)
    /// The source exists but could not be reached: no value is shown, the card names the desk.
    /// Same handoff as `handedToDesk`; a separate case so the UI can say "couldn't check right now".
    case sourceUnavailable(FactID, desk: DeskID)

    /// The desk this line hands off to, for both handoff cases; nil when a fact is shown or deferred.
    public var handoffDesk: DeskID? {
        switch self {
        case .handedToDesk(_, let desk), .sourceUnavailable(_, let desk): desk
        case .shown, .notApplicable: nil
        }
    }
}

/// The line at the bottom of every card.
public enum SourceLine: Hashable, Sendable {
    /// Sources behind the shown facts, and the oldest retrieval date among them.
    case sourced([Source], lastChecked: Date)
    /// No shown fact has a source: "we have no source for this; this is the desk".
    case noSource(desk: DeskID)

    /// Text key for the line's lead-in (table "ADCore"); ADLocale adds publisher/date/desk.
    public var labelKey: StringKey {
        switch self {
        case .sourced: .adCore("source_line.sourced")
        case .noSource: .adCore("source_line.no_source")
        }
    }
}

/// Structured parts ADVoice/ADLocale turn into speech and VoiceOver text. Data, not strings.
public struct SpeakableParts: Hashable, Sendable {
    public let titleKey: StringKey
    public let keyFact: FactLine?
    /// When the shown key fact is a `.code`/`.codes` value: the strings voice must read as-is
    /// (no translation, no StringKey lookup), in source order. Empty otherwise.
    public let verbatimCodes: [String]
    public let sourcePublisher: String?
    public let retrievedAt: Date?
    public let desk: DeskID
}

extension Card {
    public func factLines(using resolver: some FactResolving, asOf now: Date) -> [FactLine] {
        facts.map { line(for: $0, using: resolver, asOf: now) }
    }

    public func sourceLine(using resolver: some FactResolving, asOf now: Date) -> SourceLine {
        var sources: [Source] = []
        var oldest: Date?
        for case let .shown(fact, _) in factLines(using: resolver, asOf: now) {
            guard let source = fact.source, let retrievedAt = fact.retrievedAt else { continue }
            if !sources.contains(source) { sources.append(source) }
            oldest = min(oldest ?? retrievedAt, retrievedAt)
        }
        guard let oldest, !sources.isEmpty else { return .noSource(desk: desk) }
        return .sourced(sources, lastChecked: oldest)
    }

    public func speakableParts(using resolver: some FactResolving, asOf now: Date) -> SpeakableParts {
        let key = keyFact.map { line(for: $0, using: resolver, asOf: now) }
        var publisher: String?
        var retrievedAt: Date?
        var codes: [String] = []
        if case let .shown(fact, _) = key {
            publisher = fact.source?.publisher
            retrievedAt = fact.retrievedAt
            codes = fact.displayValue?.verbatimCodes ?? []
        }
        return SpeakableParts(titleKey: titleKey, keyFact: key, verbatimCodes: codes, sourcePublisher: publisher,
                              retrievedAt: retrievedAt, desk: desk)
    }

    private func line(for id: FactID, using resolver: some FactResolving, asOf now: Date) -> FactLine {
        switch resolver.outcome(for: id) {
        case .fact(let fact)?:
            // Backstop: a fact whose evidence does not match its status never renders as shown.
            guard fact.displayValue != nil, fact.hasRequiredEvidence else { return .handedToDesk(id, desk: desk) }
            return .shown(fact, status: fact.status(asOf: now))
        case let .notApplicable(reason, target)?:
            return .notApplicable(id, reason: reason, deferTo: target)
        case .unsourced(let named)?:
            return .handedToDesk(id, desk: named.id)
        case .unavailable(let named)?:
            // No cached value rides along: only a sourced Fact marked .stale can show old data.
            return .sourceUnavailable(id, desk: named.id)
        case nil:
            return .handedToDesk(id, desk: desk)
        }
    }
}
