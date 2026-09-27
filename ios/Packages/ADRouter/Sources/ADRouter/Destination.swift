import Foundation
import ADCore

/// Every screen the app has, as a value (ARCHITECTURE.md §13.1). Touch, voice, App Intents,
/// VoiceOver actions, and UI tests all reach a screen only through `Router.perform(.navigate(_:))`.
public enum Destination: Hashable, Sendable {
    /// The household and its week (the root).
    case household
    case person(PersonID)
    case addPerson
    /// The same form as `addPerson`, filled in for one person.
    case editPerson(PersonID)
    /// One of ADCore's four onboarding questions.
    case onboarding(OnboardingStep)
    /// The hero for that stage of that person.
    case stage(PersonID, Stage)
    case card(CardID, person: PersonID?)
    /// The wallet narrowed by ADCore's `CardFilter` (applied only through ADCore's privacy and tourist rules).
    case cards(CardFilter)
    /// Desk handoff: phone, address, and hours come only from ledger facts.
    case desk(DeskID)
    /// Choose between the demo pins.
    case pin
    case settings
    case language
    case voice
}

/// Where "open the map" goes. `.place` must point at a fact whose value is `.place`; the router
/// refuses anything else. Both cases leave the app, so both are confirmed first.
public enum MapTarget: Hashable, Sendable {
    case desk(DeskID)
    case place(FactRef)
}

/// What "read aloud" reads.
public enum ReadTarget: Hashable, Sendable {
    /// The current screen.
    case screen
    case card(CardID)
    /// The active person's current next step.
    case step
}

/// The id of one option in a clarifying question or a screen's list of choices.
public struct ClarifyOptionID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Wire

extension Destination: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        switch try c.type() {
        case "household": self = .household
        case "person": self = .person(try c.getPerson("person_id"))
        case "add_person": self = .addPerson
        case "edit_person": self = .editPerson(try c.getPerson("person_id"))
        case "onboarding": self = .onboarding(try c.get(OnboardingStep.self, "step"))
        case "stage": self = .stage(try c.getPerson("person_id"), try c.get(Stage.self, "stage"))
        case "card": self = .card(try c.getID(CardID.self, "card_id"), person: try c.getNullablePerson("person_id"))
        case "cards": self = .cards(try c.get(WireCardFilter.self, "filter").value)
        case "desk": self = .desk(try c.getID(DeskID.self, "desk_id"))
        case "pin": self = .pin
        case "settings": self = .settings
        case "language": self = .language
        case "voice": self = .voice
        case let other: throw unknownType(c, other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .household: try c.put("household", "type")
        case .person(let id):
            try c.put("person", "type")
            try c.putPerson(id, "person_id")
        case .addPerson: try c.put("add_person", "type")
        case .editPerson(let id):
            try c.put("edit_person", "type")
            try c.putPerson(id, "person_id")
        case .onboarding(let step):
            try c.put("onboarding", "type")
            try c.put(step, "step")
        case let .stage(person, stage):
            try c.put("stage", "type")
            try c.putPerson(person, "person_id")
            try c.put(stage, "stage")
        case let .card(card, person):
            try c.put("card", "type")
            try c.putID(card, "card_id")
            try c.putPerson(person, "person_id")
        case .cards(let filter):
            try c.put("cards", "type")
            try c.put(WireCardFilter(filter), "filter")
        case .desk(let desk):
            try c.put("desk", "type")
            try c.putID(desk, "desk_id")
        case .pin: try c.put("pin", "type")
        case .settings: try c.put("settings", "type")
        case .language: try c.put("language", "type")
        case .voice: try c.put("voice", "type")
        }
    }
}

/// `{"subject": "person"|"household"|null, "stage": 1-10|null, "desk": id|null, "mode": "resident"|"tourist"|null}`
struct WireCardFilter: Codable {
    let value: CardFilter
    init(_ value: CardFilter) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        value = CardFilter(subject: try c.getNullable(CardSubject.self, "subject"),
                           stage: try c.getNullable(Stage.self, "stage"),
                           desk: try c.getNullableID(DeskID.self, "desk"),
                           mode: try c.getNullable(Mode.self, "mode"))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putNullable(value.subject, "subject")
        try c.putNullable(value.stage, "stage")
        try c.putID(value.desk, "desk")
        try c.putNullable(value.mode, "mode")
    }
}

extension MapTarget: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        switch try c.type() {
        case "desk": self = .desk(try c.getID(DeskID.self, "desk_id"))
        case "place": self = .place(try c.getRef("fact"))
        case let other: throw unknownType(c, other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .desk(let desk):
            try c.put("desk", "type")
            try c.putID(desk, "desk_id")
        case .place(let ref):
            try c.put("place", "type")
            try c.putRef(ref, "fact")
        }
    }
}

extension ReadTarget: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        switch try c.type() {
        case "screen": self = .screen
        case "card": self = .card(try c.getID(CardID.self, "card_id"))
        case "step": self = .step
        case let other: throw unknownType(c, other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .screen: try c.put("screen", "type")
        case .card(let card):
            try c.put("card", "type")
            try c.putID(card, "card_id")
        case .step: try c.put("step", "type")
        }
    }
}
