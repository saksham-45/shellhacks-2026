import Foundation
import Observation
import ADCore
import ADLocale
import ADRouter
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Notices shown on screen and announced (never on a timer; they stay until the next action).
public enum Notice: Hashable, Sendable {
    /// ADVoice has no voice for Creole: the text stays on screen, nothing is read with an es/en voice.
    case creoleUnavailable
    /// No voice for another language the text is in.
    case voiceUnavailable(language: String)
    /// Live speech input is not available yet (ADVoice's recognizer); typing works.
    case speechInputUnavailable
    /// A confirmed call, but no ledger phone fact for this desk is on hand. The app never guesses a number.
    case noPhoneNumber(DeskID)
    /// A confirmed map, but no ledger place fact is on hand.
    case noPlace

    /// Speech notices carry a11y.voice.unavailableNotice; the others are plain notices.
    public var isSpeechNotice: Bool {
        switch self {
        case .creoleUnavailable, .voiceUnavailable, .speechInputUnavailable: true
        case .noPhoneNumber, .noPlace: false
        }
    }

    public var key: String {
        switch self {
        case .creoleUnavailable: "app.notice.creole_unavailable"
        case .voiceUnavailable: "app.notice.voice_unavailable"
        case .speechInputUnavailable: "app.notice.speech_input_unavailable"
        case .noPhoneNumber: "app.notice.no_phone"
        case .noPlace: "app.notice.no_place"
        }
    }
}

/// What the platform layer provides (UIKit/SwiftUI side), so this model stays testable.
public struct PlatformHooks {
    /// VoiceOver announcement in `language`; `screenChanged` posts a screen-changed notification first.
    public var announce: @MainActor (_ text: String, _ language: String, _ screenChanged: Bool) -> Void
    /// Opens a tel:/maps URL (only after the router's confirmation).
    public var open: @MainActor (URL) -> Void
    /// Whether live speech input can start (mic + recognizer), without prompting.
    public var speechInputAvailable: @MainActor () -> Bool

    public init(announce: @escaping @MainActor (String, String, Bool) -> Void = { _, _, _ in },
                open: @escaping @MainActor (URL) -> Void = { _ in },
                speechInputAvailable: @escaping @MainActor () -> Bool = { false }) {
        self.announce = announce
        self.open = open
        self.speechInputAvailable = speechInputAvailable
    }
}

/// App state around the shared router. Every control in the UI calls `router.perform` (or `hear`,
/// which ends in the router); this model only carries what the router's effects produce.
@MainActor
@Observable
public final class AppModel: RouterEffects {
    public let options: LaunchOptions
    public let router: Router
    public let languages: LanguageSettings
    public let content: CardBundle
    @ObservationIgnored let facts: PinFactStore
    @ObservationIgnored public let speech: any SpeechOutput
    @ObservationIgnored public var platform: PlatformHooks

    public private(set) var readingCard: CardID?
    public private(set) var isReading = false
    public private(set) var notice: Notice?
    public private(set) var transcript = ""
    public private(set) var answer = ""
    /// UI-test mode: the confirmed leave-app action ("callDesk" / "openMap"), shown as a11y.router.handoff.
    public private(set) var handoff: String?
    public private(set) var listening = false
    /// Present iff a voice script was requested (a11y.voice.stub value).
    public var voiceScriptStatus: String?
    #if canImport(Speech)
    @ObservationIgnored private var mic = LiveSpeechSession()
    #endif

    public init(options: LaunchOptions, speech: any SpeechOutput, platform: PlatformHooks = PlatformHooks(),
                lexicon: (any CommandLexiconProviding)? = nil, content: CardBundle = .load(), factStore: PinFactStore = PinFactStore()) {
        self.options = options
        self.speech = speech
        self.platform = platform
        self.content = content
        self.facts = factStore
        let pins = DemoSeed.pins()
        let household = (options.seed == .demoHousehold || (!options.uiTest && options.seed == .none))
            ? DemoSeed.household(pins: pins) : nil
        factStore.select(household?.pin)
        let surface = options.surface ?? .en
        languages = LanguageSettings(surface: surface)
        let matcher = LexiconCommandMatcher(lexicon: lexicon ?? AppLexicon.load(uiTest: options.uiTest || options.voiceScript != nil),
                                            cards: content.utterances, labels: AppLabels())
        router = Router(household: household, catalog: content.cards, surface: surface, pins: pins, facts: factStore,
                        lensResolver: NoOriginLenses(), matcher: matcher,
                        config: RouterConfig(officesCard: DemoSeed.officesCard, fallbackDesk: DemoSeed.desk311))
        router.effects = self
        if voiceScriptRequested { voiceScriptStatus = "loading" }
    }

    public var voiceScriptRequested: Bool { options.usesVoiceStub && options.voiceScript != nil }
    public var surface: String { router.surface.rawValue }
    public func text(_ key: StringKey) -> String { AppStrings.text(key, language: surface) }
    public func app(_ key: String) -> String { AppStrings.app(key, surface) }

    // MARK: Input

    /// Spoken or typed text. When `language` is omitted, the UI language is read off the
    /// sentence (script / recognizer). A tagged language from STT or a voice script is used
    /// as-is when the text has no stronger script signal.
    public func hear(_ text: String, language: String? = nil, from source: ActionSource = .voice) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript = trimmed
        let spoken = resolveSpokenLanguage(trimmed, tagged: language)
        let remote: (any IntentResolving)?
        if options.uiTest {
            remote = nil
        } else if let key = SecretEnv.gemini {
            let hints = router.catalog.map {
                GeminiCardHint(id: $0.id, title: AppStrings.text($0.titleKey, language: spoken.rawValue))
            }
            remote = GeminiCardIntent(apiKey: key, cards: hints)
        } else {
            remote = nil
        }
        await router.hear(trimmed, language: spoken.rawValue, remote: remote, from: source)
    }

    /// The mic button and Magic Tap: open the voice panel and start listening, or stop.
    public func toggleListening() {
        if listening {
            stopMic()
            listening = false
            return
        }
        if router.current != .voice { router.perform(.navigate(.voice), from: .touch) }
        if options.usesVoiceStub {
            listening = true
            return
        }
        if platform.speechInputAvailable() {
            listening = true
            startMic()
        } else {
            show(.speechInputUnavailable)
            noticeRaisedDuringAction = false
        }
    }

    /// Language the UI should follow for this sentence.
    func resolveSpokenLanguage(_ text: String, tagged: String?) -> SurfaceLanguage {
        if let script = SpokenSurface.fromScript(text) { return script }
        if let guessed = naturalLanguageSurface(text) { return guessed }
        if let tagged, let surface = SpokenSurface.fromTag(tagged) { return surface }
        return router.surface
    }

    private func naturalLanguageSurface(_ text: String) -> SurfaceLanguage? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 8)[dominant] ?? 0
        guard confidence >= 0.5, text.count >= 4 else { return nil }
        return Self.surface(fromNL: dominant.rawValue)
        #else
        return nil
        #endif
    }

    static func surface(fromNL raw: String) -> SurfaceLanguage? {
        switch raw.lowercased() {
        case "es", "spanish": .es
        case "en", "english": .en
        case "ht", "hat", "haitian", "haitiancreole": .ht
        case "pt", "portuguese": .pt
        case "fr", "french": .fr
        case "ar", "arabic": .ar
        case "zh", "zh-hans", "zh-hant", "chinese", "simplifiedchinese", "traditionalchinese": .zh
        case "ru", "russian": .ru
        case "tl", "fil", "tagalog": .tl
        case "vi", "vietnamese": .vi
        default: SurfaceLanguage(languageTag: raw)
        }
    }

    private func startMic() {
        #if canImport(Speech)
        stopSpeaking()
        mic.start(locale: micLocale, onPartial: { [weak self] text in
            self?.transcript = text
        }, onFinal: { [weak self] text in
            guard let self else { return }
            self.listening = false
            Task { await self.hear(text, language: nil, from: .voice) }
        }, onFail: { [weak self] in
            guard let self else { return }
            self.listening = false
            self.show(.speechInputUnavailable)
            self.noticeRaisedDuringAction = false
        })
        #endif
    }

    private func stopMic() {
        #if canImport(Speech)
        mic.stop()
        #endif
    }

    private var micLocale: Locale {
        switch router.surface {
        case .ht: Locale(identifier: "es-US")
        default: router.surface.formattingLocale
        }
    }

    public func dismissNotice() { notice = nil; noticeRaisedDuringAction = false }

    /// Same-screen guide: speak the steps that are already on screen. Never a chat reply.
    public func speakPlain(_ text: String, language: String) {
        say(text, language: language, reading: true)
    }

    /// Home “Your next step”: one person, one card, one line. Prefers the house leak (311).
    public func householdNextStep() -> HouseholdNextStep? {
        guard let people = router.household?.people, !people.isEmpty else { return nil }
        let person = people.last(where: { $0.mode == .resident && $0.goal != .study })
            ?? people.last(where: { $0.mode == .resident })
            ?? people[people.count - 1]
        let preferred: [CardID] = ["house-damage", "bumper-tap", "trash-week"]
        guard let card = preferred.compactMap({ id in router.catalog.first { $0.id == id } }).first else { return nil }
        let lineKey: String
        let photo: Bool
        switch card.id.rawValue {
        case "house-damage": lineKey = "app.next.line.house"; photo = true
        case "bumper-tap": lineKey = "app.next.line.bumper"; photo = true
        default: lineKey = "app.next.line.trash"; photo = false
        }
        return HouseholdNextStep(personName: person.displayName, card: card, lineKey: lineKey, showsPhoto: photo)
    }

    public func spokenNextStep(_ step: HouseholdNextStep) -> String {
        let who = String(format: app("app.next.who"), step.personName)
        return "\(who) \(app(step.lineKey))"
    }

    /// Why this answer: first shown fact’s source, date, jurisdiction, demo/verified, desk.
    public func trust(for card: Card) -> CardTrust {
        let lines = card.factLines(using: facts, asOf: Date())
        var publisher: String?
        var retrieved: Date?
        var demo = false
        var verified = false
        for case let .shown(fact, status) in lines {
            if status == .demo { demo = true }
            if status == .verified || status == .stale { verified = true }
            if publisher == nil { publisher = fact.source?.publisher }
            if let at = fact.retrievedAt {
                retrieved = [retrieved, Optional(at)].compactMap { $0 }.min()
            }
        }
        var jurisdictionID = card.regionPack.rawValue
        if let first = card.facts.first, let row = facts.result(for: first) {
            jurisdictionID = row.jurisdiction.rawValue
            if publisher == nil { publisher = row.publisher }
        }
        let evidence: String
        if demo && !verified { evidence = "app.trust.demo" }
        else if verified { evidence = "app.trust.verified" }
        else { evidence = "app.trust.unsourced" }
        return CardTrust(
            publisher: publisher,
            retrieved: retrieved.map { FactText.date($0, surface) },
            jurisdiction: jurisdictionName(jurisdictionID),
            evidenceKey: evidence,
            desk: card.desk
        )
    }

    func jurisdictionName(_ id: String) -> String {
        let key = "app.jurisdiction.\(id)"
        let s = app(key)
        return s == key ? id : s
    }

    func deskTitle(_ desk: DeskID) -> String {
        let key = "app.desk.name.\(desk.rawValue)"
        let s = app(key)
        return s == key ? desk.rawValue : s
    }

    /// Leave-app sheet: who you are calling, about what, where, the number, and languages.
    public func handoffSummary(for action: AppAction) -> HandoffSummary? {
        let desk: DeskID?
        let isMap: Bool
        switch action {
        case .callDesk(let d): desk = d; isMap = false
        case .openMap(.desk(let d)): desk = d; isMap = true
        case .openMap: desk = nil; isMap = true
        default: return nil
        }
        let cardID: CardID? = {
            if case .card(let id, _)? = router.current { return id }
            if let step = householdNextStep(), desk == step.card.desk { return step.card.id }
            return nil
        }()
        let aboutKey: String
        switch cardID?.rawValue {
        case "house-damage": aboutKey = "app.handoff.about.house"
        case "bumper-tap": aboutKey = "app.handoff.about.crash"
        case "lights-311", "night-walk": aboutKey = "app.handoff.about.light"
        case "taxi", "rideshare": aboutKey = "app.handoff.about.airport"
        default: aboutKey = "app.handoff.about.this"
        }
        let address = router.household?.pin?.address
        let name = desk.map(deskTitle) ?? app("app.handoff.place")
        let about = app(aboutKey)
        let headline: String
        if let address {
            headline = String(format: app(isMap ? "app.handoff.map.at" : "app.handoff.call.at"), name, about, address)
        } else {
            headline = String(format: app(isMap ? "app.handoff.map" : "app.handoff.call"), name, about)
        }
        let phone = desk.flatMap { phonesToShow(for: $0) }
        var languages: String?
        if desk?.rawValue == "us-fl-miamidade.311" {
            if case .fact(let f)? = facts.outcome(for: "us-fl-miamidade.311.hours-languages"),
               case .text(let text, _)? = f.displayValue {
                languages = text
            }
        }
        return HandoffSummary(headline: headline, phone: phone, languages: languages, isMap: isMap)
    }

    // MARK: RouterEffects

    public func speak(_ content: ReadContent, language: String) {
        let lang = SurfaceLanguage(languageTag: language)?.rawValue ?? surface
        let text = spokenText(for: content, language: lang)
        let card: CardID? = if case .card(let id, _) = content { id } else { nil }
        say(text, language: lang, reading: true, card: card)
    }

    public func stopSpeaking() {
        speechToken += 1
        speech.stop()
        isReading = false
        readingCard = nil
    }

    public func leaveApp(_ exit: AppExit) {
        if options.uiTest {
            switch exit {
            case .call: handoff = "callDesk"
            case .map: handoff = "openMap"
            }
            return
        }
        switch exit {
        case .call(let desk):
            guard let digits = phoneDigits(for: desk), let url = URL(string: "tel:\(digits)") else { return show(.noPhoneNumber(desk)) }
            platform.open(url)
        case .map(let target):
            guard let place = place(for: target), let url = mapURL(place) else { return show(.noPlace) }
            platform.open(url)
        }
    }

    public func householdChanged(_ household: Household?) {
        facts.select(household?.pin)
    }

    public func languagesChanged(surface: SurfaceLanguage, thinkIn: SpokenLanguage) {
        languages.surface = surface
        languages.thinkIn = thinkIn.language
    }

    public func didPerform(_ action: AppAction?, outcome: ActionOutcome, source: ActionSource, screenChanged: Bool, language: String) {
        let lang = SurfaceLanguage(languageTag: language)?.rawValue ?? surface
        answer = AppStrings.text(outcome.speech, language: lang)
        // A notice stays until the next action (never a timer); one raised by this action stays.
        if !noticeRaisedDuringAction { notice = nil }
        noticeRaisedDuringAction = false
        if case .needsConfirmation = outcome { handoff = nil }
        switch outcome {
        case .clarifying(let c):
            // Spoken question and numbered options; the overlay moves VoiceOver focus to the question.
            let options = c.options.enumerated().map { "\($0.offset + 1). \(AppStrings.text($0.element.label, language: lang))" }
            say(([answer] + options).joined(separator: " "), language: lang, reading: false)
        case .needsConfirmation:
            if let pending = router.pendingConfirmation, let summary = handoffSummary(for: pending) {
                let spoken = [summary.headline, summary.phone, summary.languages].compactMap { $0 }.joined(separator: " ")
                say(spoken, language: lang, reading: false)
            } else {
                say(answer, language: lang, reading: false)
            }
        case .performed, .refused:
            let spoke = [.readAloud(.screen), .repeatLast].contains(action) || { if case .readAloud? = action { true } else { false } }()
            if !spoke, source == .voice || source == .appIntent { say(answer, language: lang, reading: false) }
        }
        if screenChanged, source != .touch, source != .voiceOver {
            platform.announce([screenTitle(router.current), answer].joined(separator: ". "), surface, true)
        }
    }

    // MARK: Speech

    @ObservationIgnored private var speechToken = 0

    private func say(_ text: String, language: String, reading: Bool, card: CardID? = nil) {
        speechToken += 1
        let token = speechToken
        let result = speech.speak(text, language: language) { [weak self] in
            // Only the utterance still current may clear the reading state.
            guard let self, self.speechToken == token else { return }
            self.isReading = false
            self.readingCard = nil
        }
        switch result {
        case .speaking:
            isReading = reading
            readingCard = reading ? card : nil
        case .unavailable(let lang):
            isReading = false
            readingCard = nil
            show(lang.hasPrefix("ht") ? .creoleUnavailable : .voiceUnavailable(language: lang))
        }
    }

    @ObservationIgnored private var noticeRaisedDuringAction = false

    private func show(_ n: Notice) {
        notice = n
        noticeRaisedDuringAction = true
        platform.announce(app(n.key), surface, false)
    }

    // MARK: Text for speech (same facts and order as the screen)

    public func factRows(_ card: Card, language: String? = nil) -> [FactRowText] {
        card.factLines(using: facts, asOf: Date()).map { FactText.row($0, language: language ?? surface) }
    }

    public func spokenText(for content: ReadContent, language: String) -> String {
        switch content {
        case .card(let id, _):
            guard let card = router.catalog.first(where: { $0.id == id }) else { return "" }
            let rows = factRows(card, language: language).map(\.combined)
            let desk = "\(AppStrings.app("app.card.desk_label", language)): \(card.desk.rawValue)"
            return ([AppStrings.text(card.titleKey, language: language)] + rows + [desk]).joined(separator: ". ")
        case .destination(let d):
            return screenTitle(d, language: language)
        }
    }

    public func screenTitle(_ d: Destination?, language: String? = nil) -> String {
        let lang = language ?? surface
        let key: String = switch d {
        case nil, .household?: "app.screen.household"
        case .person?: "app.screen.person"
        case .addPerson?: "app.screen.add_person"
        case .editPerson?: "app.screen.edit_person"
        case .onboarding?: "app.screen.onboarding"
        case .stage?: "app.screen.stage"
        case .card?: "app.screen.card"
        case .cards?: "app.screen.cards"
        case .desk?: "app.screen.desk"
        case .pin?: "app.screen.pin"
        case .settings?, .language?: "app.screen.settings"
        case .voice?: "app.screen.voice"
        }
        return AppStrings.app(key, lang)
    }

    // MARK: Ledger lookups for leave-app actions (never an invented number or place)

    private func cardsForHandoff(desk: DeskID?) -> [Card] {
        var cards: [Card] = []
        if case .card(let id, _)? = router.current, let c = router.catalog.first(where: { $0.id == id }) { cards.append(c) }
        if let desk { cards += router.catalog.filter { $0.desk == desk && !cards.contains($0) } }
        return cards
    }

    /// Digits this desk would actually dial. Never the first phone on the current card.
    func phoneDigits(for desk: DeskID) -> String? { phones(for: desk).first }

    /// Formatted ledger phones for the same-screen walkthrough (311 · (305) 468-5900).
    func phonesToShow(for desk: DeskID) -> String? {
        let list = phones(for: desk)
        guard !list.isEmpty else { return nil }
        return list.map(FactText.phone).joined(separator: " · ")
    }

    /// Ledger phones for a desk, in dial order. 911 is the emergency line; other desks use
    /// `<desk>.phone` / `<desk>.phone-alt`, then a pin-local alias, then a card that owns the desk.
    func phones(for desk: DeskID) -> [String] {
        if desk.rawValue == "us.911" { return ["911"] }
        var ids: [FactID] = [
            FactID(rawValue: "\(desk.rawValue).phone"),
            FactID(rawValue: "\(desk.rawValue).phone-alt"),
        ]
        switch desk.rawValue {
        case "us-fl-miamidade.mdpd":
            ids.append("us-fl-miamidade.police.nearest.phone")
        case "us-fl.flhsmv":
            ids.append("us-fl.flhsmv.crash.customer-service")
        default:
            break
        }
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ raw: String) {
            let d = raw.filter(\.isNumber)
            guard !d.isEmpty, seen.insert(d).inserted else { return }
            ordered.append(d)
        }
        for id in ids {
            if case .fact(let f)? = facts.outcome(for: id), case .phone(let digits)? = f.displayValue {
                add(digits)
            }
        }
        if ordered.isEmpty {
            for card in router.catalog where card.desk == desk {
                for row in factRows(card) {
                    if let digits = row.phoneDigits { add(digits) }
                }
            }
        }
        return ordered
    }

    func place(for target: MapTarget) -> Place? {
        switch target {
        case .place(let ref):
            if case .fact(let f)? = facts.outcome(for: ref.ledgerFactID), case .place(let p)? = f.displayValue { return p }
            return nil
        case .desk(let desk):
            for card in cardsForHandoff(desk: desk) {
                if let p = factRows(card).lazy.compactMap(\.place).first { return p }
            }
            return nil
        }
    }

    func mapURL(_ p: Place) -> URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(p.coordinate.latitude),\(p.coordinate.longitude)"),
                         URLQueryItem(name: "q", value: p.name)]
        return c?.url
    }
}

public struct HouseholdNextStep: Equatable, Sendable {
    public let personName: String
    public let card: Card
    public let lineKey: String
    public let showsPhoto: Bool
}

public struct CardTrust: Equatable, Sendable {
    public let publisher: String?
    public let retrieved: String?
    public let jurisdiction: String
    public let evidenceKey: String
    public let desk: DeskID
}

public struct HandoffSummary: Equatable, Sendable {
    public let headline: String
    public let phone: String?
    public let languages: String?
    public let isMap: Bool
}

/// Origin lenses are content's data (not landed): none until then.
struct NoOriginLenses: OriginLensResolving {
    func lenses(for origin: Origin) -> Set<OriginLens> { [] }
}

/// The command lexicon. Shipping: myAD Language's lexicon when it lands; until then the English
/// key-name fallback (ADRouter.KeyNameLexicon). UI tests and voice scripts: the test lexicon in
/// UITestFixtures (excluded from Release builds), so es/ht scripts can run.
public enum AppLexicon {
    public static func load(uiTest: Bool, bundle: Bundle = .main) -> any CommandLexiconProviding {
        guard uiTest, let url = bundle.url(forResource: "command_lexicon.uitest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: [String: [String]]].self, from: data) else {
            return KeyNameLexicon()
        }
        return InMemoryCommandLexicon(table)
    }
}
