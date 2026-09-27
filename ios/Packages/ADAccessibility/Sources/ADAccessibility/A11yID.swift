// accessibilityIdentifier contract for the test UI (docs/accessibility.md §9).
// Single source of truth: the app sets these, ios/Tests/Accessibility queries them.
// Identifiers are never shown or spoken; they must never be used as labels (A11Y-VO-02).
// Rules: lowercase dotted "a11y.<screen>.<element>", camelCase inside a segment, every segment starts
// with a letter, stable across languages and releases. Dynamic rows append a stable model id
// (UUID or registry id), never a display name or an index.

import ADCore

public enum A11yID {
    // MARK: Household (root)
    public enum Household {
        public static let list = "a11y.household.list"                 // screen anchor
        public static let addPerson = "a11y.household.addPerson"
        public static let settings = "a11y.household.settings"
        public static let pin = "a11y.household.pin"
        public static let cards = "a11y.household.cards"
        public static let rowPrefix = "a11y.household.row."
        public static func row(_ personID: String) -> String { rowPrefix + personID }
    }

    // MARK: Onboarding (the four questions, ADCore `OnboardingStep`; never a status question)
    public enum Onboarding {
        public static let form = "a11y.onboarding.form"                // screen anchor
        /// The current question text (spoken, and VoiceOver focus moves here on each step).
        public static let question = "a11y.onboarding.question"
        public static let next = "a11y.onboarding.next"
        public static let back = "a11y.onboarding.back"
        public static let skip = "a11y.onboarding.skip"
        public static let stepPrefix = "a11y.onboarding.step."
        /// Container of the step being asked. Exactly one exists at a time.
        public static func step(_ step: OnboardingStep) -> String {
            switch step {
            case .pin: stepPrefix + "pin"
            case .people: stepPrefix + "people"
            case .originAndLanguage: stepPrefix + "originAndLanguage"
            case .goal: stepPrefix + "goal"
            }
        }
        /// The only step identifiers that may ever appear, in order.
        public static var allSteps: [String] { OnboardingStep.allCases.map(step) }
    }

    // MARK: Add person (sheet or push)
    public enum AddPerson {
        public static let form = "a11y.addPerson.form"                 // screen anchor
        public static let name = "a11y.addPerson.name"
        public static let stage = "a11y.addPerson.stage"
        public static let origin = "a11y.addPerson.origin"
        public static let language = "a11y.addPerson.language"
        public static let thinkIn = "a11y.addPerson.thinkIn"
        public static let mode = "a11y.addPerson.mode"
        public static let save = "a11y.addPerson.save"
        public static let cancel = "a11y.addPerson.cancel"
        public static let error = "a11y.addPerson.error"
    }

    // MARK: Person detail
    public enum PersonDetail {
        public static let list = "a11y.personDetail.list"              // screen anchor
        public static let name = "a11y.personDetail.name"
        public static let stage = "a11y.personDetail.stage"
        public static let hero = "a11y.personDetail.hero"
        public static let nextSteps = "a11y.personDetail.nextSteps"
        public static let edit = "a11y.personDetail.edit"
        public static let delete = "a11y.personDetail.delete"
        public static let undo = "a11y.personDetail.undo"
    }

    // MARK: Settings / language switch
    public enum Settings {
        public static let form = "a11y.settings.form"                  // screen anchor
        public static let languageES = "a11y.settings.language.es"
        public static let languageEN = "a11y.settings.language.en"
        public static let languageHT = "a11y.settings.language.ht"
        public static func language(_ code: String) -> String { "a11y.settings.language.\(code)" }
        public static let thinkIn = "a11y.settings.thinkIn"
        public static let mode = "a11y.settings.mode"
        public static let done = "a11y.settings.done"
    }

    // MARK: Pin switch (two demo addresses)
    public enum Pin {
        public static let list = "a11y.pin.list"                       // screen anchor
        public static let kendall = "a11y.pin.option.kendall"          // 11200 SW 137th Ave 33186
        public static let downtown = "a11y.pin.option.downtown"        // 111 NW 1st St 33128
        public static let current = "a11y.pin.current"
    }

    // MARK: Card list
    public enum Cards {
        public static let list = "a11y.cards.list"                     // screen anchor
        public static let rowPrefix = "a11y.cards.row."
        /// Same scheme as `ADAccessibility.identifier(forCard:)` (which calls this).
        public static func row(_ cardID: String) -> String { rowPrefix + cardID }
    }

    // MARK: Card detail with facts
    public enum Card {
        public static let list = "a11y.card.list"                      // screen anchor
        public static let title = "a11y.card.title"
        public static let readAloud = "a11y.card.readAloud"
        /// Visible only while the card is being read aloud (its presence means reading started).
        public static let stopReading = "a11y.card.stopReading"
        public static let desk = "a11y.card.desk"
        public static let call = "a11y.card.call"
        public static let factPrefix = "a11y.card.fact."
        /// One combined element per fact (value + qualifier + source slot). There is no separate
        /// source identifier: the slot is part of this element's label (A11Y-VO-04, A11Y-FACT-01).
        public static func fact(_ factID: String) -> String { factPrefix + factID }
    }

    // MARK: Desk handoff (Destination.desk)
    public enum Desk {
        public static let panel = "a11y.desk.panel"                    // screen anchor
        public static let call = "a11y.desk.call"                      // AppAction.callDesk: confirmed first
        public static let map = "a11y.desk.map"                        // AppAction.openMap: confirmed first
    }

    // MARK: Router prompts (Router.pendingClarification / pendingConfirmation), any screen
    public enum Router {
        /// Clarifying question (2 or 3 options). VoiceOver focus moves here when it appears.
        public static let clarify = "a11y.router.clarify"
        /// Option buttons in spoken order: first, second, third.
        public static func clarifyOption(_ ordinal: Int) -> String { "a11y.router.clarify.option\(ordinal)" }
        /// Leave-app confirmation (call or map). VoiceOver focus moves here when it appears.
        public static let confirm = "a11y.router.confirm"
        public static let confirmYes = "a11y.router.confirm.yes"
        public static let confirmNo = "a11y.router.confirm.no"
        /// UI-test mode only (`-myadUITest YES`): instead of opening `tel:`/maps, the app shows this
        /// element after a confirmed handoff. Its value is the action ("callDesk" or "openMap").
        public static let handoff = "a11y.router.handoff"
    }

    // MARK: Voice
    public enum Voice {
        public static let panel = "a11y.voice.panel"                   // screen anchor (Destination.voice)
        /// The mic button. On EVERY screen (voice-first order), same identifier everywhere.
        public static let mic = "a11y.voice.mic"
        public static let transcript = "a11y.voice.transcript"
        public static let answer = "a11y.voice.answer"
        public static let stop = "a11y.voice.stop"
        public static let typeInstead = "a11y.voice.typeInstead"
        /// Shown (and announced) when speech is unavailable for the text, e.g. no Creole voice
        /// (ADVoice returned `.unavailable`). The text stays on screen.
        public static let unavailableNotice = "a11y.voice.unavailableNotice"
        /// UI-test only: present iff the app was launched with `-myadVoiceStub YES -myadVoiceScript <name>`.
        /// Its value reports the replay state (docs §9, VoiceScript).
        public static let stub = "a11y.voice.stub"
    }

    /// Every static identifier (dynamic prefixes excluded). Used by tests to catch duplicates/typos.
    public static let allStatic: [String] = [
        Household.list, Household.addPerson, Household.settings, Household.pin, Household.cards,
        Onboarding.form, Onboarding.question, Onboarding.next, Onboarding.back, Onboarding.skip,
        AddPerson.form, AddPerson.name, AddPerson.stage, AddPerson.origin, AddPerson.language, AddPerson.thinkIn,
        AddPerson.mode, AddPerson.save, AddPerson.cancel, AddPerson.error,
        PersonDetail.list, PersonDetail.name, PersonDetail.stage, PersonDetail.hero, PersonDetail.nextSteps,
        PersonDetail.edit, PersonDetail.delete, PersonDetail.undo,
        Settings.form, Settings.languageES, Settings.languageEN, Settings.languageHT, Settings.thinkIn, Settings.mode, Settings.done,
        Pin.list, Pin.kendall, Pin.downtown, Pin.current,
        Cards.list,
        Card.list, Card.title, Card.readAloud, Card.stopReading, Card.desk, Card.call,
        Desk.panel, Desk.call, Desk.map,
        Router.clarify, Router.confirm, Router.confirmYes, Router.confirmNo, Router.handoff,
        Voice.panel, Voice.mic, Voice.transcript, Voice.answer, Voice.stop, Voice.typeInstead,
        Voice.unavailableNotice, Voice.stub,
    ] + Onboarding.allSteps + (1...3).map(Router.clarifyOption)
}
