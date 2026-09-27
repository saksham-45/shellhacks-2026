import Testing
@testable import ADCore

@Suite("Stages and hero")
struct StageHeroTests {
    @Test func stageTableMatchesPlan() {
        // myMiami plan, "Stages", column "The hero is".
        let expected: [Stage: [HeroTopic]] = [
            .safeThisWeek: [.bed, .food, .airport, .scam],
            .mailAndStatus: [.statusWord, .mailbox],
            .identification: [.idChecklist],
            .money: [.bank, .remittance, .noCheckCasher],
            .roof: [.rentLine, .listingCheck, .whichCity],
            .health: [.clinicDesk],
            .schoolOrAllowedWork: [.schoolZone, .dso, .eadDates],
            .movement: [.transit, .license, .tolls, .insurance],
            .paperTrail: [.irs, .credit, .deadlines],
            .footing: [.ordinaryWeek],
        ]
        #expect(Stage.allCases.map(\.number) == Array(1...10))
        for stage in Stage.allCases { #expect(stage.heroTopics == expected[stage]) }
    }

    @Test(arguments: Stage.allCases)
    func heroFollowsStage(_ stage: Stage) throws {
        var p = person()
        try p.setStage(stage)
        let hero = try #require(policy.hero(for: p, catalog: catalogOnePerTopic))
        #expect(hero.heroTopic == stage.heroTopics.first)
        let steps = policy.nextSteps(for: p, catalog: catalogOnePerTopic)
        #expect(steps.count == min(3, stage.heroTopics.count))
        #expect(steps.allSatisfy { stage.heroTopics.contains($0.heroTopic!) })
    }

    @Test func changingStageChangesHero() throws {
        var p = person()
        #expect(policy.hero(for: p, catalog: catalogOnePerTopic)?.heroTopic == .bed)
        do { let moved = p.advanceStage(); #expect(moved) }
        #expect(policy.hero(for: p, catalog: catalogOnePerTopic)?.heroTopic == .statusWord)
        try p.setStage(.footing)
        #expect(policy.hero(for: p, catalog: catalogOnePerTopic)?.heroTopic == .ordinaryWeek)
        do { let moved = p.advanceStage(); #expect(!moved) }
    }

    @Test func completedCardMovesToNextStep() {
        var p = person()
        p.completedCards = ["bed"]
        #expect(policy.hero(for: p, catalog: catalogOnePerTopic)?.heroTopic == .food)
    }

    @Test func householdCardsNeverBecomePersonHero() {
        #expect(policy.hero(for: person(), catalog: [card("week", .bed, subject: .household)]) == nil)
    }

    // Review finding 11: a negative limit used to crash in prefix(_:).
    @Test func negativeLimitIsClampedToZero() {
        #expect(policy.nextSteps(for: person(), catalog: catalogOnePerTopic, limit: -1).isEmpty)
    }

    // Demo beat: student from India, stage "movement" -> the hero is the license.
    @Test func demoStudentHeroIsLicense() throws {
        var student = person("Student", age: 20, origin: "IN", goal: .study, thinkIn: hi)
        try student.setStage(.movement)
        let catalog = [card("transit", .transit), card("license", .license, lenses: [.leftDriving, .internationalStudent])]
        #expect(policy.hero(for: student, catalog: catalog)?.id == "license")
        #expect(policy.lenses(for: student) == [.leftDriving, .internationalStudent])
    }

    // Demo beat: parent, stage "safe this week" -> the hero is the notario warning.
    @Test func demoParentHeroIsNotarioWarning() {
        let parent = person("Parent", age: 60, origin: "CU")
        let catalog = [card("bed", .bed), card("notario-warning", .scam, lenses: [.latinAmerica])]
        #expect(policy.hero(for: parent, catalog: catalog)?.id == "notario-warning")
    }
}
