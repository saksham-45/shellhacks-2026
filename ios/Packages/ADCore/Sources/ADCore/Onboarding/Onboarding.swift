import Foundation

/// The four questions, myMiami plan, "Who it is for", in order. Each is answerable by
/// voice through the router (`AppAction.answerOnboarding`). The status word is never a step.
public enum OnboardingStep: String, Hashable, Codable, Sendable, CaseIterable {
    /// "Where are you sleeping, or where is the pin?"
    case pin
    /// "Who is in the household, each as their own person."
    case people
    /// "Where did this person live before, and what language do they actually think in."
    /// Asked once per person.
    case originAndLanguage = "origin_and_language"
    /// "What are they here to do right now: arrive, study, work, reunite, visit, or just get
    /// through this week." Asked once per person.
    case goal

    /// The question, as text to show and speak (table "ADCore").
    public var prompt: StringKey {
        switch self {
        case .pin: .adCore("onboarding.q1")
        case .people: .adCore("onboarding.q2")
        case .originAndLanguage: .adCore("onboarding.q3")
        case .goal: .adCore("onboarding.q4")
        }
    }
}

/// One person named in answer to question 2.
public struct OnboardingPerson: Hashable, Codable, Sendable {
    public var displayName: String
    public var age: Int?

    public init(displayName: String, age: Int? = nil) {
        self.displayName = displayName
        self.age = age
    }

    /// Router wire keys are snake_case (ARCHITECTURE.md §13.2).
    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case age
    }
}

/// A typed answer to one step. Question 3 and 4 answers apply to `OnboardingDraft.pendingPerson`.
public enum OnboardingAnswer: Hashable, Sendable {
    /// Question 1. The router/ADCityPack turns spoken or typed text into a pin first.
    case pin(Pin)
    /// Question 2.
    case people([OnboardingPerson])
    /// Question 3. `origin` nil means "born here" or not given. `thinkIn` is BCP-47 ("hi", "ht").
    case originAndLanguage(origin: Origin?, thinkIn: String)
    /// Question 4.
    case goal(Goal)
    /// Never prompted. Only when a person offers it on their own; applies to that person.
    case volunteeredStatusWord(StatusWord, person: PersonID)
}

extension OnboardingAnswer: Codable {
    private enum Kind: String, Codable {
        case pin, people, originAndLanguage = "origin_and_language", goal
        case volunteeredStatusWord = "volunteered_status_word"
    }

    /// Tagged JSON with snake_case keys, as the router's AppAction.answerOnboarding carries it:
    /// {"type":"origin_and_language","origin_country_code":"HT","think_in":"ht"}.
    private enum CodingKeys: String, CodingKey {
        case type, pin, people, goal
        case originCountryCode = "origin_country_code"
        case thinkIn = "think_in"
        case statusWord = "status_word"
        case personID = "person_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .pin: self = .pin(try c.decode(Pin.self, forKey: .pin))
        case .people: self = .people(try c.decode([OnboardingPerson].self, forKey: .people))
        case .originAndLanguage:
            self = .originAndLanguage(origin: try c.decodeIfPresent(String.self, forKey: .originCountryCode).map(Origin.init(countryCode:)),
                                      thinkIn: try c.decode(String.self, forKey: .thinkIn))
        case .goal: self = .goal(try c.decode(Goal.self, forKey: .goal))
        case .volunteeredStatusWord:
            self = .volunteeredStatusWord(try c.decode(StatusWord.self, forKey: .statusWord),
                                          person: try c.decode(PersonID.self, forKey: .personID))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pin(let pin):
            try c.encode(Kind.pin, forKey: .type)
            try c.encode(pin, forKey: .pin)
        case .people(let people):
            try c.encode(Kind.people, forKey: .type)
            try c.encode(people, forKey: .people)
        case let .originAndLanguage(origin, thinkIn):
            try c.encode(Kind.originAndLanguage, forKey: .type)
            try c.encodeIfPresent(origin?.countryCode, forKey: .originCountryCode)
            try c.encode(thinkIn, forKey: .thinkIn)
        case .goal(let goal):
            try c.encode(Kind.goal, forKey: .type)
            try c.encode(goal, forKey: .goal)
        case let .volunteeredStatusWord(word, person):
            try c.encode(Kind.volunteeredStatusWord, forKey: .type)
            try c.encode(word, forKey: .statusWord)
            try c.encode(person, forKey: .personID)
        }
    }
}

/// Why an answer was not accepted. The same step is asked again.
public enum OnboardingError: Error, Hashable, Codable, Sendable {
    case invalidPin
    case noPeople
    case unnamedPerson(index: Int)
    case invalidAge(index: Int)
    case invalidLanguage
    /// The answer belongs to another step than the one being asked.
    case unexpectedAnswer(expected: OnboardingStep?)
    case unknownPerson(PersonID)

    /// Text to show and speak before asking again (table "ADCore").
    public var messageKey: StringKey {
        switch self {
        case .invalidPin: .adCore("onboarding.error.invalid_pin")
        case .noPeople: .adCore("onboarding.error.no_people")
        case .unnamedPerson: .adCore("onboarding.error.unnamed_person")
        case .invalidAge: .adCore("onboarding.error.invalid_age")
        case .invalidLanguage: .adCore("onboarding.error.invalid_language")
        case .unexpectedAnswer: .adCore("onboarding.error.unexpected_answer")
        case .unknownPerson: .adCore("onboarding.error.unknown_person")
        }
    }
}

/// Onboarding in progress. Resumable (Codable). Built only through `Onboarding.apply`.
public struct OnboardingDraft: Hashable, Codable, Sendable {
    public struct DraftPerson: Hashable, Codable, Sendable, Identifiable {
        public let id: PersonID
        public let displayName: String
        public let age: Int?
        public fileprivate(set) var origin: Origin?
        public fileprivate(set) var thinkIn: String?
        public fileprivate(set) var goal: Goal?
        public fileprivate(set) var statusWord: StatusWord?
        fileprivate var answeredOrigin: Bool
    }

    public fileprivate(set) var pin: Pin?
    public fileprivate(set) var people: [DraftPerson]

    public init() {
        pin = nil
        people = []
    }

    /// The step to ask next; nil when complete. Order: pin, people, then for each person
    /// origin-and-language followed by goal.
    public var nextStep: OnboardingStep? { pending?.step }

    /// Whose question 3 or 4 is being asked; nil for questions 1 and 2 and when complete.
    public var pendingPerson: PersonID? { pending?.person }

    public var isComplete: Bool { pending == nil }

    /// What to show and speak for the step being asked; nil when complete. Questions 3 and 4
    /// carry whose question it is, so a voice-only listener in a household of several people
    /// knows who is meant.
    public var prompt: OnboardingPrompt? {
        guard let pending else { return nil }
        let name = pending.person.flatMap { id in people.first { $0.id == id }?.displayName }
        return OnboardingPrompt(question: pending.step.prompt, personName: name)
    }

    private var pending: (step: OnboardingStep, person: PersonID?)? {
        if pin == nil { return (.pin, nil) }
        if people.isEmpty { return (.people, nil) }
        for person in people {
            if !person.answeredOrigin { return (.originAndLanguage, person.id) }
            if person.goal == nil { return (.goal, person.id) }
        }
        return nil
    }

    /// The household, once every step is answered.
    public func makeHousehold() -> Household? {
        guard isComplete, let pin else { return nil }
        let persons = people.compactMap { p -> Person? in
            guard let tag = p.thinkIn, let goal = p.goal else { return nil }
            return Person(id: p.id, displayName: p.displayName, age: p.age, origin: p.origin,
                          thinkIn: Locale.Language(identifier: tag), goal: goal, statusWord: p.statusWord)
        }
        return try? Household(pin: pin, people: persons)
    }
}

/// The question to ask, and for questions 3 and 4 whose it is. The UI shows and speaks
/// `leadIn` (formatted with `personName`) right before `question`.
public struct OnboardingPrompt: Hashable, Sendable {
    public let question: StringKey
    /// The person's name exactly as the household gave it; never translated.
    public let personName: String?

    /// "For %@:" (table "ADCore", one `%@`); nil on questions 1 and 2.
    public var leadIn: StringKey? { personName == nil ? nil : .adCore("onboarding.about_person") }
}

/// The result of one answer.
public enum OnboardingOutcome: Hashable, Sendable {
    /// Ask this step next (for `person`, on questions 3 and 4).
    case next(OnboardingStep, person: PersonID?)
    /// Every step answered: `OnboardingDraft.makeHousehold()` returns the household.
    case complete
    /// Not accepted; the draft is unchanged and the same step is asked again.
    case invalid(OnboardingError, reask: OnboardingStep?, person: PersonID?)
}

public enum Onboarding {
    /// Pure: applies one answer and returns the new draft and what to do next. Everyone starts
    /// at stage 1; goal `.visit` starts in tourist mode. No step is skipped for tourists: all
    /// four questions apply to everyone. The status word is never asked.
    public static func apply(_ answer: OnboardingAnswer, to draft: OnboardingDraft) -> (OnboardingDraft, OnboardingOutcome) {
        var new = draft
        func invalid(_ error: OnboardingError) -> (OnboardingDraft, OnboardingOutcome) {
            (draft, .invalid(error, reask: draft.nextStep, person: draft.pendingPerson))
        }
        func expecting(_ step: OnboardingStep) -> Bool { draft.nextStep == step }

        switch answer {
        case .pin(let pin):
            guard expecting(.pin) else { return invalid(.unexpectedAnswer(expected: draft.nextStep)) }
            guard pin.isValid else { return invalid(.invalidPin) }
            new.pin = pin
        case .people(let entries):
            guard expecting(.people) else { return invalid(.unexpectedAnswer(expected: draft.nextStep)) }
            guard !entries.isEmpty else { return invalid(.noPeople) }
            var people: [OnboardingDraft.DraftPerson] = []
            for (index, entry) in entries.enumerated() {
                let name = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return invalid(.unnamedPerson(index: index)) }
                if let age = entry.age, !(0...130).contains(age) { return invalid(.invalidAge(index: index)) }
                people.append(.init(id: PersonID(), displayName: name, age: entry.age, answeredOrigin: false))
            }
            new.people = people
        case let .originAndLanguage(origin, thinkIn):
            guard expecting(.originAndLanguage), let id = draft.pendingPerson,
                  let i = new.people.firstIndex(where: { $0.id == id })
            else { return invalid(.unexpectedAnswer(expected: draft.nextStep)) }
            let tag = thinkIn.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, Locale.Language(identifier: tag).languageCode != nil else { return invalid(.invalidLanguage) }
            new.people[i].origin = origin
            new.people[i].thinkIn = Locale.Language(identifier: tag).minimalIdentifier
            new.people[i].answeredOrigin = true
        case .goal(let goal):
            guard expecting(.goal), let id = draft.pendingPerson,
                  let i = new.people.firstIndex(where: { $0.id == id })
            else { return invalid(.unexpectedAnswer(expected: draft.nextStep)) }
            new.people[i].goal = goal
        case let .volunteeredStatusWord(word, person):
            // Not a step: does not advance, and is never prompted.
            guard let i = new.people.firstIndex(where: { $0.id == person }) else { return invalid(.unknownPerson(person)) }
            new.people[i].statusWord = word
        }
        guard let step = new.nextStep else { return (new, .complete) }
        return (new, .next(step, person: new.pendingPerson))
    }
}
