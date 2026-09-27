import Foundation

public struct PersonID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Onboarding question 4: "arrive, study, work, reunite, visit, or just get through this week."
/// Raw values match the server's `Goal`.
public enum Goal: String, Hashable, Codable, Sendable, CaseIterable {
    case arrive, study, work, reunite, visit, getThroughWeek

    /// Option label for onboarding question 4 (table "ADCore").
    public var labelKey: StringKey { .adCore("goal.\(rawValue)") }
}

/// A status word id from the country pack's vocabulary ("us" pack). ADCore never asks for it.
public struct StatusWord: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct PaperID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One item in a person's folder (passport, I-94, I-20, vaccine record...).
/// Photos live on the device; ADCore only holds opaque references to them.
public struct Paper: Hashable, Codable, Sendable, Identifiable {
    public let id: PaperID
    /// Kind id, e.g. "passport", "i-94", "i-20". Vocabulary is the country pack's.
    public var kind: String
    /// Immigration content (hidden from any tourist's view). Required: no default, so every
    /// paper is classified on purpose.
    public var isImmigrationDocument: Bool
    public var attachmentRefs: [String]
    /// The owner put this on the household on purpose. Default: private to the owner.
    public var sharedWithHousehold: Bool

    public init(id: PaperID = PaperID(), kind: String, isImmigrationDocument: Bool,
                attachmentRefs: [String] = [], sharedWithHousehold: Bool = false) {
        self.id = id
        self.kind = kind
        self.isImmigrationDocument = isImmigrationDocument
        self.attachmentRefs = attachmentRefs
        self.sharedWithHousehold = sharedWithHousehold
    }
}

public enum StageError: Error, Equatable, Sendable {
    case skippedInTouristMode(Stage)
}

/// One member of the household, on their own path.
public struct Person: Hashable, Sendable, Identifiable {
    public let id: PersonID
    public var displayName: String
    public var age: Int?
    public var origin: Origin?
    /// The language they think in (any language, not only es/en/ht).
    public var thinkIn: Locale.Language
    /// The surface this person reads, if they chose one; nil follows `thinkIn`/the app setting.
    public var surfaceLanguage: Locale.Language?
    public var goal: Goal
    public private(set) var mode: Mode
    public private(set) var stage: Stage
    /// Only if the person chooses to give it. Never required anywhere.
    public var statusWord: StatusWord?
    public var statusWordSharedWithHousehold: Bool
    public var papers: [Paper]
    public var completedCards: Set<CardID>

    public init(
        id: PersonID = PersonID(),
        displayName: String,
        age: Int? = nil,
        origin: Origin? = nil,
        thinkIn: Locale.Language,
        surfaceLanguage: Locale.Language? = nil,
        goal: Goal,
        statusWord: StatusWord? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.age = age
        self.origin = origin
        self.thinkIn = .normalized(thinkIn)
        self.surfaceLanguage = surfaceLanguage.map(Locale.Language.normalized)
        self.goal = goal
        self.mode = goal == .visit ? .tourist : .resident
        self.stage = .safeThisWeek
        self.statusWord = statusWord
        self.statusWordSharedWithHousehold = false
        self.papers = []
        self.completedCards = []
    }

    /// BCP-47 tag of the language they think in (ADLocale's `SpokenLanguage`).
    public var thinkInLanguageTag: String { thinkIn.minimalIdentifier }
    /// BCP-47 tag of the surface this person reads; falls back to `thinkIn`.
    /// ADLocale maps it onto `SurfaceLanguage` (es/en/ht) when it is one of the three.
    public var surfaceLanguageTag: String { (surfaceLanguage ?? thinkIn).minimalIdentifier }

    /// Policy threshold for "child card" privacy. Open question: confirm 18 with the captain.
    public static let adultAge = 18
    /// Unknown age is treated as adult (age is optional per the plans).
    public var isChild: Bool { age.map { $0 < Person.adultAge } ?? false }

    public mutating func setStage(_ newStage: Stage) throws(StageError) {
        if mode == .tourist, newStage.isSkippedInTouristMode { throw .skippedInTouristMode(newStage) }
        stage = newStage
    }

    /// Moves to the next stage for this mode. Tourist: 1 -> 10. Returns false at stage 10.
    @discardableResult
    public mutating func advanceStage() -> Bool {
        guard let next = stage.next(in: mode) else { return false }
        stage = next
        return true
    }

    /// "I live here now." Tourist -> resident. The resident path resumes at the first
    /// stage tourist mode skipped (2) if they had reached 10; stage 1 stays 1.
    /// A `.visit` goal becomes `.arrive` unless a new goal is given. No-op for residents
    /// (except an explicit goal). Never asks for a status word.
    public mutating func iLiveHereNow(goal newGoal: Goal? = nil) {
        if let newGoal, newGoal != .visit { goal = newGoal }
        guard mode == .tourist else { return }
        mode = .resident
        if goal == .visit { goal = .arrive }
        if stage == .footing { stage = .mailAndStatus }
    }

    /// Back to tourist mode (test UI "set mode"). Stages 2-9 do not exist there: clamp to 1.
    public mutating func becomeTourist() {
        mode = .tourist
        goal = .visit
        if stage.isSkippedInTouristMode { stage = .safeThisWeek }
    }
}

extension Person: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, age, origin, thinkIn, surfaceLanguage, goal, mode, stage,
             statusWord, statusWordSharedWithHousehold, papers, completedCards
    }

    /// Languages decode from BCP-47 strings. Re-checks the mode/stage invariant: a tourist
    /// stored at stages 2-9 fails to decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PersonID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        age = try c.decodeIfPresent(Int.self, forKey: .age)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        thinkIn = .normalized(try c.decodeLanguage(forKey: .thinkIn))
        surfaceLanguage = try c.decodeLanguageIfPresent(forKey: .surfaceLanguage).map(Locale.Language.normalized)
        goal = try c.decode(Goal.self, forKey: .goal)
        mode = try c.decode(Mode.self, forKey: .mode)
        stage = try c.decode(Stage.self, forKey: .stage)
        statusWord = try c.decodeIfPresent(StatusWord.self, forKey: .statusWord)
        statusWordSharedWithHousehold = try c.decodeIfPresent(Bool.self, forKey: .statusWordSharedWithHousehold) ?? false
        papers = try c.decodeIfPresent([Paper].self, forKey: .papers) ?? []
        completedCards = try c.decodeIfPresent(Set<CardID>.self, forKey: .completedCards) ?? []
        if mode == .tourist, stage.isSkippedInTouristMode {
            throw DecodingError.dataCorruptedError(forKey: .stage, in: c,
                debugDescription: "tourist cannot be at stage \(stage.number)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeLanguage(thinkIn, forKey: .thinkIn)
        try c.encodeLanguageIfPresent(surfaceLanguage, forKey: .surfaceLanguage)
        try c.encode(goal, forKey: .goal)
        try c.encode(mode, forKey: .mode)
        try c.encode(stage, forKey: .stage)
        try c.encodeIfPresent(statusWord, forKey: .statusWord)
        try c.encode(statusWordSharedWithHousehold, forKey: .statusWordSharedWithHousehold)
        try c.encode(papers, forKey: .papers)
        try c.encode(completedCards.sorted { $0.rawValue < $1.rawValue }, forKey: .completedCards)
    }
}
