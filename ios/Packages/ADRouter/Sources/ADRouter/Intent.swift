import Foundation
import ADCore

/// Where the person is, as ids only (ARCHITECTURE.md §13.2). No pack ids, no papers, no other
/// person's data: this is all `/v1/ask` ever learns about the screen.
public struct RouteContext: Hashable, Sendable {
    public var destination: Destination?
    /// The active person (whose card is on screen), if any.
    public var personID: PersonID?
    /// The card on screen, if any.
    public var cardID: CardID?
    /// The desk of the screen (a desk screen, or the visible card's desk), for "call the desk".
    public var deskID: DeskID?
    /// The active person's stage and mode.
    public var stage: Stage?
    public var mode: Mode?
    /// The options an ordinal ("the second one") picks from: the pending clarification's options,
    /// else the current screen's list of choices. In order.
    public var choiceIDs: [ClarifyOptionID]
    /// A leave-app action is waiting for yes or no.
    public var awaitingConfirmation: Bool

    public init(destination: Destination? = nil, personID: PersonID? = nil, cardID: CardID? = nil,
                deskID: DeskID? = nil, stage: Stage? = nil, mode: Mode? = nil,
                choiceIDs: [ClarifyOptionID] = [], awaitingConfirmation: Bool = false) {
        self.destination = destination
        self.personID = personID
        self.cardID = cardID
        self.deskID = deskID
        self.stage = stage
        self.mode = mode
        self.choiceIDs = choiceIDs
        self.awaitingConfirmation = awaitingConfirmation
    }
}

/// One sentence heard (from ADVoice) or typed, tagged with the language it was actually in.
public struct Utterance: Hashable, Sendable {
    public var text: String
    /// BCP-47 of the sentence just spoken, e.g. "es", "ht".
    public var language: String
    public var context: RouteContext

    public init(text: String, language: String, context: RouteContext = RouteContext()) {
        self.text = text
        self.language = language
        self.context = context
    }
}

/// What backs an answer: a card whose facts are ledger refs, or a desk handoff.
public enum Grounding: Hashable, Sendable {
    case card(CardID, facts: [FactRef])
    case desk(DeskID, reason: StringKey)
}

public enum ClarificationError: Error, Hashable, Sendable {
    /// A clarifying question has exactly 2 or 3 options.
    case optionCount(Int)
    case duplicateOption(ClarifyOptionID)
}

public struct ClarifyOption: Hashable, Sendable, Identifiable {
    public var id: ClarifyOptionID
    public var label: StringKey
    public var action: AppAction

    public init(id: ClarifyOptionID, label: StringKey, action: AppAction) {
        self.id = id
        self.label = label
        self.action = action
    }
}

/// ONE short question with exactly 2 or 3 options, spoken and shown as buttons.
public struct Clarification: Hashable, Sendable {
    /// A string key (or verified card text); never free-form model prose.
    public let question: StringKey
    public let options: [ClarifyOption]

    public static let allowedOptionCount = 2...3

    public init(question: StringKey, options: [ClarifyOption]) throws(ClarificationError) {
        guard Self.allowedOptionCount.contains(options.count) else { throw .optionCount(options.count) }
        var seen = Set<ClarifyOptionID>()
        for option in options where !seen.insert(option.id).inserted { throw .duplicateOption(option.id) }
        self.question = question
        self.options = options
    }

    public func option(_ id: ClarifyOptionID) -> ClarifyOption? { options.first { $0.id == id } }
}

/// The only thing an intent resolver may return: never a free-form answer.
public struct IntentResolution: Hashable, Sendable {
    /// A destination arrives as `.navigate`.
    public var action: AppAction?
    public var grounding: Grounding?
    /// 0...1. The on-device matcher returns 1.0.
    public var confidence: Double
    public var clarification: Clarification?
    /// BCP-47; defaults to the utterance's language.
    public var replyLanguage: String

    public init(action: AppAction? = nil, grounding: Grounding? = nil, confidence: Double,
                clarification: Clarification? = nil, replyLanguage: String) {
        self.action = action
        self.grounding = grounding
        self.confidence = min(1, max(0, confidence))
        self.clarification = clarification
        self.replyLanguage = replyLanguage
    }
}

/// On-device, deterministic, no network (ARCHITECTURE.md §13.2 step 1).
public protocol CommandMatcher: Sendable {
    func match(_ u: Utterance) -> IntentResolution?
    /// Same, with the labels of the choices on offer so "the Kendall one" or an option's own words
    /// can pick one. Default: ignores the choices.
    func match(_ u: Utterance, choices: [ClarifyOption]) -> IntentResolution?
}

extension CommandMatcher {
    public func match(_ u: Utterance, choices: [ClarifyOption]) -> IntentResolution? { match(u) }
}

/// The open-question resolver (Agents' `POST /v1/ask`, through ADAgentsClient). Returns an
/// `IntentResolution` and nothing else.
public protocol IntentResolving: Sendable {
    func resolve(_ u: Utterance) async throws -> IntentResolution
}

/// Confidence policy, applied on the phone so no server can bypass it (§13.2 step 3).
public struct IntentPolicy: Hashable, Sendable {
    public var performThreshold: Double
    public var clarifyThreshold: Double

    public init(performThreshold: Double = 0.75, clarifyThreshold: Double = 0.40) {
        self.performThreshold = performThreshold
        self.clarifyThreshold = clarifyThreshold
    }

    public enum Decision: Hashable, Sendable {
        case perform(AppAction)
        case clarify(Clarification)
        /// "I don't have this", plus the closest desk if the resolution named one.
        case handToDesk(DeskID?)
    }

    public func decide(_ r: IntentResolution) -> Decision {
        let desk: DeskID? = if case .desk(let d, _) = r.grounding { d } else { nil }
        if r.confidence >= performThreshold, let action = r.action { return .perform(action) }
        if r.confidence >= clarifyThreshold, let clarification = r.clarification {
            return .clarify(clarification)
        }
        return .handToDesk(desk)
    }
}

// MARK: - Wire

extension RouteContext: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        self.init(destination: try c.getNullable(Destination.self, "destination"),
                  personID: try c.getNullablePerson("person_id"),
                  cardID: try c.getNullableID(CardID.self, "card_id"),
                  deskID: try c.getNullableID(DeskID.self, "desk_id"),
                  stage: try c.getNullable(Stage.self, "stage"),
                  mode: try c.getNullable(Mode.self, "mode"),
                  choiceIDs: (try c.getNullable([String].self, "choice_ids") ?? []).map(ClarifyOptionID.init(rawValue:)),
                  awaitingConfirmation: try c.getNullable(Bool.self, "awaiting_confirmation") ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putNullable(destination, "destination")
        try c.putPerson(personID, "person_id")
        try c.putID(cardID, "card_id")
        try c.putID(deskID, "desk_id")
        try c.putNullable(stage, "stage")
        try c.putNullable(mode, "mode")
        try c.put(choiceIDs.map(\.rawValue), "choice_ids")
        try c.put(awaitingConfirmation, "awaiting_confirmation")
    }
}

extension Utterance: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        self.init(text: try c.get(String.self, "text"), language: try c.get(String.self, "language"),
                  context: try c.get(RouteContext.self, "context"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.put(text, "text")
        try c.put(language, "language")
        try c.put(context, "context")
    }
}

extension Grounding: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        switch try c.type() {
        case "card": self = .card(try c.getID(CardID.self, "card_id"), facts: try c.get([WireFactRef].self, "facts").map(\.value))
        case "desk": self = .desk(try c.getID(DeskID.self, "desk_id"), reason: try c.getKey("reason"))
        case let other: throw unknownType(c, other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case let .card(card, facts):
            try c.put("card", "type")
            try c.putID(card, "card_id")
            try c.put(facts.map(WireFactRef.init), "facts")
        case let .desk(desk, reason):
            try c.put("desk", "type")
            try c.putID(desk, "desk_id")
            try c.putKey(reason, "reason")
        }
    }
}

extension ClarifyOption: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        self.init(id: try c.getID(ClarifyOptionID.self, "id"), label: try c.getKey("label"),
                  action: try c.get(AppAction.self, "action"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putID(id, "id")
        try c.putKey(label, "label")
        try c.put(action, "action")
    }
}

extension Clarification: Codable {
    /// Decoding enforces the 2-3 option rule too: a server cannot send four options.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        let question = try c.getKey("question")
        let options = try c.get([ClarifyOption].self, "options")
        do {
            try self.init(question: question, options: options)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: "options", in: c, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putKey(question, "question")
        try c.put(options, "options")
    }
}

extension IntentResolution: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        let confidence = try c.get(Double.self, "confidence")
        guard (0...1).contains(confidence) else {
            throw DecodingError.dataCorruptedError(forKey: "confidence", in: c, debugDescription: "confidence must be 0...1")
        }
        self.init(action: try c.getNullable(AppAction.self, "action"),
                  grounding: try c.getNullable(Grounding.self, "grounding"),
                  confidence: confidence,
                  clarification: try c.getNullable(Clarification.self, "clarification"),
                  replyLanguage: try c.get(String.self, "reply_language"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putNullable(action, "action")
        try c.putNullable(grounding, "grounding")
        try c.put(confidence, "confidence")
        try c.putNullable(clarification, "clarification")
        try c.put(replyLanguage, "reply_language")
    }
}
