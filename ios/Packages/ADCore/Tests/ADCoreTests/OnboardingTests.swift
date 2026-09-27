import Foundation
import Testing
@testable import ADCore

@Suite("Voice-first onboarding")
struct OnboardingTests {
    /// Drives onboarding with answers only, as a voice turn would.
    func run(_ answers: [OnboardingAnswer]) -> (OnboardingDraft, [OnboardingOutcome]) {
        var draft = OnboardingDraft()
        var outcomes: [OnboardingOutcome] = []
        for answer in answers {
            let (next, outcome) = Onboarding.apply(answer, to: draft)
            draft = next
            outcomes.append(outcome)
        }
        return (draft, outcomes)
    }

    @Test func fourStepsInPlanOrderWithPrompts() {
        #expect(OnboardingStep.allCases == [.pin, .people, .originAndLanguage, .goal])
        #expect(OnboardingStep.allCases.map(\.prompt.key) == ["onboarding.q1", "onboarding.q2", "onboarding.q3", "onboarding.q4"])
        #expect(OnboardingStep.allCases.allSatisfy { $0.prompt.table == "ADCore" })
        #expect(OnboardingDraft().nextStep == .pin)
    }

    // Access review: q3 and q4 are asked per person, so the prompt names whose question it is.
    @Test func perPersonPromptsNameThePerson() {
        let (draft, _) = run([.pin(testPin),
                              .people([OnboardingPerson(displayName: "Priya", age: 20), OnboardingPerson(displayName: "Rosa")])])
        #expect(OnboardingDraft().prompt == OnboardingPrompt(question: .adCore("onboarding.q1"), personName: nil))
        #expect(OnboardingDraft().prompt?.leadIn == nil)
        let q3 = draft.prompt
        #expect(q3?.question.key == "onboarding.q3")
        #expect(q3?.personName == "Priya")
        #expect(q3?.leadIn == StringKey(key: "onboarding.about_person", table: "ADCore"))
        let afterPriya = run([.pin(testPin),
                              .people([OnboardingPerson(displayName: "Priya", age: 20), OnboardingPerson(displayName: "Rosa")]),
                              .originAndLanguage(origin: nil, thinkIn: "hi"), .goal(.study),
                              .originAndLanguage(origin: nil, thinkIn: "es")]).0
        #expect(afterPriya.prompt?.question.key == "onboarding.q4")
        #expect(afterPriya.prompt?.personName == "Rosa")
    }

    @Test func completesEndToEndUsingOnlyAnswers() throws {
        var draft = OnboardingDraft()
        var asked: [OnboardingStep] = []
        func answer(_ a: OnboardingAnswer) {
            if let step = draft.nextStep { asked.append(step) }
            draft = Onboarding.apply(a, to: draft).0
        }
        answer(.pin(testPin))
        answer(.people([OnboardingPerson(displayName: "Student", age: 20), OnboardingPerson(displayName: "Parent")]))
        answer(.originAndLanguage(origin: Origin(countryCode: "in"), thinkIn: "hi"))
        answer(.goal(.study))
        answer(.originAndLanguage(origin: Origin(countryCode: "CU"), thinkIn: "es"))
        answer(.goal(.reunite))
        #expect(draft.isComplete)
        #expect(asked == [.pin, .people, .originAndLanguage, .goal, .originAndLanguage, .goal])
        let h = try #require(draft.makeHousehold())
        #expect(h.pin == testPin)
        #expect(h.people.map(\.displayName) == ["Student", "Parent"])
        #expect(h.people[0].thinkInLanguageTag == "hi" && h.people[0].origin?.countryCode == "IN")
        #expect(h.people.allSatisfy { $0.stage == .safeThisWeek && $0.mode == .resident && $0.statusWord == nil })
    }

    @Test func invalidAnswerReturnsErrorAndSameStep() {
        let (draft, outcomes) = run([
            .pin(Pin(latitude: 200, longitude: 0)),
            .pin(testPin),
            .people([OnboardingPerson(displayName: " \n ")]),
            .people([OnboardingPerson(displayName: "A", age: -1)]),
            .people([]),
            .goal(.work),
            .people([OnboardingPerson(displayName: "A")]),
            .originAndLanguage(origin: nil, thinkIn: "  "),
        ])
        #expect(outcomes[0] == .invalid(.invalidPin, reask: .pin, person: nil))
        #expect(outcomes[1] == .next(.people, person: nil))
        // Review finding 12: a name of only whitespace and newlines is rejected.
        #expect(outcomes[2] == .invalid(.unnamedPerson(index: 0), reask: .people, person: nil))
        #expect(outcomes[3] == .invalid(.invalidAge(index: 0), reask: .people, person: nil))
        #expect(outcomes[4] == .invalid(.noPeople, reask: .people, person: nil))
        #expect(outcomes[5] == .invalid(.unexpectedAnswer(expected: .people), reask: .people, person: nil))
        let a = draft.people[0].id
        #expect(outcomes[6] == .next(.originAndLanguage, person: a))
        #expect(outcomes[7] == .invalid(.invalidLanguage, reask: .originAndLanguage, person: a))
        #expect(draft.nextStep == .originAndLanguage)
        #expect(OnboardingError.invalidPin.messageKey.table == "ADCore")
    }

    @Test func touristPathAsksTheSameFourStepsAndSkipsNone() throws {
        let (draft, outcomes) = run([
            .pin(testPin), .people([OnboardingPerson(displayName: "Visitor")]),
            .originAndLanguage(origin: nil, thinkIn: "en"), .goal(.visit),
        ])
        #expect(outcomes.last == .complete)
        let visitor = try #require(draft.makeHousehold()?.people.first)
        #expect(visitor.mode == .tourist && visitor.stage == .safeThisWeek)
    }

    @Test func statusWordIsNeverAStepNorPrompted() throws {
        // No step and no prompt is about status.
        #expect(!OnboardingStep.allCases.map(\.rawValue).contains { $0.lowercased().contains("status") })
        #expect(!OnboardingStep.allCases.map(\.prompt.key).contains { $0.contains("status") })
        // Completing onboarding never requires it.
        let (done, outcomes) = run([
            .pin(testPin), .people([OnboardingPerson(displayName: "A")]),
            .originAndLanguage(origin: nil, thinkIn: "ht"), .goal(.arrive),
        ])
        #expect(outcomes.allSatisfy { if case .next(let step, _) = $0 { step.rawValue != "status" } else { true } })
        #expect(done.isComplete && done.makeHousehold()?.people.first?.statusWord == nil)
        // Volunteered: accepted, does not advance, and lands only on that person.
        let (withWord, outcome) = Onboarding.apply(.volunteeredStatusWord("test-status", person: done.people[0].id), to: done)
        #expect(outcome == .complete)
        #expect(withWord.makeHousehold()?.people.first?.statusWord == "test-status")
        let stranger = PersonID()
        #expect(Onboarding.apply(.volunteeredStatusWord("x", person: stranger), to: done).1
                == .invalid(.unknownPerson(stranger), reask: nil, person: nil))
    }

    @Test func answersAndStepsEncodeAsTaggedJSON() throws {
        let answers: [OnboardingAnswer] = [
            .pin(testPin), .people([OnboardingPerson(displayName: "A", age: 3)]),
            .originAndLanguage(origin: Origin(countryCode: "HT"), thinkIn: "ht"), .goal(.getThroughWeek),
            .volunteeredStatusWord("test-status", person: PersonID()),
        ]
        for a in answers { #expect(try decode(OnboardingAnswer.self, try json(a)) == a) }
        #expect(try json(OnboardingAnswer.goal(.visit)) == #"{"goal":"visit","type":"goal"}"#)
        #expect(try json(OnboardingStep.originAndLanguage) == #""origin_and_language""#)
        #expect(try json(OnboardingAnswer.originAndLanguage(origin: Origin(countryCode: "ht"), thinkIn: "ht"))
                == #"{"origin_country_code":"HT","think_in":"ht","type":"origin_and_language"}"#)
        #expect(try json(OnboardingAnswer.people([OnboardingPerson(displayName: "A", age: 3)]))
                == #"{"people":[{"age":3,"display_name":"A"}],"type":"people"}"#)
        let id = PersonID()
        #expect(try json(OnboardingAnswer.volunteeredStatusWord("test-status", person: id))
                == #"{"person_id":"\#(id.rawValue.uuidString)","status_word":"test-status","type":"volunteered_status_word"}"#)
        // Draft resumes after a round trip.
        let (draft, _) = run([.pin(testPin), .people([OnboardingPerson(displayName: "A")])])
        let back = try decode(OnboardingDraft.self, try json(draft))
        #expect(back == draft && back.nextStep == .originAndLanguage)
    }
}
