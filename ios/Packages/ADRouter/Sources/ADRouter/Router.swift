import Foundation
import Observation
import ADCore
import ADLocale

/// Who asked. Used ONLY for the confirmation policy; never logged or sent anywhere.
public enum ActionSource: Hashable, Sendable {
    case touch, voice, appIntent, voiceOver, uiTest
}

/// What a performed action says back. Always speakable.
public struct Confirmation: Hashable, Sendable {
    public let key: StringKey
    /// The screen the action landed on, when it changed the screen.
    public let destination: Destination?
    public let card: CardID?
    public let desk: DeskID?

    public init(key: StringKey, destination: Destination? = nil, card: CardID? = nil, desk: DeskID? = nil) {
        self.key = key
        self.destination = destination
        self.card = card
        self.desk = desk
    }
}

public enum ActionOutcome: Hashable, Sendable {
    case performed(Confirmation)
    /// Leaves the app only after a yes (`.confirm(true)`), spoken or tapped. Never times out.
    case needsConfirmation(AppAction, prompt: StringKey)
    /// ONE question, 2-3 options, spoken and shown as buttons. Never times out.
    case clarifying(Clarification)
    case refused(reason: StringKey)

    /// The line to speak or announce for this outcome.
    public var speech: StringKey {
        switch self {
        case .performed(let c): c.key
        case .needsConfirmation(_, let prompt): prompt
        case .clarifying(let c): c.question
        case .refused(let reason): reason
        }
    }
}

/// Where a confirmed leave-app action goes.
public enum AppExit: Hashable, Sendable {
    case call(DeskID)
    case map(MapTarget)
}

/// What "read aloud" resolved to. The app turns it into words through ADLocale and speaks it
/// with ADVoice in the reply language (never Creole with an es/en voice).
public enum ReadContent: Hashable, Sendable {
    case destination(Destination)
    case card(CardID, person: PersonID?)
}

/// One of the demo pins the router can set.
public struct PinChoice: Hashable, Sendable, Identifiable {
    public let id: PinID
    /// Usually `RouterText.verbatim(address)`: street addresses are never translated.
    public let label: StringKey
    public let pin: Pin

    public init(id: PinID, label: StringKey, pin: Pin) {
        self.id = id
        self.label = label
        self.pin = pin
    }
}

public struct RouterConfig: Hashable, Sendable {
    /// Shown when the resolver is offline ("I can't look that up right now" plus the offices card).
    public var officesCard: CardID?
    /// The desk offered when nothing answers and the resolution named none.
    public var fallbackDesk: DeskID?

    public init(officesCard: CardID? = nil, fallbackDesk: DeskID? = nil) {
        self.officesCard = officesCard
        self.fallbackDesk = fallbackDesk
    }
}

/// The outside world, as the router sees it. The app implements this with ADVoice, the store,
/// UIApplication.open, and VoiceOver announcements. Tests record calls.
@MainActor
public protocol RouterEffects: AnyObject {
    func speak(_ content: ReadContent, language: String)
    func stopSpeaking()
    func leaveApp(_ exit: AppExit)
    func householdChanged(_ household: Household?)
    func languagesChanged(surface: SurfaceLanguage, thinkIn: SpokenLanguage)
    /// After every action (and every resolution), with whether the screen changed. The app speaks
    /// `outcome.speech` for voice sources and posts a screen-changed announcement when voice moved the screen.
    func didPerform(_ action: AppAction?, outcome: ActionOutcome, source: ActionSource, screenChanged: Bool, language: String)
}

/// The one router (ARCHITECTURE.md §13.1). Every control, voice command, App Intent, VoiceOver
/// action, and UI test calls `perform(_:from:)`. It checks ADCore's privacy and tourist rules
/// before every navigation and never leaves the app without a yes.
@MainActor
@Observable
public final class Router {
    public private(set) var path: [Destination]
    public private(set) var pendingClarification: Clarification?
    public private(set) var pendingConfirmation: AppAction?
    public private(set) var household: Household?
    public private(set) var draft: OnboardingDraft
    public private(set) var pinID: PinID?
    public private(set) var lastOutcome: ActionOutcome?
    /// BCP-47. Follows the sentence just spoken; a language switch sets it to the new surface.
    public private(set) var replyLanguage: String
    public private(set) var stepIndex: Int = 0
    public private(set) var lastRead: ReadContent?
    /// The last removed person and their position, for `undo`.
    public private(set) var lastDeleted: (person: Person, index: Int)?

    public var catalog: [Card]
    /// Buttons follow `surface`; spoken explanations follow `thinkIn`. The app mirrors these into
    /// ADLocale's `LanguageSettings` in `RouterEffects.languagesChanged` (and the environment locale).
    public private(set) var surface: SurfaceLanguage
    public private(set) var thinkIn: SpokenLanguage
    public let pins: [PinChoice]
    public let policy: IntentPolicy
    public let config: RouterConfig
    @ObservationIgnored private let facts: any FactResolving
    @ObservationIgnored private let heroes: HeroPolicy
    @ObservationIgnored public let matcher: any CommandMatcher
    @ObservationIgnored public weak var effects: (any RouterEffects)?

    public init(household: Household?, catalog: [Card], surface: SurfaceLanguage, thinkIn: SpokenLanguage? = nil,
                pins: [PinChoice],
                facts: some FactResolving, lensResolver: some OriginLensResolving, matcher: some CommandMatcher,
                policy: IntentPolicy = IntentPolicy(), config: RouterConfig = RouterConfig(),
                effects: (any RouterEffects)? = nil) {
        self.household = household
        self.catalog = catalog
        self.surface = surface
        self.thinkIn = thinkIn ?? SpokenLanguage(bcp47: surface.rawValue)
        self.pins = pins
        self.facts = facts
        self.heroes = HeroPolicy(lensResolver: lensResolver)
        self.matcher = matcher
        self.policy = policy
        self.config = config
        self.effects = effects
        self.draft = OnboardingDraft()
        self.replyLanguage = surface.rawValue
        self.path = household == nil ? [.onboarding(.pin)] : []
    }

    // MARK: Read-only views of the state

    /// The screen on top; nil only for the empty start screen (no household, onboarding closed).
    public var current: Destination? { path.last ?? (household == nil ? nil : .household) }

    /// Whose card is on screen: the most recent person in the path. Nil is the household surface.
    public var activePerson: PersonID? {
        for d in path.reversed() {
            switch d {
            case .person(let id), .stage(let id, _): return id
            case .card(_, let id?): return id
            default: continue
            }
        }
        return nil
    }

    public var cardSurface: CardSurface { activePerson.map(CardSurface.person) ?? .household }

    /// The active person's next steps (hero first), after ADCore's rules.
    public var nextSteps: [Card] {
        guard let id = activePerson, let person = household?.person(id) else { return [] }
        return heroes.nextSteps(for: person, catalog: catalog)
    }

    /// Cards a filter shows on the current surface (ADCore applies privacy and tourist rules first).
    public func cards(matching filter: CardFilter) -> [Card] {
        guard let household else { return [] }
        return HeroPolicy.cards(matching: filter, on: cardSurface, in: household, catalog: catalog)
    }

    /// The current screen's list of choices, in order: what "the second one" picks from when no
    /// clarifying question is pending.
    public var screenChoices: [ClarifyOption] {
        switch current {
        case .onboarding(.pin)?, .pin?:
            return pins.map { ClarifyOption(id: ClarifyOptionID(rawValue: "pin.\($0.id.rawValue)"), label: $0.label, action: .setPin($0.id)) }
        case .onboarding(.goal)?:
            return Goal.allCases.map { ClarifyOption(id: ClarifyOptionID(rawValue: "goal.\($0.rawValue)"), label: $0.labelKey,
                                                     action: .answerOnboarding(.goal($0))) }
        case .language?:
            return SurfaceLanguage.allCases.map { ClarifyOption(id: ClarifyOptionID(rawValue: "language.\($0.rawValue)"),
                                                                label: RouterText.surfaceName($0.rawValue),
                                                                action: .setSurfaceLanguage($0)) }
        case .household?:
            return (household?.people ?? []).map { ClarifyOption(id: ClarifyOptionID(rawValue: "person.\($0.id.rawValue.uuidString)"),
                                                                 label: RouterText.verbatim($0.displayName),
                                                                 action: .navigate(.person($0.id))) }
        case .person(let id)?:
            return nextSteps.map { cardChoice($0, person: id) }
        case .cards(let filter)?:
            return cards(matching: filter).map { cardChoice($0, person: activePerson) }
        default:
            return []
        }
    }

    public var currentChoices: [ClarifyOption] { pendingClarification?.options ?? screenChoices }

    /// Ids only (§13.2).
    public var context: RouteContext {
        let person = activePerson.flatMap { household?.person($0) }
        var card: CardID?
        var desk: DeskID?
        switch current {
        case .card(let id, _)?:
            card = id
            desk = catalog.first { $0.id == id }?.desk
        case .desk(let id)?:
            desk = id
        default: break
        }
        return RouteContext(destination: current, personID: activePerson, cardID: card, deskID: desk,
                            stage: person?.stage, mode: person?.mode,
                            choiceIDs: currentChoices.map(\.id), awaitingConfirmation: pendingConfirmation != nil)
    }

    // MARK: The one entry point

    @discardableResult
    public func perform(_ action: AppAction, from source: ActionSource) -> ActionOutcome {
        let before = current
        let outcome = apply(action, from: source, depth: 0)
        finish(action, outcome, source, screenChanged: current != before)
        return outcome
    }

    /// Applies ADCore-independent intent policy to a resolution (from the matcher or `/v1/ask`).
    @discardableResult
    public func handle(_ resolution: IntentResolution, from source: ActionSource) -> ActionOutcome {
        replyLanguage = resolution.replyLanguage
        let before = current
        let outcome: ActionOutcome
        var action: AppAction?
        switch policy.decide(resolution) {
        case .perform(let a):
            action = a
            if let reason = groundingProblem(a, resolution.grounding) {
                outcome = .refused(reason: reason)
            } else {
                outcome = apply(a, from: source, depth: 0)
            }
        case .clarify(let c):
            pendingClarification = c
            outcome = .clarifying(c)
        case .handToDesk(let desk):
            outcome = handToDesk(desk ?? config.fallbackDesk, key: RouterText.dontHaveThis)
        }
        finish(action, outcome, source, screenChanged: current != before)
        return outcome
    }

    /// Voice or typed text: the on-device matcher first, then the remote resolver, then the offline path.
    /// When the sentence is in a different surface language than the screen, the UI follows it.
    /// Same language keeps the current screen language.
    @discardableResult
    public func hear(_ text: String, language: String, remote: (any IntentResolving)? = nil,
                     from source: ActionSource = .voice) async -> ActionOutcome {
        let spoken = SpokenSurface.resolve(text: text, tagged: language, current: surface)
        followSpokenSurface(spoken, from: source)
        replyLanguage = spoken.rawValue
        let utterance = Utterance(text: text, language: spoken.rawValue, context: context)
        if let local = matcher.match(utterance, choices: currentChoices) { return handle(local, from: source) }
        if let remote, let resolution = try? await remote.resolve(utterance) { return handle(resolution, from: source) }
        return offline(source)
    }

    /// Buttons stay on `surface`. A voice sentence in another shipped language flips the
    /// whole UI; a sentence already in the current language does nothing here.
    private func followSpokenSurface(_ spoken: SurfaceLanguage, from source: ActionSource) {
        guard source == .voice || source == .appIntent else { return }
        guard spoken != surface else { return }
        surface = spoken
        replyLanguage = spoken.rawValue
        effects?.languagesChanged(surface: surface, thinkIn: thinkIn)
    }

    /// Only the system back gesture uses this (NavigationStack's path binding): it can pop, never push.
    public func systemPopped(to newPath: [Destination]) {
        guard newPath.count < path.count, Array(path.prefix(newPath.count)) == newPath else { return }
        while path.count > newPath.count { perform(.back, from: .touch) }
    }

    // MARK: Actions

    private func finish(_ action: AppAction?, _ outcome: ActionOutcome, _ source: ActionSource, screenChanged: Bool) {
        lastOutcome = outcome
        effects?.didPerform(action, outcome: outcome, source: source, screenChanged: screenChanged, language: replyLanguage)
    }

    private func apply(_ action: AppAction, from source: ActionSource, depth: Int) -> ActionOutcome {
        switch action {
        case .confirm, .readAloud, .repeatLast, .stopSpeaking: break
        default: pendingConfirmation = nil
        }
        switch action {
        case .choose, .readAloud, .repeatLast, .stopSpeaking: break
        default: pendingClarification = nil
        }

        switch action {
        case .navigate(let destination):
            return navigate(destination)
        case .back:
            // Onboarding has no step back (ADCore's draft only moves forward): its screen is the start.
            guard !path.isEmpty, household != nil || path.count > 1 else { return .refused(reason: RouterText.refusedAlreadyHome) }
            path.removeLast()
            return .performed(Confirmation(key: RouterText.wentBack, destination: current))
        case .home:
            path = household == nil ? [.onboarding(draft.nextStep ?? .pin)] : []
            return .performed(Confirmation(key: RouterText.wentHome, destination: current))
        case .readAloud(let target):
            return read(target)
        case .stopSpeaking:
            effects?.stopSpeaking()
            return .performed(Confirmation(key: RouterText.stopped))
        case .repeatLast:
            if let pendingClarification { return .clarifying(pendingClarification) }
            if let pendingConfirmation { return .needsConfirmation(pendingConfirmation, prompt: prompt(for: pendingConfirmation)) }
            guard let lastRead else { return .refused(reason: RouterText.refusedNothingToRepeat) }
            effects?.speak(lastRead, language: replyLanguage)
            return .performed(Confirmation(key: RouterText.reading))
        case .nextStep:
            return step(by: 1)
        case .previousStep:
            return step(by: -1)
        case .callDesk:
            pendingConfirmation = action
            return .needsConfirmation(action, prompt: RouterText.askCallDesk)
        case .openMap(let target):
            if case .place(let ref) = target, !isPlace(ref) {
                return .refused(reason: RouterText.refusedNotAPlace)
            }
            pendingConfirmation = action
            return .needsConfirmation(action, prompt: RouterText.askOpenMap)
        case .confirm(let yes):
            guard let pending = pendingConfirmation else { return .refused(reason: RouterText.refusedNothingToConfirm) }
            pendingConfirmation = nil
            guard yes else { return .performed(Confirmation(key: RouterText.cancelled)) }
            switch pending {
            case .callDesk(let desk):
                effects?.leaveApp(.call(desk))
                return .performed(Confirmation(key: RouterText.leavingToCall, desk: desk))
            case .openMap(let target):
                effects?.leaveApp(.map(target))
                if case .desk(let desk) = target { return .performed(Confirmation(key: RouterText.leavingToMap, desk: desk)) }
                return .performed(Confirmation(key: RouterText.leavingToMap))
            default:
                return .refused(reason: RouterText.refusedNothingToConfirm)
            }
        case .setSurfaceLanguage(let language):
            surface = language
            replyLanguage = language.rawValue
            effects?.languagesChanged(surface: surface, thinkIn: thinkIn)
            return .performed(Confirmation(key: RouterText.languageChanged))
        case .setThinkIn(let language):
            thinkIn = language
            effects?.languagesChanged(surface: surface, thinkIn: thinkIn)
            return .performed(Confirmation(key: RouterText.thinkInChanged))
        case .answerOnboarding(let answer):
            return answerOnboarding(answer)
        case .choose(let id):
            guard depth == 0 else { return .refused(reason: RouterText.refusedNoChoice) }
            if let option = pendingClarification?.option(id) ?? screenChoices.first(where: { $0.id == id }) {
                pendingClarification = nil
                return apply(option.action, from: source, depth: depth + 1)
            }
            return .refused(reason: RouterText.refusedNoChoice)
        case .setPin(let id):
            guard let choice = pins.first(where: { $0.id == id }) else { return .refused(reason: RouterText.refusedUnknown) }
            if household == nil {
                guard case .onboarding(.pin)? = current else { return .refused(reason: RouterText.refusedNotOnboarding) }
                let outcome = answerOnboarding(.pin(choice.pin))
                if case .performed = outcome { pinID = id }
                return outcome
            }
            household?.pin = choice.pin
            pinID = id
            effects?.householdChanged(household)
            return .performed(Confirmation(key: RouterText.pinChanged))
        case .savePerson(let draft):
            return save(draft)
        case .deletePerson(let id):
            if let reason = refusal(for: .person(id), viewer: activePerson) { return .refused(reason: reason) }
            guard let index = household?.people.firstIndex(where: { $0.id == id }), let person = household?.person(id) else {
                return .refused(reason: RouterText.refusedUnknown)
            }
            household?.remove(id)
            lastDeleted = (person, index)
            path.removeAll { Self.person(in: $0) == id }
            effects?.householdChanged(household)
            return .performed(Confirmation(key: RouterText.deleted, destination: current))
        case .undo:
            guard let (person, _) = lastDeleted, household != nil else { return .refused(reason: RouterText.refusedNothingToUndo) }
            do { try household?.add(person) } catch { return .refused(reason: RouterText.refusedUnknown) }
            lastDeleted = nil
            effects?.householdChanged(household)
            return .performed(Confirmation(key: RouterText.restored, destination: current))
        case .setMode(let mode):
            guard let id = activePerson, household?.person(id) != nil else { return .refused(reason: RouterText.refusedNoPerson) }
            household?.update(id) { (person: inout Person) in
                if mode == .tourist { person.becomeTourist() } else { person.iLiveHereNow() }
            }
            dropHiddenDestinations()
            effects?.householdChanged(household)
            return .performed(Confirmation(key: mode == .tourist ? RouterText.modeTourist : RouterText.modeResident))
        }
    }

    private func navigate(_ destination: Destination) -> ActionOutcome {
        if let reason = refusal(for: destination, viewer: activePerson) { return .refused(reason: reason) }
        switch destination {
        case .household:
            path = []
        case .onboarding:
            if case .onboarding? = path.last { path.removeLast() }
            path.append(destination)
        case .person:
            stepIndex = 0
            if path.last != destination { path.append(destination) }
        default:
            if path.last != destination { path.append(destination) }
        }
        var card: CardID?
        if case .card(let id, _) = destination { card = id }
        var desk: DeskID?
        if case .desk(let id) = destination { desk = id }
        return .performed(Confirmation(key: RouterText.opened, destination: destination, card: card, desk: desk))
    }

    /// Why `viewer`'s surface may not open `destination` (ADCore's PrivacyPolicy, tourist rule), or nil.
    public func refusal(for destination: Destination, viewer: PersonID?) -> StringKey? {
        func personProblem(_ id: PersonID) -> StringKey? {
            guard let household, household.person(id) != nil else { return RouterText.refusedUnknown }
            // Another member's card is reachable only where the roster is visible (never from a child's card).
            if let viewer, viewer != id, !PrivacyPolicy.isVisible(.household, on: .person(viewer), in: household) {
                return RouterText.refusedPrivacy
            }
            return nil
        }
        switch destination {
        case .person(let id), .editPerson(let id):
            return personProblem(id)
        case let .stage(id, stage):
            if let problem = personProblem(id) { return problem }
            if household?.person(id)?.mode == .tourist, stage.isSkippedInTouristMode { return RouterText.refusedTourist }
            return nil
        case let .card(id, person):
            guard let household, let card = catalog.first(where: { $0.id == id }) else { return RouterText.refusedUnknown }
            let owner = person ?? viewer
            if let owner, let problem = personProblem(owner) { return problem }
            let surface = owner.map(CardSurface.person) ?? .household
            if HeroPolicy.canShow(card, on: surface, in: household) { return nil }
            let mode = PrivacyPolicy.viewerMode(of: surface, in: household)
            return mode == .tourist && card.isImmigrationContent ? RouterText.refusedTourist : RouterText.refusedPrivacy
        case .onboarding:
            return household == nil ? nil : RouterText.refusedNotOnboarding
        case .household, .addPerson, .cards, .desk, .pin, .settings, .language, .voice:
            return nil
        }
    }

    private func read(_ target: ReadTarget) -> ActionOutcome {
        let content: ReadContent
        switch target {
        case .screen:
            content = .destination(current ?? .household)
        case .card(let id):
            if let reason = refusal(for: .card(id, person: activePerson), viewer: activePerson) { return .refused(reason: reason) }
            content = .card(id, person: activePerson)
        case .step:
            let steps = nextSteps
            guard !steps.isEmpty else { return .refused(reason: activePerson == nil ? RouterText.refusedNoPerson : RouterText.refusedNoSteps) }
            content = .card(steps[min(stepIndex, steps.count - 1)].id, person: activePerson)
        }
        lastRead = content
        effects?.speak(content, language: replyLanguage)
        return .performed(Confirmation(key: RouterText.reading))
    }

    private func step(by delta: Int) -> ActionOutcome {
        guard let person = activePerson else { return .refused(reason: RouterText.refusedNoPerson) }
        let steps = nextSteps
        guard !steps.isEmpty else { return .refused(reason: RouterText.refusedNoSteps) }
        let onStep = if case .card(let id, _)? = current { steps.contains { $0.id == id } } else { false }
        stepIndex = onStep ? min(max(stepIndex + delta, 0), steps.count - 1) : 0
        if onStep { path.removeLast() }
        return navigate(.card(steps[stepIndex].id, person: person))
    }

    private func answerOnboarding(_ answer: OnboardingAnswer) -> ActionOutcome {
        guard household == nil, case .onboarding? = current else { return .refused(reason: RouterText.refusedNotOnboarding) }
        let (next, outcome) = Onboarding.apply(answer, to: draft)
        switch outcome {
        case .next(let step, _):
            draft = next
            path = [.onboarding(step)]
            return .performed(Confirmation(key: RouterText.onboardingNext, destination: .onboarding(step)))
        case .complete:
            guard let made = next.makeHousehold() else { return .refused(reason: RouterText.refusedUnknown) }
            draft = next
            household = made
            path = []
            effects?.householdChanged(made)
            return .performed(Confirmation(key: RouterText.onboardingDone, destination: .household))
        case .invalid(let error, _, _):
            return .refused(reason: error.messageKey)
        }
    }

    private func handToDesk(_ desk: DeskID?, key: StringKey) -> ActionOutcome {
        guard let desk else { return .refused(reason: key) }
        path.append(.desk(desk))
        return .performed(Confirmation(key: key, destination: .desk(desk), desk: desk))
    }

    private func offline(_ source: ActionSource) -> ActionOutcome {
        let before = current
        var outcome: ActionOutcome = .refused(reason: RouterText.offline)
        if let card = config.officesCard, refusal(for: .card(card, person: activePerson), viewer: activePerson) == nil {
            _ = navigate(.card(card, person: activePerson))
            outcome = .performed(Confirmation(key: RouterText.offline, destination: current, card: card))
        }
        finish(nil, outcome, source, screenChanged: current != before)
        return outcome
    }

    /// A confident answer must be grounded in the card it opens: every fact ref is on that card.
    private func groundingProblem(_ action: AppAction, _ grounding: Grounding?) -> StringKey? {
        guard case .card(let groundedCard, let refs)? = grounding else { return nil }
        guard case .navigate(.card(let opened, _)) = action, opened == groundedCard,
              let card = catalog.first(where: { $0.id == opened }) else { return RouterText.refusedUngrounded }
        return refs.allSatisfy { card.facts.contains($0.ledgerFactID) } ? nil : RouterText.refusedUngrounded
    }

    private func isPlace(_ ref: FactRef) -> Bool {
        guard case .fact(let fact)? = facts.outcome(for: ref.ledgerFactID), case .place? = fact.displayValue else { return false }
        return true
    }

    private func prompt(for action: AppAction) -> StringKey {
        if case .openMap = action { return RouterText.askOpenMap }
        return RouterText.askCallDesk
    }

    private func cardChoice(_ card: Card, person: PersonID?) -> ClarifyOption {
        ClarifyOption(id: ClarifyOptionID(rawValue: "card.\(card.id.rawValue)"), label: card.titleKey,
                      action: .navigate(.card(card.id, person: person)))
    }

    private static func person(in destination: Destination) -> PersonID? {
        switch destination {
        case .person(let id), .stage(let id, _): id
        case .card(_, let id): id
        default: nil
        }
    }

    /// Add (no id) or update (id) a person from the form. Stage and mode follow ADCore's rules:
    /// a tourist cannot be put on a skipped stage.
    private func save(_ draft: PersonDraft) -> ActionOutcome {
        guard household != nil else { return .refused(reason: RouterText.refusedNotOnboarding) }
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, draft.age.map({ (0...130).contains($0) }) ?? true else {
            return .refused(reason: RouterText.refusedInvalidPerson)
        }
        func apply(_ p: inout Person) throws(StageError) {
            p.displayName = name
            p.age = draft.age
            p.origin = draft.origin
            p.thinkIn = Locale.Language(identifier: draft.thinkIn)
            p.statusWord = draft.statusWord.flatMap { $0.isEmpty ? nil : StatusWord(rawValue: $0) }
            p.surfaceLanguage = draft.surfaceLanguage.map { Locale.Language(identifier: $0) }
            if p.goal != draft.goal {
                p.goal = draft.goal
                if draft.mode == nil { if draft.goal == .visit { p.becomeTourist() } else if p.mode == .tourist { p.iLiveHereNow(goal: draft.goal) } }
            }
            switch draft.mode {
            case .tourist?: p.becomeTourist()
            case .resident? where p.mode == .tourist: p.iLiveHereNow(goal: draft.goal == .visit ? nil : draft.goal)
            default: break
            }
            if let stage = draft.stage, stage != p.stage { try p.setStage(stage) }
        }
        if let id = draft.personID {
            if let reason = refusal(for: .person(id), viewer: activePerson) { return .refused(reason: reason) }
            var failed = false
            let found = household?.update(id) { (p: inout Person) in
                do { try apply(&p) } catch { failed = true }
            } ?? false
            guard found else { return .refused(reason: RouterText.refusedUnknown) }
            if failed { return .refused(reason: RouterText.refusedTourist) }
            if case .editPerson(id)? = path.last { path.removeLast() }
            dropHiddenDestinations()
            effects?.householdChanged(household)
            return .performed(Confirmation(key: RouterText.saved, destination: current))
        }
        var person = Person(displayName: name, thinkIn: Locale.Language(identifier: draft.thinkIn), goal: draft.goal)
        do { try apply(&person) } catch { return .refused(reason: RouterText.refusedTourist) }
        do { try household?.add(person) } catch { return .refused(reason: RouterText.refusedUnknown) }
        if case .addPerson? = path.last { path.removeLast() }
        path.append(.person(person.id))
        stepIndex = 0
        effects?.householdChanged(household)
        return .performed(Confirmation(key: RouterText.saved, destination: .person(person.id)))
    }

    /// After a mode change, screens the person may no longer see are closed.
    private func dropHiddenDestinations() {
        var kept: [Destination] = []
        for d in path {
            let viewer = kept.reversed().lazy.compactMap { d -> PersonID? in
                switch d {
                case .person(let id), .stage(let id, _): id
                case .card(_, let id): id
                default: nil
                }
            }.first
            if refusal(for: d, viewer: viewer) != nil { break }
            kept.append(d)
        }
        path = kept
    }
}
