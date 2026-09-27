import Foundation
import ADCore
import ADLocale

/// Everything a person can do, as a value (ARCHITECTURE.md §13.1).
public enum AppAction: Hashable, Sendable {
    case navigate(Destination)
    case back
    case home
    case readAloud(ReadTarget)
    case stopSpeaking
    case repeatLast
    case nextStep
    case previousStep
    /// Leaves the app: always confirmed first (a spoken yes or a button).
    case callDesk(DeskID)
    /// Leaves the app: always confirmed first. `.place` must be a `.place` fact.
    case openMap(MapTarget)
    case setSurfaceLanguage(SurfaceLanguage)
    case setThinkIn(SpokenLanguage)
    /// ADCore's typed answer to the onboarding question being asked.
    case answerOnboarding(OnboardingAnswer)
    /// Answer to a clarifying question, or a pick from the current screen's list of choices.
    case choose(ClarifyOptionID)
    case setPin(PinID)
    /// Tourist, or "I live here now" (resident), for the active person.
    case setMode(Mode)
    case confirm(Bool)
    /// Add a person (draft without an id) or update one (draft with the person's id).
    case savePerson(PersonDraft)
    /// Removes a person; `undo` puts them back. Destructive, so the UI offers undo right away.
    case deletePerson(PersonID)
    case undo

    /// Actions that leave the app. The router never performs one without a yes.
    public var leavesApp: Bool {
        switch self {
        case .callDesk, .openMap: true
        default: false
        }
    }
}

extension AppAction: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        switch try c.type() {
        case "navigate": self = .navigate(try c.get(Destination.self, "destination"))
        case "back": self = .back
        case "home": self = .home
        case "read_aloud": self = .readAloud(try c.get(ReadTarget.self, "target"))
        case "stop_speaking": self = .stopSpeaking
        case "repeat_last": self = .repeatLast
        case "next_step": self = .nextStep
        case "previous_step": self = .previousStep
        case "call_desk": self = .callDesk(try c.getID(DeskID.self, "desk_id"))
        case "open_map": self = .openMap(try c.get(MapTarget.self, "target"))
        case "set_surface_language": self = .setSurfaceLanguage(try c.get(SurfaceLanguage.self, "language"))
        case "set_think_in": self = .setThinkIn(SpokenLanguage(bcp47: try c.get(String.self, "language")))
        case "answer_onboarding": self = .answerOnboarding(try c.get(WireOnboardingAnswer.self, "answer").value)
        case "choose": self = .choose(try c.getID(ClarifyOptionID.self, "option_id"))
        case "set_pin": self = .setPin(try c.getID(PinID.self, "pin_id"))
        case "set_mode": self = .setMode(try c.get(Mode.self, "mode"))
        case "confirm": self = .confirm(try c.get(Bool.self, "value"))
        case "save_person": self = .savePerson(try c.get(PersonDraft.self, "person"))
        case "delete_person": self = .deletePerson(try c.getPerson("person_id"))
        case "undo": self = .undo
        case let other: throw unknownType(c, other)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .navigate(let destination):
            try c.put("navigate", "type")
            try c.put(destination, "destination")
        case .back: try c.put("back", "type")
        case .home: try c.put("home", "type")
        case .readAloud(let target):
            try c.put("read_aloud", "type")
            try c.put(target, "target")
        case .stopSpeaking: try c.put("stop_speaking", "type")
        case .repeatLast: try c.put("repeat_last", "type")
        case .nextStep: try c.put("next_step", "type")
        case .previousStep: try c.put("previous_step", "type")
        case .callDesk(let desk):
            try c.put("call_desk", "type")
            try c.putID(desk, "desk_id")
        case .openMap(let target):
            try c.put("open_map", "type")
            try c.put(target, "target")
        case .setSurfaceLanguage(let language):
            try c.put("set_surface_language", "type")
            try c.put(language, "language")
        case .setThinkIn(let language):
            try c.put("set_think_in", "type")
            try c.put(language.bcp47, "language")
        case .answerOnboarding(let answer):
            try c.put("answer_onboarding", "type")
            try c.put(WireOnboardingAnswer(answer), "answer")
        case .choose(let option):
            try c.put("choose", "type")
            try c.putID(option, "option_id")
        case .setPin(let pin):
            try c.put("set_pin", "type")
            try c.putID(pin, "pin_id")
        case .setMode(let mode):
            try c.put("set_mode", "type")
            try c.put(mode, "mode")
        case .confirm(let value):
            try c.put("confirm", "type")
            try c.put(value, "value")
        case .savePerson(let draft):
            try c.put("save_person", "type")
            try c.put(draft, "person")
        case .deletePerson(let id):
            try c.put("delete_person", "type")
            try c.putPerson(id, "person_id")
        case .undo: try c.put("undo", "type")
        }
    }
}

/// ADCore's `OnboardingAnswer`, in the intent contract's snake_case wire shape. Written here so the
/// router's wire does not depend on ADCore's own (camelCase) Codable spelling.
struct WireOnboardingAnswer: Codable {
    let value: OnboardingAnswer
    init(_ value: OnboardingAnswer) { self.value = value }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        switch try c.type() {
        case "pin": value = .pin(try c.get(WirePin.self, "pin").value)
        case "people": value = .people(try c.get([WireOnboardingPerson].self, "people").map(\.value))
        case "origin_and_language":
            value = .originAndLanguage(origin: try c.getNullable(WireOrigin.self, "origin")?.value,
                                       thinkIn: try c.get(String.self, "think_in"))
        case "goal": value = .goal(try c.get(Goal.self, "goal"))
        case "volunteered_status_word":
            value = .volunteeredStatusWord(StatusWord(rawValue: try c.get(String.self, "status_word")),
                                           person: try c.getPerson("person_id"))
        case let other: throw unknownType(c, other)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch value {
        case .pin(let pin):
            try c.put("pin", "type")
            try c.put(WirePin(pin), "pin")
        case .people(let people):
            try c.put("people", "type")
            try c.put(people.map(WireOnboardingPerson.init), "people")
        case let .originAndLanguage(origin, thinkIn):
            try c.put("origin_and_language", "type")
            try c.putNullable(origin.map(WireOrigin.init), "origin")
            try c.put(thinkIn, "think_in")
        case .goal(let goal):
            try c.put("goal", "type")
            try c.put(goal, "goal")
        case let .volunteeredStatusWord(word, person):
            try c.put("volunteered_status_word", "type")
            try c.put(word.rawValue, "status_word")
            try c.putPerson(person, "person_id")
        }
    }
}

/// `{"latitude": .., "longitude": .., "address": ..|null}`
struct WirePin: Codable {
    let value: Pin
    init(_ value: Pin) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        value = Pin(latitude: try c.get(Double.self, "latitude"), longitude: try c.get(Double.self, "longitude"),
                    address: try c.getNullable(String.self, "address"))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.put(value.latitude, "latitude")
        try c.put(value.longitude, "longitude")
        try c.putNullable(value.address, "address")
    }
}

/// `{"display_name": .., "age": ..|null}`
struct WireOnboardingPerson: Codable {
    let value: OnboardingPerson
    init(_ value: OnboardingPerson) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        value = OnboardingPerson(displayName: try c.get(String.self, "display_name"), age: try c.getNullable(Int.self, "age"))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.put(value.displayName, "display_name")
        try c.putNullable(value.age, "age")
    }
}

/// `{"country_code": "CU"}`
struct WireOrigin: Codable {
    let value: Origin
    init(_ value: Origin) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        value = Origin(countryCode: try c.get(String.self, "country_code"))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.put(value.countryCode, "country_code")
    }
}

/// The add/edit person form as a value. Only `displayName` and `thinkIn` are required; the
/// status word is optional and never asked for.
/// Wire: `{"person_id": ..|null, "display_name", "age": ..|null, "origin": {"country_code"}|null,
/// "think_in", "goal", "stage": 1-10|null, "mode": "resident"|"tourist"|null, "status_word": ..|null,
/// "surface_language": "es"|"en"|"ht"|null}`.
public struct PersonDraft: Hashable, Sendable, Codable {
    public var personID: PersonID?
    public var displayName: String
    public var age: Int?
    public var origin: Origin?
    public var thinkIn: String
    public var goal: Goal
    public var stage: Stage?
    public var mode: Mode?
    public var statusWord: String?
    /// BCP-47 surface this person reads (es/en/ht), nil to follow the app setting.
    public var surfaceLanguage: String?

    public init(personID: PersonID? = nil, displayName: String, age: Int? = nil, origin: Origin? = nil,
                thinkIn: String, goal: Goal, stage: Stage? = nil, mode: Mode? = nil, statusWord: String? = nil,
                surfaceLanguage: String? = nil) {
        self.surfaceLanguage = surfaceLanguage
        self.personID = personID
        self.displayName = displayName
        self.age = age
        self.origin = origin
        self.thinkIn = thinkIn
        self.goal = goal
        self.stage = stage
        self.mode = mode
        self.statusWord = statusWord
    }

    /// The form's current values for an existing person.
    public init(_ person: Person) {
        self.init(personID: person.id, displayName: person.displayName, age: person.age, origin: person.origin,
                  thinkIn: person.thinkInLanguageTag, goal: person.goal, stage: person.stage, mode: person.mode,
                  statusWord: person.statusWord?.rawValue, surfaceLanguage: person.surfaceLanguage?.minimalIdentifier)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        self.init(personID: try c.getNullablePerson("person_id"),
                  displayName: try c.get(String.self, "display_name"),
                  age: try c.getNullable(Int.self, "age"),
                  origin: try c.getNullable(WireOrigin.self, "origin")?.value,
                  thinkIn: try c.get(String.self, "think_in"),
                  goal: try c.get(Goal.self, "goal"),
                  stage: try c.getNullable(Int.self, "stage").map { n in
                      guard let s = Stage(rawValue: n) else {
                          throw DecodingError.dataCorruptedError(forKey: WireKey(stringValue: "stage"), in: c, debugDescription: "stage is 1-10")
                      }
                      return s
                  },
                  mode: try c.getNullable(Mode.self, "mode"),
                  statusWord: try c.getNullable(String.self, "status_word"),
                  surfaceLanguage: try c.getNullable(String.self, "surface_language"))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.putPerson(personID, "person_id")
        try c.put(displayName, "display_name")
        try c.putNullable(age, "age")
        try c.putNullable(origin.map(WireOrigin.init), "origin")
        try c.put(thinkIn, "think_in")
        try c.put(goal, "goal")
        try c.putNullable(stage?.rawValue, "stage")
        try c.putNullable(mode, "mode")
        try c.putNullable(statusWord, "status_word")
        try c.putNullable(surfaceLanguage, "surface_language")
    }
}
