import Foundation
import Testing
import ADCore
import ADLocale
import ADRouter
@testable import MyAmericanDream

// App logic tests: run in Xcode (MyAmericanDreamTests, hosted by the app) and on Linux by
// tools/check_app_logic.sh (which builds ios/App/Sources/Logic as a package named MyAmericanDream).

enum Fixtures {
    static var uiTestBundle: Bundle {
        let dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("UITestFixtures")
        return Bundle(path: dir.path)!
    }
    static let generatedBundle: URL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Generated/cards.json")

    @MainActor
    static func model(_ args: [String]) -> (AppModel, StubSpeechOutput) {
        let options = LaunchOptions.parse(args)
        let speech = StubSpeechOutput()
        let model = AppModel(options: options, speech: speech,
                             lexicon: AppLexicon.load(uiTest: true, bundle: uiTestBundle),
                             content: CardBundle.load(from: generatedBundle))
        return (model, speech)
    }
}

@Suite("Launch options")
struct LaunchOptionTests {
    @Test func accessFlags() {
        let o = LaunchOptions.parse(["app", "-myadUITest", "YES", "-myadSeed", "none", "-myadSurfaceLanguage", "ht",
                                     "-myadVoiceStub", "YES", "-myadVoiceScript", "desk_handoff_es"])
        #expect(o.uiTest && o.voiceStub && o.seed == .none && o.surface == .ht && o.voiceScript == "desk_handoff_es")
    }

    @Test func bareFlagsAndDefaults() {
        let o = LaunchOptions.parse(["app", "-myadUITest", "-myadVoiceStub"])
        #expect(o.uiTest && o.voiceStub && o.seed == .demoHousehold && o.surface == nil)
        #expect(LaunchOptions.parse(["app"]).seed == .none)
        #expect(LaunchOptions.parse(["app", "-uiTestScreen", "card"]).seed == .demoHousehold)
    }

    @Test func appleLanguagesAndPreferredLanguages() {
        #expect(LaunchOptions.parse(["app", "-AppleLanguages", "(ht)"]).surface == .ht)
        #expect(LaunchOptions.parse(["app", "-AppleLanguages", "(de, es-US)"]).surface == .es)
        #expect(LaunchOptions.parse(["app", "-AppleLanguages", "(fr, es-US)"]).surface == .fr)
        #expect(LaunchOptions.parse(["app"], preferredLanguages: ["de-DE", "en-US"]).surface == .en)
        #expect(LaunchOptions.parse(["app", "-myadSurfaceLanguage", "es", "-AppleLanguages", "(ht)"]).surface == .es)
    }
}

@MainActor
@Suite("App model")
struct AppModelTests {
    @Test func demoSeedIsTwoPeopleOnKendallWithRegionsFixtures() {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        let h = m.router.household
        #expect(h?.people.map(\.displayName) == ["Demo Student", "Demo Parent"])
        #expect(m.router.pins.map(\.id) == [DemoSeed.kendall, DemoSeed.downtown])
        #expect(h?.pin?.address == "11200 SW 137th Ave, Miami, FL 33186")
        #expect(m.content.isDemo)  // the compiled bundle has no cards yet
        #expect(m.presentIdentifiers.contains(A11yID.Household.list))
        #expect(m.presentIdentifiers.contains(A11yID.Voice.mic))
    }

    @Test func freshInstallOpensOnboarding() {
        let (m, _) = Fixtures.model(["-myadUITest", "YES", "-myadSeed", "none"])
        #expect(m.router.current == .onboarding(.pin))
        #expect(m.presentIdentifiers.isSuperset(of: [A11yID.Onboarding.form, A11yID.Onboarding.step(.pin)]))
    }

    @Test func officesCardShowsDemoFactsAndHandsOffTheRest() throws {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        let card = try #require(m.router.catalog.first { $0.id == DemoSeed.officesCard })
        let lines = card.factLines(using: PinFactStore.demoAtKendall, asOf: Date())
        #expect(lines.count == 4)
        var shown = 0, desk = 0, na = 0
        for line in lines {
            switch line {
            case .shown(_, let status): shown += 1; #expect(status == .demo)
            case .handedToDesk, .sourceUnavailable: desk += 1
            case .notApplicable: na += 1
            }
        }
        #expect(shown == 2 && desk == 1 && na == 1)
    }

    @Test func pinSwitchChangesTheFacts() throws {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        let trash = try #require(m.router.catalog.first { $0.id == "trash-week" })
        let kendallShown = m.factRows(trash).filter { $0.value != nil }.count
        m.router.perform(.setPin(DemoSeed.downtown), from: .touch)
        #expect(m.router.household?.pin?.address == "111 NW 1st St, Miami, FL 33128")
        let downtownShown = m.factRows(trash).filter { $0.value != nil }.count
        #expect(kendallShown == 3 && downtownShown == 1)
    }

    @Test func confirmedCallIsRecordedNotOpenedInUITestMode() {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        m.router.perform(.navigate(.card(DemoSeed.officesCard, person: nil)), from: .touch)
        m.router.perform(.callDesk(DemoSeed.desk311), from: .touch)
        #expect(m.presentIdentifiers.contains(A11yID.Router.confirm))
        #expect(m.handoff == nil)
        m.router.perform(.confirm(true), from: .touch)
        #expect(m.handoff == "callDesk")
        #expect(m.presentIdentifiers.contains(A11yID.Router.handoff))
    }

    @Test func liveCallUsesOnlyALedgerPhoneFact() {
        var opened: [URL] = []
        let (m, _) = Fixtures.model(["-myadVoiceStub", "YES", "-myadSeed", "demoHousehold"])
        m.platform.open = { opened.append($0) }
        // offices has no phone fact: the app says so instead of guessing.
        m.router.perform(.navigate(.card(DemoSeed.officesCard, person: nil)), from: .touch)
        m.router.perform(.callDesk(DemoSeed.desk311), from: .touch)
        m.router.perform(.confirm(true), from: .touch)
        #expect(opened.first?.scheme == "tel")  // desk 311 also owns school-zone, whose phone is a ledger fact
        #expect(m.notice == nil)
    }

    @Test func creoleIsNeverReadWithAnotherVoice() {
        let (m, speech) = Fixtures.model(["-myadUITest", "YES", "-myadSurfaceLanguage", "ht"])
        m.router.perform(.navigate(.card(DemoSeed.officesCard, person: nil)), from: .touch)
        m.router.perform(.readAloud(.card(DemoSeed.officesCard)), from: .touch)
        #expect(m.notice == .creoleUnavailable)
        #expect(!m.isReading)
        #expect(speech.spoken.allSatisfy { !$0.language.hasPrefix("ht") })
        #expect(m.presentIdentifiers.contains(A11yID.Voice.unavailableNotice))
        #expect(!m.presentIdentifiers.contains(A11yID.Card.stopReading))
        // Spanish surface: read, stop button appears, stop ends it.
        m.router.perform(.setSurfaceLanguage(.es), from: .touch)
        m.router.perform(.readAloud(.card(DemoSeed.officesCard)), from: .touch)
        #expect(m.isReading && m.notice == nil)
        #expect(m.presentIdentifiers.contains(A11yID.Card.stopReading))
        m.router.perform(.stopSpeaking, from: .touch)
        #expect(!m.isReading)
        #expect(m.languages.surface == .es)
    }

    @Test(arguments: ["hero_card_en", "desk_handoff_es", "switch_language_ht", "onboarding_es"])
    func bundledVoiceScriptsPass(name: String) async {
        let seed = name == "onboarding_es" ? "none" : "demoHousehold"
        let surface = name.hasSuffix("_en") ? "en" : "es"
        let (m, _) = Fixtures.model(["-myadUITest", "YES", "-myadVoiceStub", "YES", "-myadVoiceScript", name,
                                     "-myadSeed", seed, "-myadSurfaceLanguage", surface])
        #expect(m.voiceScriptStatus == "loading")
        await m.runVoiceScript(bundle: Fixtures.uiTestBundle, pause: .zero, timeout: .milliseconds(300))
        #expect(m.voiceScriptStatus == "passed", "\(name): \(m.voiceScriptStatus ?? "nil") at \(String(describing: m.router.current))")
    }

    @Test func uiLanguageFollowsTheMicAndStaysWhenItMatches() async {
        let (m, _) = Fixtures.model(["-myadUITest", "YES", "-myadSeed", "demoHousehold", "-myadSurfaceLanguage", "en"])
        #expect(m.router.surface == .en)
        await m.hear("siguiente paso", language: "es")
        #expect(m.router.surface == .es)
        #expect(m.languages.surface == .es)
        await m.hear("repite", language: "es")
        #expect(m.router.surface == .es)
        await m.hear("next step", language: "en")
        #expect(m.router.surface == .en)
        #expect(m.resolveSpokenLanguage("هذا العنوان", tagged: "en") == .ar)
        #expect(m.resolveSpokenLanguage("next step", tagged: "en") == .en)
        #expect(m.resolveSpokenLanguage("ok", tagged: "hi") == .en)
    }

    @Test func missingScriptReportsScriptNotFound() async {
        let (m, _) = Fixtures.model(["-myadVoiceStub", "YES", "-myadVoiceScript", "nope"])
        await m.runVoiceScript(bundle: Fixtures.uiTestBundle, pause: .zero)
        #expect(m.voiceScriptStatus == "scriptNotFound")
    }

    @Test func everyScreenshotRouteLands() {
        for screen in ScreenshotRoute.all {
            let seed = screen == "onboarding" ? "none" : "demoHousehold"
            let (m, _) = Fixtures.model(["-myadUITest", "YES", "-myadSeed", seed, "-uiTestScreen", screen])
            ScreenshotRoute.apply(screen, to: m)
            let ids = m.presentIdentifiers
            let expected: String = switch screen {
            case "household": A11yID.Household.list
            case "onboarding": A11yID.Onboarding.form
            case "addPerson": A11yID.AddPerson.form
            case "person": A11yID.PersonDetail.list
            case "stage", "cards": A11yID.Cards.list
            case "card": A11yID.Card.list
            case "desk": A11yID.Desk.panel
            case "pin": A11yID.Pin.list
            case "settings": A11yID.Settings.form
            case "voice": A11yID.Voice.panel
            case "clarify": A11yID.Router.clarify
            case "confirm": A11yID.Router.confirm
            default: A11yID.Voice.unavailableNotice
            }
            #expect(ids.contains(expected), "\(screen)")
        }
    }

    @Test func allStaticIdsAreUnique() {
        #expect(Set(A11yID.allStatic).count == A11yID.allStatic.count)
    }
}

@MainActor
@Suite("Household groups")
struct HouseholdGroupTests {
    @Test func groupsCoverEachBoardCardOnce() {
        for board in HouseholdBoard.allCases {
            let ids = board.groups.flatMap(\.cardIDs)
            #expect(ids.count == Set(ids).count, "\(board.rawValue) has a repeated card")
            #expect(ids == board.orderedIDs)
        }
    }

    @Test func everyHouseholdCardExceptThisWeekSitsOnABoard() {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        let onBoards = Set(HouseholdBoard.allCases.flatMap(\.orderedIDs))
        let catalog = Set(m.router.catalog.filter { $0.subject == .household }.map(\.id))
        #expect(catalog.subtracting(onBoards) == ["trash-week"])
    }

    @Test func homeNextStepIsTheParentHouseLeakTo311() throws {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        let step = try #require(m.householdNextStep())
        #expect(step.personName == "Demo Parent")
        #expect(step.card.id == "house-damage")
        #expect(step.card.desk == DemoSeed.desk311)
        #expect(step.showsPhoto)
        #expect(m.app(step.lineKey).localizedCaseInsensitiveContains("leak") || m.app(step.lineKey).contains("311"))
    }

    @Test func houseCardTrustNamesASourceAndDesk() throws {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        let card = try #require(m.router.catalog.first { $0.id == "house-damage" })
        let trust = m.trust(for: card)
        #expect(trust.desk == DemoSeed.desk311)
        #expect(trust.publisher != nil)
        #expect(trust.retrieved != nil)
        #expect(trust.evidenceKey == "app.trust.verified" || trust.evidenceKey == "app.trust.demo")
    }

    @Test func callHandoffNames311TheHouseAndThePin() throws {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        m.router.perform(.navigate(.card("house-damage", person: nil)), from: .touch)
        m.router.perform(.callDesk(DemoSeed.desk311), from: .touch)
        let summary = try #require(m.router.pendingConfirmation.flatMap(m.handoffSummary(for:)))
        #expect(summary.headline.contains("311"))
        #expect(summary.headline.lowercased().contains("house") || summary.headline.contains("casa") || summary.headline.contains("kay"))
        #expect(summary.headline.contains("11200"))
        #expect(summary.phone?.contains("311") == true)
        #expect(summary.languages != nil)
    }
}

#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Speech

@Suite("Scene guide")
struct SceneGuideTests {
    @Test func vehiclePackRefusesFaultAndMoney() {
        #expect(ScenePack.vehicle.cannotProve.contains("fault"))
        #expect(ScenePack.home.cannotProve.contains("deposit"))
    }

    @Test func parseAcceptsPackJSON() throws {
        let data = #"{"pack":"vehicle","visible":"scuffed bumper","where":"rear right"}"#.data(using: .utf8)!
        let r = try #require(SceneGuide.parse(data))
        #expect(r.pack == .vehicle)
        #expect(r.visible.contains("bumper"))
    }
}

@MainActor
@Suite("Scene walkthrough phones")
struct ScenePhoneTests {
    @Test func bumperTapDialsDeskPhonesNotTheFirstFactOnTheCard() {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        m.router.perform(.navigate(.card("bumper-tap", person: nil)), from: .touch)
        #expect(m.phoneDigits(for: "us.911") == "911")
        #expect(m.phoneDigits(for: "us-fl-miamidade.mdpd") == "3053836800")
        #expect(m.phoneDigits(for: "us-fl-miamidade.311") == "311")
        #expect(m.phoneDigits(for: "us-fl.flhsmv") == "8506172000")
        #expect(m.phonesToShow(for: "us-fl-miamidade.mdpd") == "(305) 383-6800")
        #expect(m.phonesToShow(for: "us-fl-miamidade.311")?.contains("305") == true)
    }

    @Test func bumperTap311Dials311NotFLHSMV() {
        var opened: [URL] = []
        let (m, _) = Fixtures.model(["-myadVoiceStub", "YES", "-myadSeed", "demoHousehold"])
        m.platform.open = { opened.append($0) }
        m.router.perform(.navigate(.card("bumper-tap", person: nil)), from: .touch)
        m.router.perform(.callDesk("us-fl-miamidade.311"), from: .touch)
        m.router.perform(.confirm(true), from: .touch)
        #expect(opened.first?.absoluteString == "tel:311")
    }

    @Test func bumperTapUtteranceOpensTheCard() async {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        await m.hear("bumper tap", language: "en")
        guard case .card(let id, _)? = m.router.current else {
            Issue.record("expected bumper-tap card")
            return
        }
        #expect(id == "bumper-tap")
    }

    @Test func houseDamageUtteranceOpensTheCard() async {
        let (m, _) = Fixtures.model(["-myadUITest", "YES"])
        await m.hear("leak in the house", language: "en")
        guard case .card(let id, _)? = m.router.current else {
            Issue.record("expected house-damage card")
            return
        }
        #expect(id == "house-damage")
    }
}

@Suite("Gemini spoken intent")
struct GeminiIntentTests {
    @Test func parseAcceptsACatalogCardId() throws {
        let body = """
        {"candidates":[{"content":{"parts":[{"text":"taxi"}]}}]}
        """.data(using: .utf8)!
        #expect(GeminiCardParse.choice(from: body, allowed: ["taxi", "street-week"]) == "taxi")
    }

    @Test func parseRejectsUnknownAndNone() throws {
        let none = """
        {"candidates":[{"content":{"parts":[{"text":"none"}]}}]}
        """.data(using: .utf8)!
        let other = """
        {"candidates":[{"content":{"parts":[{"text":"visa-strategy"}]}}]}
        """.data(using: .utf8)!
        #expect(GeminiCardParse.choice(from: none, allowed: ["taxi"]) == nil)
        #expect(GeminiCardParse.choice(from: other, allowed: ["taxi"]) == nil)
    }

    @Test func promptListsOnlyCatalogIds() {
        let text = GeminiCardParse.prompt(
            utterance: "taxi from the airport",
            cards: [GeminiCardHint(id: "taxi", title: "The official taxi stand at MIA (demo)")]
        )
        #expect(text.contains("taxi"))
        #expect(text.contains("Never invent a card"))
        #expect(!text.contains("chat"))
    }
}


/// Speech/mic permission handlers are delivered on a root queue. A `@MainActor`
/// waiter traps (`_swift_task_checkIsolatedSwift`) the moment the person taps Speak.
@MainActor
@Suite("Live speech")
struct LiveSpeechTests {
    @Test func permissionCallbackMayArriveOffTheMainActor() async {
        let granted = await LiveSpeechAuth.wait { finish in
            DispatchQueue.global(qos: .default).async {
                finish(true)
            }
        }
        #expect(granted)
    }

    @Test func audioTapBlockMayRunOffTheMainActor() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let request = SFSpeechAudioBufferRecognitionRequest()
        let block = LiveSpeechTap.append(request)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            block(buffer, AVAudioTime(hostTime: mach_absolute_time()))
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 2) == .success)
    }
}
#endif

extension PinFactStore {
    static var demoAtKendall: PinFactStore {
        let s = PinFactStore()
        s.select(DemoSeed.pins().first?.pin)
        return s
    }
}
