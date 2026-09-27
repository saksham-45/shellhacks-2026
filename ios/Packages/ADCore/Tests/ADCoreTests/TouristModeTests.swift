import Testing
@testable import ADCore

@Suite("Tourist mode and \"I live here now\"")
struct TouristModeTests {
    @Test func visitGoalStartsTouristAndSkipsTwoThroughNine() {
        var t = person(goal: .visit)
        #expect(t.mode == .tourist && t.stage == .safeThisWeek)
        do { let moved = t.advanceStage(); #expect(moved) }
        #expect(t.stage == .footing)
        do { let moved = t.advanceStage(); #expect(!moved) }
    }

    @Test(arguments: Stage.allCases.filter(\.isSkippedInTouristMode))
    func touristCannotEnterSkippedStage(_ stage: Stage) {
        var t = person(goal: .visit)
        var thrown: StageError?
        do { try t.setStage(stage) } catch { thrown = error }
        #expect(thrown == .skippedInTouristMode(stage))
        #expect(t.stage == .safeThisWeek)
    }

    @Test func touristHeroComesFromTouristList() {
        let t = person(goal: .visit)
        #expect(HeroPolicy.heroTopics(for: t) == Mode.touristHeroTopics)
        #expect(policy.hero(for: t, catalog: catalogOnePerTopic)?.heroTopic == .airport)
        #expect(policy.nextSteps(for: t, catalog: catalogOnePerTopic, limit: 10).map(\.heroTopic!) == Mode.touristHeroTopics)
    }

    @Test func immigrationContentNeverShownToTourist() {
        // Content even (wrongly) declares it for tourists: the hard rule still filters it.
        let papers = card("immigration-papers", .scam, modes: [.resident, .tourist], immigration: true, lenses: [.tourist])
        let t = person(goal: .visit)
        #expect(!HeroPolicy.isAllowed(papers, in: .tourist))
        #expect(policy.nextSteps(for: t, catalog: [papers]).isEmpty)
        let h = household([t])
        #expect(HeroPolicy.wallet(for: .person(t.id), in: h, catalog: [papers]).isEmpty)
        #expect(HeroPolicy.wallet(for: .household, in: h,
                                  catalog: [card("hh-papers", nil, subject: .household, modes: [.tourist], immigration: true)]).isEmpty)
        #expect(HeroPolicy.isAllowed(papers, in: .resident))
    }

    // Review finding 2: household-subject immigration cards were checked against the household's
    // mode, so a tourist in a mixed household got them.
    @Test func touristInMixedHouseholdGetsNoHouseholdImmigrationCards() {
        let grandmother = person("Grandmother", age: 70, goal: .visit)
        let parent = person("Parent", goal: .work), kid = person("Kid", age: 8, goal: .arrive)
        let h = household([grandmother, parent, kid])
        #expect(h.mode == .resident)
        let hhImmigration = card("hh-immigration", nil, subject: .household, modes: [.resident, .tourist], immigration: true)
        let hhTrash = card("hh-week", nil, subject: .household, modes: [.resident, .tourist])
        let wallet = HeroPolicy.wallet(for: .person(grandmother.id), in: h, catalog: [hhImmigration, hhTrash])
        #expect(wallet.map(\.id) == ["hh-week"])
        #expect(HeroPolicy.wallet(for: .person(parent.id), in: h, catalog: [hhImmigration, hhTrash]).count == 2)
        #expect(!HeroPolicy.canShow(hhImmigration, on: .person(grandmother.id), in: h))
    }

    @Test func householdIsTouristOnlyWhenEveryoneIs() {
        let t = person(goal: .visit), r = person(goal: .work)
        #expect(household([t]).mode == .tourist)
        #expect(household([t, r]).mode == .resident)
    }

    @Test func iLiveHereNowFromFootingResumesAtStageTwo() throws {
        var t = person(goal: .visit)
        try t.setStage(.footing)
        t.iLiveHereNow()
        #expect(t.mode == .resident && t.stage == .mailAndStatus && t.goal == .arrive)
        #expect(t.statusWord == nil)
        #expect(policy.hero(for: t, catalog: catalogOnePerTopic)?.heroTopic == .statusWord)
    }

    @Test func iLiveHereNowFromStageOneStaysAtOne() {
        var t = person(goal: .visit)
        t.iLiveHereNow(goal: .work)
        #expect(t.mode == .resident && t.stage == .safeThisWeek && t.goal == .work)
    }

    @Test func iLiveHereNowUnlocksImmigrationContent() throws {
        let papers = card("immigration-papers", .statusWord, modes: [.resident], immigration: true)
        var t = person(goal: .visit)
        try t.setStage(.footing)
        #expect(policy.hero(for: t, catalog: [papers]) == nil)
        t.iLiveHereNow()
        #expect(policy.hero(for: t, catalog: [papers])?.id == "immigration-papers")
    }

    @Test func iLiveHereNowIsNoOpForResident() throws {
        var r = person(goal: .work)
        try r.setStage(.roof)
        r.iLiveHereNow()
        #expect(r.mode == .resident && r.stage == .roof && r.goal == .work)
    }

    @Test func becomeTouristClampsSkippedStage() throws {
        var r = person(goal: .work)
        try r.setStage(.roof)
        r.becomeTourist()
        #expect(r.mode == .tourist && r.stage == .safeThisWeek && r.goal == .visit)
    }
}
