import Foundation
import Testing
@testable import ADCore

/// Mirrors DESIGN.md §2 so the caller's-view sketch stays compilable.
@Suite("Design doc usage")
struct UsageTests {
    @Test func callerViewCompilesAndBehaves() throws {
        var draft = OnboardingDraft()
        for answer: OnboardingAnswer in [
            .pin(Pin(latitude: 0, longitude: 0, address: "test pin")),
            .people([OnboardingPerson(displayName: "Student", age: 20)]),
            .originAndLanguage(origin: Origin(countryCode: "IN"), thinkIn: "hi"),
            .goal(.study),
        ] {
            let (next, outcome) = Onboarding.apply(answer, to: draft)
            if case .invalid = outcome { Issue.record("unexpected \(outcome)") }
            draft = next
        }
        var home = try #require(draft.makeHousehold())
        let studentID = home.people[0].id
        let parent = Person(displayName: "Parent", age: 58, origin: Origin(countryCode: "CU"), thinkIn: es, goal: .reunite)
        try home.add(parent)
        try home.update(studentID) { (p: inout Person) throws(StageError) in try p.setStage(.movement) }
        let visitor = Person(displayName: "Visitor", thinkIn: en, goal: .visit)
        try home.add(visitor)
        home.update(visitor.id) { $0.iLiveHereNow() }
        #expect(home.person(visitor.id)?.mode == .resident)
        let registry = [card("transit", .transit), card("license", .license, lenses: [.leftDriving]),
                        card("bed", .bed), card("notario-warning", .scam, lenses: [.latinAmerica])]
        #expect(policy.hero(for: home.person(studentID)!, catalog: registry)?.id == "license")
        #expect(policy.hero(for: home.person(parent.id)!, catalog: registry)?.id == "notario-warning")
    }
}
