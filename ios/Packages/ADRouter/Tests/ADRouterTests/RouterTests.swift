import Foundation
import Testing
import ADCore
import ADLocale
@testable import ADRouter

@MainActor
@Suite("Router: one entry point, privacy, leave-app confirmation")
struct RouterTests {
    @Test func startsInOnboardingWithoutAHouseholdAndAtHomeWithOne() {
        let fx = RecordingEffects()
        let fresh = Fixture.router(household: nil, effects: fx)
        #expect(fresh.path == [.onboarding(.pin)])
        #expect(fresh.perform(.back, from: .touch) == .refused(reason: RouterText.refusedAlreadyHome))
        #expect(fresh.path == [.onboarding(.pin)])
        #expect(Fixture.router(household: Fixture.household().0, effects: fx).current == .household)
    }

    @Test func callDeskAlwaysAsksFirstEvenFromTouch() {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        let outcome = router.perform(.callDesk(Fixture.desk311), from: .touch)
        #expect(outcome == .needsConfirmation(.callDesk(Fixture.desk311), prompt: RouterText.askCallDesk))
        #expect(fx.exits.isEmpty)
        #expect(router.context.awaitingConfirmation)
        router.perform(.confirm(true), from: .touch)
        #expect(fx.exits == [.call(Fixture.desk311)])
        #expect(!router.context.awaitingConfirmation)
    }

    @Test func noCancelsAndConfirmWithoutAQuestionIsRefused() {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        #expect(router.perform(.confirm(true), from: .voice) == .refused(reason: RouterText.refusedNothingToConfirm))
        router.perform(.openMap(.desk(Fixture.desk311)), from: .voice)
        #expect(router.perform(.confirm(false), from: .voice) == .performed(Confirmation(key: RouterText.cancelled)))
        #expect(fx.exits.isEmpty)
    }

    @Test func openMapPlaceRefusesAFactThatIsNotAPlace() {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        let notPlace = FactRef(regionPackID: "us", ledgerFactID: TestFacts.notPlaceID)
        let unknown = FactRef(regionPackID: "us", ledgerFactID: "test.nothing")
        let place = FactRef(regionPackID: "us", ledgerFactID: TestFacts.placeID)
        #expect(router.perform(.openMap(.place(notPlace)), from: .voice) == .refused(reason: RouterText.refusedNotAPlace))
        #expect(router.perform(.openMap(.place(unknown)), from: .voice) == .refused(reason: RouterText.refusedNotAPlace))
        #expect(!router.context.awaitingConfirmation)
        #expect(router.perform(.openMap(.place(place)), from: .voice) == .needsConfirmation(.openMap(.place(place)), prompt: RouterText.askOpenMap))
        router.perform(.confirm(true), from: .voice)
        #expect(fx.exits == [.map(.place(place))])
    }

    @Test func aChildsSurfaceCannotOpenAnotherMembersCard() {
        let fx = RecordingEffects()
        let (h, student, parent, child) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(child)), from: .touch)
        #expect(router.perform(.navigate(.person(parent)), from: .voice) == .refused(reason: RouterText.refusedPrivacy))
        #expect(router.perform(.navigate(.card("license-checklist", person: student)), from: .voice) == .refused(reason: RouterText.refusedPrivacy))
        #expect(router.current == .person(child))
        // An adult's surface shows the roster.
        router.perform(.home, from: .touch)
        router.perform(.navigate(.person(parent)), from: .touch)
        #expect(router.perform(.navigate(.person(student)), from: .voice) == .performed(Confirmation(key: RouterText.opened, destination: .person(student))))
    }

    @Test func aTouristNeverReachesImmigrationContentOrSkippedStages() {
        let fx = RecordingEffects()
        let (h, _, parent, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(parent)), from: .touch)
        router.perform(.navigate(.card("status-word", person: parent)), from: .touch)
        #expect(router.current == .card("status-word", person: parent))
        router.perform(.back, from: .touch)
        router.perform(.setMode(.tourist), from: .voice)
        #expect(router.household?.person(parent)?.mode == .tourist)
        #expect(router.perform(.navigate(.card("status-word", person: parent)), from: .voice) == .refused(reason: RouterText.refusedTourist))
        #expect(router.perform(.navigate(.stage(parent, .mailAndStatus)), from: .voice) == .refused(reason: RouterText.refusedTourist))
        #expect(router.perform(.readAloud(.card("status-word")), from: .voice) == .refused(reason: RouterText.refusedTourist))
    }

    @Test func switchingToTouristClosesScreensTheTouristMayNotSee() {
        let fx = RecordingEffects()
        let (h, _, parent, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(parent)), from: .touch)
        router.perform(.navigate(.stage(parent, .mailAndStatus)), from: .touch)
        router.perform(.setMode(.tourist), from: .touch)
        #expect(router.path == [.person(parent)])
    }

    @Test func policyBands() {
        let policy = IntentPolicy()
        let c = try! Clarification(question: RouterText.clarifyWhichCard, options: [
            ClarifyOption(id: "a", label: RouterText.opened, action: .back),
            ClarifyOption(id: "b", label: RouterText.opened, action: .home)])
        #expect(policy.decide(IntentResolution(action: .home, confidence: 0.9, replyLanguage: "en")) == .perform(.home))
        #expect(policy.decide(IntentResolution(action: .home, confidence: 0.75, replyLanguage: "en")) == .perform(.home))
        #expect(policy.decide(IntentResolution(action: .home, confidence: 0.6, clarification: c, replyLanguage: "en")) == .clarify(c))
        #expect(policy.decide(IntentResolution(action: .home, confidence: 0.6, replyLanguage: "en")) == .handToDesk(nil))
        #expect(policy.decide(IntentResolution(confidence: 0.3, clarification: c, replyLanguage: "en")) == .handToDesk(nil))
        #expect(policy.decide(IntentResolution(action: .home, grounding: .desk(Fixture.deskDSO, reason: RouterText.dontHaveThis),
                                               confidence: 0.1, replyLanguage: "en")) == .handToDesk(Fixture.deskDSO))
    }

    @Test func aConfidentAnswerMustBeGroundedInTheCardItOpens() {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        let onCard = FactRef(regionPackID: "us-fl-miamidade", ledgerFactID: "us-fl-miamidade.tolls.dolphin-97-ave.sunpass")
        let offCard = FactRef(regionPackID: "us-fl", ledgerFactID: "us-fl.license.i20-required")
        let bad = IntentResolution(action: .navigate(.card("tolls", person: nil)), grounding: .card("tolls", facts: [offCard]),
                                   confidence: 0.9, replyLanguage: "es")
        #expect(router.handle(bad, from: .voice) == .refused(reason: RouterText.refusedUngrounded))
        let mismatch = IntentResolution(action: .navigate(.card("transit", person: nil)), grounding: .card("tolls", facts: [onCard]),
                                        confidence: 0.9, replyLanguage: "es")
        #expect(router.handle(mismatch, from: .voice) == .refused(reason: RouterText.refusedUngrounded))
        router.perform(.navigate(.cards(CardFilter(subject: .household))), from: .touch)
        let good = IntentResolution(action: .navigate(.card("trash-week", person: nil)), grounding: .card("trash-week", facts: []),
                                    confidence: 0.9, replyLanguage: "es")
        #expect(router.handle(good, from: .voice) == .performed(Confirmation(key: RouterText.opened, destination: .card("trash-week", person: nil), card: "trash-week")))
        #expect(router.replyLanguage == "es")
    }

    @Test func lowConfidenceHandsToTheDeskInsteadOfGuessing() {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        let low = IntentResolution(action: .navigate(.card("tolls", person: nil)), confidence: 0.3, replyLanguage: "ht")
        let outcome = router.handle(low, from: .voice)
        #expect(outcome == .performed(Confirmation(key: RouterText.dontHaveThis, destination: .desk(Fixture.desk311), desk: Fixture.desk311)))
        #expect(router.current == .desk(Fixture.desk311))
    }

    @Test func systemBackGestureCanOnlyPop() {
        let fx = RecordingEffects()
        let (h, student, _, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(student)), from: .touch)
        router.perform(.navigate(.card("tolls", person: student)), from: .touch)
        router.systemPopped(to: [.person(student), .card("tolls", person: student), .settings])
        #expect(router.path.count == 2)
        router.systemPopped(to: [.settings])
        #expect(router.path.count == 2)
        router.systemPopped(to: [.person(student)])
        #expect(router.path == [.person(student)])
        #expect(fx.outcomes.last?.2 == .touch)
    }

    @Test func everyActionReportsToEffects() {
        let fx = RecordingEffects()
        let router = Fixture.router(household: Fixture.household().0, effects: fx)
        router.perform(.navigate(.settings), from: .voiceOver)
        router.perform(.back, from: .appIntent)
        #expect(fx.outcomes.map(\.2) == [.voiceOver, .appIntent])
        #expect(fx.outcomes.map(\.3) == [true, true])
    }

    @Test func contextCarriesIdsOnly() {
        let fx = RecordingEffects()
        let (h, student, _, _) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.person(student)), from: .touch)
        router.perform(.navigate(.card("license-checklist", person: student)), from: .touch)
        let c = router.context
        #expect(c.personID == student && c.cardID == "license-checklist" && c.deskID == Fixture.deskDSO)
        #expect(c.stage == .movement && c.mode == .resident)
    }

    @Test func addEditDeleteAndUndoGoThroughTheRouter() {
        let fx = RecordingEffects()
        let (h, student, parent, child) = Fixture.household()
        let router = Fixture.router(household: h, effects: fx)
        router.perform(.navigate(.addPerson), from: .touch)
        #expect(router.perform(.savePerson(PersonDraft(displayName: "  ", thinkIn: "es", goal: .work)), from: .touch)
                == .refused(reason: RouterText.refusedInvalidPerson))
        let saved = router.perform(.savePerson(PersonDraft(displayName: "Example Cousin", age: 30, thinkIn: "ht", goal: .visit)), from: .touch)
        guard case .performed(let c) = saved, case .person(let cousin)? = c.destination else { Issue.record("\(saved)"); return }
        #expect(router.path == [.person(cousin)])
        #expect(router.household?.person(cousin)?.mode == .tourist)
        #expect(router.household?.people.count == 4)

        router.perform(.navigate(.editPerson(student)), from: .touch)
        var edit = PersonDraft(router.household!.person(student)!)
        edit.stage = .schoolOrAllowedWork
        edit.surfaceLanguage = "ht"
        router.perform(.savePerson(edit), from: .voice)
        #expect(router.household?.person(student)?.stage == .schoolOrAllowedWork)
        #expect(router.household?.person(student)?.surfaceLanguageTag == "ht")
        #expect(router.path == [.person(cousin)])  // the edit form closed

        // A tourist cannot be put on a skipped stage.
        var bad = PersonDraft(router.household!.person(cousin)!)
        bad.stage = .mailAndStatus
        #expect(router.perform(.savePerson(bad), from: .touch) == .refused(reason: RouterText.refusedTourist))

        // A child's surface cannot delete another member.
        router.perform(.home, from: .touch)
        router.perform(.navigate(.person(child)), from: .touch)
        #expect(router.perform(.deletePerson(parent), from: .touch) == .refused(reason: RouterText.refusedPrivacy))
        router.perform(.home, from: .touch)
        router.perform(.navigate(.person(parent)), from: .touch)
        router.perform(.deletePerson(parent), from: .touch)
        #expect(router.household?.person(parent) == nil)
        #expect(router.path.isEmpty)
        router.perform(.undo, from: .voice)
        #expect(router.household?.person(parent) != nil)
        #expect(router.perform(.undo, from: .voice) == .refused(reason: RouterText.refusedNothingToUndo))
    }
}
