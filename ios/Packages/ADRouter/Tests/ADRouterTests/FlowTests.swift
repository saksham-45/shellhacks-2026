import Foundation
import Testing
import ADCore
import ADLocale
@testable import ADRouter

/// No-touch flows: scripted utterances drive matcher + router; nothing is tapped.
@MainActor
@Suite("Voice-only flows")
struct FlowTests {
    /// Answers whatever onboarding question is on screen, in `language`.
    func speakOnboarding(_ router: Router, language: String, pin: String, people: String,
                         origin: [String], goal: [String]) async -> [ActionOutcome] {
        var outcomes: [ActionOutcome] = []
        var originIndex = 0, goalIndex = 0
        for _ in 0..<12 {
            guard router.household == nil, case .onboarding(let step)? = router.current else { break }
            let text: String
            switch step {
            case .pin: text = pin
            case .people: text = people
            case .originAndLanguage: text = origin[min(originIndex, origin.count - 1)]; originIndex += 1
            case .goal: text = goal[min(goalIndex, goal.count - 1)]; goalIndex += 1
            }
            outcomes.append(await router.hear(text, language: language))
        }
        return outcomes
    }

    @Test(arguments: [
        ("en", "the first one", "Example Student 20, Example Parent 58", ["I am from India and I think in Hindi", "from Cuba, I think in Spanish"], ["I want to study", "reunite with family"]),
        ("es", "la primera", "Ejemplo Estudiante 20, Ejemplo Madre 58", ["Soy de India y pienso en hindi", "de Cuba, pienso en español"], ["estudiar", "reunirme con mi familia"]),
        ("ht", "premye a", "Egzanp Elèv 20, Egzanp Manman 58", ["mwen soti Ayiti", "Ayiti"], ["etidye", "rejwenn fanmi"]),
    ])
    func onboardingByVoice(language: String, pin: String, people: String, origin: [String], goal: [String]) async throws {
        let fx = RecordingEffects()
        let router = Fixture.router(household: nil, effects: fx, surface: SurfaceLanguage(rawValue: language)!)
        let outcomes = await speakOnboarding(router, language: language, pin: pin, people: people, origin: origin, goal: goal)
        let refused = outcomes.filter { if case .refused = $0 { true } else { false } }
        #expect(refused.isEmpty, "\(language): \(refused)")
        let household = try #require(router.household, "\(language): onboarding did not finish")
        #expect(router.path.isEmpty && router.current == .household)
        #expect(router.pinID == Fixture.kendall)
        #expect(household.pin?.address == "11200 SW 137th Ave, Miami, FL 33186")
        #expect(household.people.count == 2)
        #expect(household.people.map(\.age) == [20, 58])
        #expect(household.people.first?.goal == .study)
        if language != "ht" { #expect(household.people.first?.origin?.countryCode == "IN") }
        #expect(fx.households.count == 1)
    }

    @Test func heroCardAndStepsByVoice() async {
        let fx = RecordingEffects()
        let (h, student, _, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        await router.hear("Example Student", language: "en")                   // a choice on the household screen
        #expect(router.current == .person(student))
        #expect(router.nextSteps.map(\.id) == ["transit", "license-checklist", "tolls"])
        await router.hear("next step", language: "en")
        #expect(router.current == .card("transit", person: student))
        await router.hear("siguiente paso", language: "es")
        #expect(router.current == .card("license-checklist", person: student))
        await router.hear("etap anvan", language: "ht")
        #expect(router.current == .card("transit", person: student))
        #expect(router.path == [.person(student), .card("transit", person: student)])
        await router.hear("read this", language: "en")
        #expect(fx.spoken.last == .card("transit", person: student))
        await router.hear("atrás", language: "es")
        await router.hear("¿y el peaje?", language: "es")                      // card utterance
        #expect(router.current == .card("tolls", person: student))
        await router.hear("repite", language: "es")
        #expect(fx.spoken == [.card("transit", person: student), .card("transit", person: student)])  // repeat re-reads the last read
        #expect(fx.outcomes.last?.1 == .performed(Confirmation(key: RouterText.reading)))
    }

    @Test(arguments: [("en", "la segunda"), ("en", "dezyèm lan"), ("en", "the second one")])
    func ambiguousCardAsksThenAcceptsAnOrdinal(askIn: String, answer: String) async throws {
        let fx = RecordingEffects()
        let (h, student, _, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(student)), from: .touch)
        let outcome = await router.hear("the school bus shelter on the school bus route", language: askIn)
        guard case .clarifying(let c) = outcome else { Issue.record("expected a question, got \(outcome)"); return }
        #expect(c.options.map(\.id.rawValue) == ["card.bed-tonight", "card.trash-week", "card.transit"])  // longest phrase first
        #expect(router.context.choiceIDs.count == 3)
        #expect(router.current == .person(student))                            // no guess
        let language = answer == "la segunda" ? "es" : answer == "dezyèm lan" ? "ht" : "en"
        await router.hear(answer, language: language)
        #expect(router.current == .card("trash-week", person: student))
        #expect(router.pendingClarification == nil)
    }

    @Test(arguments: [("en", "call them", "yes"), ("es", "llámalos", "sí"), ("ht", "rele biwo a", "wi")])
    func deskHandoffNeedsASpokenYes(language: String, ask: String, yes: String) async {
        let fx = RecordingEffects()
        let (h, student, _, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(student)), from: .touch)
        router.perform(.navigate(.card("license-checklist", person: student)), from: .touch)
        let asked = await router.hear(ask, language: language)
        #expect(asked == .needsConfirmation(.callDesk(Fixture.deskDSO), prompt: RouterText.askCallDesk))
        #expect(fx.exits.isEmpty)
        await router.hear("repeat", language: "en")                            // re-asks, still waiting
        #expect(fx.outcomes.last?.1 == asked)
        await router.hear(yes, language: language)
        #expect(fx.exits == [.call(Fixture.deskDSO)])
    }

    @Test func deskHandoffNoStaysInTheApp() async {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        router.perform(.navigate(.desk(Fixture.desk311)), from: .touch)
        await router.hear("open the map", language: "en")
        await router.hear("non", language: "ht")
        #expect(fx.exits.isEmpty)
        #expect(router.current == .desk(Fixture.desk311))
    }

    @Test func languageSwitchByVoice() async {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx, surface: .en)
        await router.hear("switch to spanish", language: "en")
        #expect(router.surface == .es && router.replyLanguage == "es")
        await router.hear("cambia a criollo", language: "es")
        #expect(router.surface == .ht && router.replyLanguage == "ht")
        await router.hear("pase an angle", language: "ht")
        #expect(router.surface == .en)
        #expect(fx.languageChanges.map(\.0) == [.es, .ht, .en])
    }

    @Test func uiFollowsTheSpokenLanguageAndStaysWhenItMatches() async {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx, surface: .en)
        await router.hear("siguiente paso", language: "es")
        #expect(router.surface == .es && router.replyLanguage == "es")
        await router.hear("repite", language: "es")
        #expect(router.surface == .es)
        #expect(fx.languageChanges.map(\.0) == [.es])
        await router.hear("next step", language: "en")
        #expect(router.surface == .en && router.replyLanguage == "en")
        await router.hear("read this", language: "en")
        #expect(router.surface == .en)
        #expect(fx.languageChanges.map(\.0) == [.es, .en])
        await router.hear("next", language: "hi")
        #expect(router.surface == .en)
        await router.hear("Где этот адрес", language: "en")
        #expect(router.surface == .ru)
    }

    @Test func languageScreenOrdinal() async {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx, surface: .en)
        router.perform(.navigate(.language), from: .touch)
        await router.hear("the third one", language: "en")
        #expect(router.surface == SurfaceLanguage.allCases[2])
    }

    @Test func unknownSpeechOfflineOpensTheOfficesCard() async {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        let outcome = await router.hear("zzz qqq", language: "en")
        #expect(outcome == .performed(Confirmation(key: RouterText.offline, destination: .card("offices", person: nil), card: "offices")))
    }

    struct Remote: IntentResolving {
        let r: IntentResolution
        func resolve(_ u: Utterance) async throws -> IntentResolution { r }
    }

    @Test func remoteClarificationWithThreeOptions() async {
        let fx = RecordingEffects()
        let (h, student, _, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(student)), from: .touch)
        let c = try! Clarification(question: RouterText.clarifyWhichCard, options: ["transit", "tolls", "license-checklist"].map {
            ClarifyOption(id: ClarifyOptionID(rawValue: "card.\($0)"), label: Card.defaultTitleKey(for: CardID(rawValue: $0)),
                          action: .navigate(.card(CardID(rawValue: $0), person: student)))
        })
        let remote = Remote(r: IntentResolution(confidence: 0.55, clarification: c, replyLanguage: "ht"))
        let outcome = await router.hear("mwen bezwen ale travay", language: "ht", remote: remote)
        #expect(outcome == .clarifying(c))
        await router.hear("peyaj", language: "ht")                             // answering by the label, no ordinal
        #expect(router.current == .card("tolls", person: student))
    }
}
