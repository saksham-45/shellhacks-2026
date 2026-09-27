// XCODE-ONLY. UI test target `MyAmericanDreamUITests`. Voice-first, no-touch flow tests (A11Y-VC-03).
// ARCHITECTURE.md §13.3: XCUITests launch with `-myadVoiceStub YES -myadVoiceScript <name>`; the app's voice
// stub (Lead: AppModel.runVoiceScript, started at launch with no tap) replays the bundled script
// (ios/App/UITestFixtures/voicescript.<name>.json) through the router. After launch these tests never tap,
// type, or swipe: they only wait and assert on anchors and identifiers (docs §9, VoiceScript).
// Line numbers below are the n of the stub's "running n/total"; they mirror the bundled files: change both.
// A missing stub hook or script FAILS, unless the test plan sets MYAD_VOICE_STUB_PENDING=1 (then it skips).

import ADAccessibility
import ADCore
import XCTest

@MainActor
final class VoiceFirstFlowTests: XCTestCase {

    /// Longest a whole script may take (the stub speaks, listens, and pauses between lines).
    private let scriptTimeout: TimeInterval = 180

    // MARK: Flows (script names are the contract with myAD Language)

    /// `onboarding_es` (6 lines): "la primera" (pin) -> people; "Ana 20, Rosa 58" -> origin and language;
    /// "soy de Cuba y hablo español" -> goal; "la segunda" (goal) -> Rosa's origin and language; the same
    /// origin again -> goal; "la primera" -> household.
    private enum OnboardingScript {
        static let total = 6
        static let done = 6        // last answer -> a11y.household.list
    }

    /// Onboarding by voice: exactly the four questions, in order, and never a status question.
    func test_voiceOnly_onboarding() throws {
        guard let run = try replay(script: "onboarding_es", language: .es, seed: A11ySeed.none,
                                   watch: [A11yID.Onboarding.stepPrefix, A11yID.Onboarding.question, A11yID.Household.list])
        else { return }
        XCTAssertEqual(run.total, OnboardingScript.total,
                       "onboarding_es has \(run.total.map(String.init) ?? "?") lines, expected \(OnboardingScript.total): update OnboardingScript")
        let stepPrefix = A11yID.Onboarding.stepPrefix
        // "Exactly one step container exists at a time" (A11yID.Onboarding.step): distinct step ids, because
        // one step may be exposed by several elements (the app sets it on a Form Section, docs §9 finding).
        let crowded = run.timeline.filter { Set($0.ids(withPrefix: stepPrefix)).count > 1 }
        XCTAssertTrue(crowded.isEmpty, "several onboarding steps shown at once: \(crowded.map { $0.ids(withPrefix: stepPrefix) })")

        // The steps as asked: consecutive duplicates collapsed (one step stays up across many snapshots).
        var asked: [String] = []
        for id in run.timeline.flatMap({ $0.ids(withPrefix: stepPrefix) }) where asked.last != id { asked.append(id) }
        let allSteps = A11yID.Onboarding.allSteps
        XCTAssertTrue(asked.allSatisfy { allSteps.contains($0) }, "onboarding showed step ids outside A11yID.Onboarding.allSteps: \(asked)")
        XCTAssertEqual(Array(asked.prefix(allSteps.count)), allSteps,
                       "onboarding asked \(asked); expected the four questions in order first (ADCore OnboardingStep)")
        // ADCore asks questions 3 and 4 once per person (OnboardingDraft); the script names two people
        // ("Ana 20, Rosa 58"), so the second person's pair follows the four questions, and nothing else.
        let secondPerson = [A11yID.Onboarding.step(.originAndLanguage), A11yID.Onboarding.step(.goal)]
        XCTAssertEqual(asked, allSteps + secondPerson,
                       "onboarding asked \(asked); expected \(allSteps + secondPerson) for the two scripted people")
        XCTAssertTrue(run.steps(showing: A11yID.Household.list).contains(OnboardingScript.done)
                      || run.timeline.last?.has(A11yID.Household.list) == true,
                      "the last answer (line \(OnboardingScript.done)) did not open the household")

        let statusLike = run.allIDs.filter { $0.hasPrefix("a11y.onboarding.") && $0.lowercased().contains("status") }
        XCTAssertTrue(statusLike.isEmpty, "onboarding showed a status element \(statusLike): it must never ask for immigration status")
        for label in run.labels(of: A11yID.Onboarding.question) {
            XCTAssertTrue(A11yLabelLint.problems(label: label, identifier: A11yID.Onboarding.question).isEmpty,
                          "question read as '\(label)'")
        }
        XCTAssertTrue(run.timeline.last?.has(A11yID.Household.list) ?? false, "onboarding did not end on the household")
        run.app.terminate()
    }

    /// `hero_card_en` (5 lines): "Demo Student" -> person detail; "next step" -> the hero card; "read this" ->
    /// reading (stop control); "stop" -> read control again; "go back" -> person detail with its hero row.
    private enum HeroScript {
        static let total = 5
        static let person = 1
        static let open = 2
        static let read = 3
        static let stop = 4
        static let back = 5
    }

    /// Hero card by voice: open it and hear it read (reading shows the stop control), stop, go back.
    func test_voiceOnly_heroCard() throws {
        guard let run = try replay(script: "hero_card_en", language: .en, seed: A11ySeed.demoHousehold,
                                   watch: [A11yID.PersonDetail.list, A11yID.PersonDetail.hero, A11yID.Card.list,
                                           A11yID.Card.readAloud, A11yID.Card.stopReading, A11yID.Voice.unavailableNotice])
        else { return }
        XCTAssertEqual(run.total, HeroScript.total,
                       "hero_card_en has \(run.total.map(String.init) ?? "?") lines, expected \(HeroScript.total): update HeroScript")
        XCTAssertTrue(run.steps(showing: A11yID.PersonDetail.list).contains(HeroScript.person),
                      "saying the person's name (line \(HeroScript.person)) did not open person detail")
        XCTAssertTrue(run.steps(showing: A11yID.Card.list).contains(HeroScript.open),
                      "'next step' (line \(HeroScript.open)) did not open the hero card")
        XCTAssertTrue(run.steps(showing: A11yID.Card.stopReading).contains(HeroScript.read),
                      "'read this' (line \(HeroScript.read)) did not start reading (a11y.card.stopReading never appeared)")
        XCTAssertTrue(run.timeline.contains { $0.step == HeroScript.stop && $0.has(A11yID.Card.readAloud) && !$0.has(A11yID.Card.stopReading) },
                      "'stop' (line \(HeroScript.stop)) did not stop reading (A11Y-SPK-03)")
        XCTAssertTrue(run.steps(showing: A11yID.PersonDetail.hero).contains(HeroScript.back)
                      || run.timeline.last?.has(A11yID.PersonDetail.hero) == true,
                      "'go back' (line \(HeroScript.back)) did not return to person detail")
        XCTAssertFalse(run.everSeen(A11yID.Voice.unavailableNotice),
                       "English speech reported unavailable on the simulator")
        run.app.terminate()
    }

    /// `desk_handoff_es` line numbers: the n of the stub's "running n/total". Contract with the bundled script
    /// (ios/App/UITestFixtures/voicescript.desk_handoff_es.json, docs §9 VoiceScript): change both together.
    /// Lines 1-2 ("la primera", "siguiente paso") open the first person and then their hero card.
    private enum DeskScript {
        static let total = 7
        static let cardOpen = 2    // "siguiente paso" -> the hero card (a11y.card.call on screen)
        static let firstAsk = 3    // "llama a la oficina" -> a11y.router.confirm
        static let no = 4          // "no" -> the confirmation closes, nothing leaves the app
        static let secondAsk = 5   // "llama a la oficina" -> a11y.router.confirm again
        static let yes = 6         // "sí" -> a11y.router.handoff, value "callDesk"
        static let thirdAsk = 7    // "llama a la oficina" -> ends with the confirmation open
    }

    /// Desk handoff by voice. Script contract (docs §9): ask to call -> confirmation; "no" -> nothing
    /// leaves; ask again -> "sí" -> handoff recorded; ask a third time and stop with the question open.
    /// Every assertion on the handoff uses what was recorded while the script ran: AppModel clears
    /// `a11y.router.handoff` when the third ask opens a new confirmation.
    func test_voiceOnly_deskHandoff() throws {
        let confirmID = A11yID.Router.confirm, handoffID = A11yID.Router.handoff
        guard let run = try replay(script: "desk_handoff_es", language: .es, seed: A11ySeed.demoHousehold,
                                   watch: [confirmID, handoffID, A11yID.Desk.panel, A11yID.Card.list])
        else { return }
        let nav = run.nav
        XCTAssertEqual(run.total, DeskScript.total,
                       "desk_handoff_es has \(run.total.map(String.init) ?? "?") lines, expected \(DeskScript.total): update DeskScript")

        // Timeline of (identifier, script line): the lines during which each one was on screen.
        let confirmSteps = run.steps(showing: confirmID)
        let handoffSteps = run.steps(showing: handoffID)
        XCTAssertTrue(confirmSteps.contains(DeskScript.firstAsk),
                      "asking to call did not show the confirmation (A11Y-VC-06); a11y.router.confirm seen during lines \(confirmSteps)")
        XCTAssertTrue(run.steps(showing: A11yID.Card.list).contains(DeskScript.cardOpen),
                      "'siguiente paso' (line \(DeskScript.cardOpen)) did not open the hero card")
        XCTAssertTrue(run.timeline.contains { $0.step == DeskScript.no && !$0.has(confirmID) },
                      "'no' (line \(DeskScript.no)) did not close the confirmation")
        XCTAssertTrue(run.timeline.contains { $0.step == DeskScript.no && !$0.has(confirmID) && $0.has(A11yID.Card.list) },
                      "after 'no' (line \(DeskScript.no)) the card is not showing: cancelling must leave the user where they were")
        for step in [DeskScript.no, DeskScript.secondAsk] {
            XCTAssertFalse(handoffSteps.contains(step),
                           "a11y.router.handoff appeared during line \(step), after 'no': 'no' must leave nothing leaving the app")
        }
        let early = handoffSteps.filter { $0 < DeskScript.no }
        XCTAssertTrue(early.isEmpty, "a11y.router.handoff appeared before anyone said 'sí', during lines \(early)")
        XCTAssertTrue(confirmSteps.contains(DeskScript.secondAsk),
                      "asking again did not show the confirmation; a11y.router.confirm seen during lines \(confirmSteps)")

        let firstHandoff = run.timeline.firstIndex { $0.has(handoffID) }
        XCTAssertNotNil(firstHandoff, "the spoken 'sí' did not hand off to the desk (a11y.router.handoff never appeared)")
        if let firstHandoff {
            let sample = run.timeline[firstHandoff]
            XCTAssertEqual(sample.step, DeskScript.yes,
                           "a11y.router.handoff first appeared with the stub at '\(sample.status)', expected line \(DeskScript.yes) ('sí')")
            if let firstConfirm = run.timeline.firstIndex(where: { $0.has(confirmID) }) {
                XCTAssertLessThan(firstConfirm, firstHandoff, "handoff happened before the confirmation")
            }
        }
        // Label and value as recorded while the handoff was on screen (its value is the action, docs §9).
        let recorded = run.seen(handoffID)
        if !recorded.isEmpty {
            let heard = Replay.collapsed(recorded.map { "value '\($0.value)', label '\($0.label)'" })
            XCTAssertEqual(Replay.collapsed(recorded.map(\.value)), ["callDesk"], "handoff recorded the wrong action: \(heard)")
        }

        // The script ends with the confirmation open: it is also answerable by 44pt buttons, and it waits.
        let confirm = nav.element(confirmID)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "final confirmation is not showing")
        XCTAssertFalse(confirm.label.trimmingCharacters(in: .whitespaces).isEmpty, "confirmation question has no label")
        for id in [A11yID.Router.confirmYes, A11yID.Router.confirmNo] {
            let button = nav.element(id)
            XCTAssertTrue(button.exists, "\(id) missing: the question must also be answerable by a button")
            guard button.exists else { continue }
            XCTAssertEqual(button.elementType, .button, "\(id) is not a button")
            XCTAssertTrue(button.frame.width >= 44 && button.frame.height >= 44, "\(id) is \(button.frame.size), under 44x44pt")
            XCTAssertTrue(A11yLabelLint.problems(label: button.label, identifier: id).isEmpty, "\(id) label '\(button.label)'")
        }
        Thread.sleep(forTimeInterval: 10)   // no time limits (A11Y-COG-01): the question is still there
        XCTAssertTrue(confirm.exists, "the confirmation timed out; it must wait for an answer")
        run.app.terminate()
    }

    /// `switch_language_ht` (2 lines): "Kreyòl" (said in Spanish) -> ht surface; the spoken reply has no Creole
    /// voice, so the Creole notice shows (A11Y-LANG-03, A11Y-VC-09); "en español" -> back to the es household.
    private enum SwitchScript {
        static let total = 2
        static let toCreole = 1
        static let toSpanish = 2
    }

    /// Language switch by voice from another surface: "Kreyòl" on the Spanish surface, then "en español".
    func test_voiceOnly_switchLanguage() throws {
        guard let run = try replay(script: "switch_language_ht", language: .es, seed: A11ySeed.demoHousehold,
                                   watch: [A11yID.Voice.mic, A11yID.Voice.unavailableNotice, A11yID.Household.list])
        else { return }
        XCTAssertEqual(run.total, SwitchScript.total,
                       "switch_language_ht has \(run.total.map(String.init) ?? "?") lines, expected \(SwitchScript.total): update SwitchScript")
        XCTAssertTrue(run.steps(showing: A11yID.Voice.unavailableNotice).contains(SwitchScript.toCreole),
                      "after 'Kreyòl' (line \(SwitchScript.toCreole)) no Creole notice appeared: the app's ht reply must show "
                      + "a11y.voice.unavailableNotice instead of speaking with another voice (A11Y-LANG-03, A11Y-VC-09)")
        // The bundled script's line 2 expects a11y.household.list, which is already up, so the stub cannot tell
        // whether Spanish came back; the mic label below is the real check (app finding: tighten the expect).
        let micLabels = run.texts(of: A11yID.Voice.mic)
        guard let first = micLabels.first, let last = micLabels.last else {
            return XCTFail("the mic (a11y.voice.mic) was never visible")
        }
        XCTAssertTrue(micLabels.contains { $0 != first }, "the surface never changed (mic label stayed '\(first)')")
        XCTAssertEqual(last, first, "saying 'en español' (line \(SwitchScript.toSpanish)) did not return to the Spanish surface")
        run.app.terminate()
    }

    // MARK: - Replay

    struct Replay {
        /// One watched element as it was in one snapshot.
        struct Seen: Equatable {
            let id: String
            let label: String
            let value: String
            /// "label value", as a listener hears it.
            var text: String { [label, value].filter { !$0.isEmpty }.joined(separator: " ") }
        }

        /// One snapshot of the accessibility tree, tagged with the stub status read from that same snapshot.
        struct Sample {
            /// Value of `a11y.voice.stub` in this snapshot ("" if it was not in the tree).
            let status: String
            /// Script line being replayed: 0 while "loading", n for "running n/total" or "failed n: ...",
            /// nil after "passed" (or for an unreadable status).
            let step: Int?
            /// Watched elements present, in tree order.
            let present: [Seen]

            func has(_ id: String) -> Bool { present.contains { $0.id == id } }
            func ids(withPrefix prefix: String) -> [String] { present.map(\.id).filter { $0.hasPrefix(prefix) } }
        }

        let app: XCUIApplication
        let nav: A11yNavigator
        /// Every snapshot taken while the script ran, oldest first, plus one after it ended.
        var timeline: [Sample] = []
        /// Every identifier seen anywhere while the script ran.
        var allIDs: Set<String> = []
        /// Script length from "running n/total"; nil if the stub never reported it.
        var total: Int?

        func everSeen(_ id: String) -> Bool { timeline.contains { $0.has(id) } }
        /// Every recorded appearance of `id`, oldest first.
        func seen(_ id: String) -> [Seen] { timeline.flatMap { $0.present.filter { $0.id == id } } }
        /// Script lines during which `id` was on screen (sorted, distinct).
        func steps(showing id: String) -> [Int] { Array(Set(timeline.filter { $0.has(id) }.compactMap(\.step))).sorted() }
        /// Distinct consecutive "label value" texts of `id`.
        func texts(of id: String) -> [String] { Self.collapsed(seen(id).map(\.text)) }
        /// Distinct consecutive labels of `id`.
        func labels(of id: String) -> [String] { Self.collapsed(seen(id).map(\.label)) }

        static func collapsed(_ items: [String]) -> [String] {
            var out: [String] = []
            for item in items where out.last != item { out.append(item) }
            return out
        }

        /// (n, total) from "running n/total".
        static func running(_ status: String) -> (n: Int, total: Int)? {
            guard status.hasPrefix("running ") else { return nil }
            let parts = status.dropFirst("running ".count).split(separator: "/")
            guard parts.count == 2, let n = Int(parts[0]), let total = Int(parts[1]) else { return nil }
            return (n, total)
        }

        static func step(_ status: String) -> Int? {
            if status == "loading" { return 0 }
            if let r = running(status) { return r.n }
            if status.hasPrefix("failed ") {
                return Int(status.dropFirst("failed ".count).prefix { $0.isNumber })
            }
            return nil
        }
    }

    /// Launches with the script, then only observes until the stub reports a result. Returns nil when the
    /// stub or script is missing (a failure was recorded) and throws XCTSkip for it only while the test plan
    /// sets MYAD_VOICE_STUB_PENDING=1.
    /// Stub status (value of `a11y.voice.stub`): "loading" | "running <n>/<total>" | "passed" |
    /// "failed <n>: <reason>" | "scriptNotFound".
    private func replay(script: String, language: A11yLanguage, seed: String, watch: [String]) throws -> Replay? {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = A11yLaunch(language: language, size: .standard, seed: seed, voiceScript: script).arguments
        app.launch()
        let nav = A11yNavigator(app: app)
        var run = Replay(app: app, nav: nav)

        let stub = nav.element(A11yID.Voice.stub)
        guard stub.waitForExistence(timeout: 20) else {
            app.terminate()
            try voicePrerequisiteMissing("No voice stub hook in the app: launched with -myadVoiceStub YES -myadVoiceScript \(script) "
                                         + "but '\(A11yID.Voice.stub)' never appeared (Lead + Language, docs §9 VoiceScript).")
            return nil
        }
        let deadline = Date().addingTimeInterval(scriptTimeout)
        var status = ""
        while Date() < deadline {
            // Status and watched elements come from one snapshot, so each sample's script line is exact.
            status = observe(app: app, watch: watch, into: &run) ?? (stub.value as? String) ?? ""
            if status == "scriptNotFound" {
                app.terminate()
                try voicePrerequisiteMissing("Voice script '\(script)' is not bundled in the app (myAD Language, docs §9 VoiceScript).")
                return nil
            }
            if status == "passed" || status.hasPrefix("failed") { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(status, "passed", "voice script '\(script)' did not pass: stub reported '\(status.isEmpty ? "<timeout>" : status)'")
        observe(app: app, watch: watch, into: &run)
        return run
    }

    /// Skip only while the test plan says the stub is pending; otherwise a missing stub or script is a regression.
    private func voicePrerequisiteMissing(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        if A11yPending.voiceStub {
            throw XCTSkip("\(A11yPending.voiceStubVariable)=1 (test plan): \(message)", file: file, line: line)
        }
        XCTFail("\(message) If the stub has not shipped yet, the test plan must set \(A11yPending.voiceStubVariable)=1.",
                file: file, line: line)
    }

    /// Takes one snapshot, appends it to the timeline, and returns the stub status found in it
    /// (nil when the snapshot failed or had no `a11y.voice.stub`).
    @discardableResult
    private func observe(app: XCUIApplication, watch: [String], into run: inout Replay) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        var status: String?
        var present: [Replay.Seen] = []
        var ids: Set<String> = []
        func walk(_ n: any XCUIElementSnapshot) {
            let id = n.identifier
            if !id.isEmpty {
                ids.insert(id)
                if id == A11yID.Voice.stub { status = (n.value as? String) ?? "" }
                if watch.contains(where: { id == $0 || ($0.hasSuffix(".") && id.hasPrefix($0)) }) {
                    present.append(Replay.Seen(id: id, label: n.label, value: (n.value as? String) ?? ""))
                }
            }
            n.children.forEach(walk)
        }
        walk(root)
        run.allIDs.formUnion(ids)
        let current = status ?? ""
        if let total = Replay.running(current)?.total { run.total = total }
        run.timeline.append(Replay.Sample(status: current, step: Replay.step(current), present: present))
        return status
    }
}
