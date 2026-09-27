import Foundation
import Testing
@testable import ADCore

@Suite("Status word is optional everywhere")
struct StatusOptionalTests {
    @Test(arguments: Stage.allCases)
    func heroWorksWithoutStatus(_ stage: Stage) throws {
        var p = person()
        try p.setStage(stage)
        #expect(p.statusWord == nil)
        #expect(policy.hero(for: p, catalog: catalogOnePerTopic) != nil)
    }

    @Test func viewAndStoreWorkWithoutStatus() async throws {
        let p = person()
        let h = household([p])
        #expect(h.view(for: .person(p.id))?.members.first?.statusWord == nil)
        let store: any HouseholdStore = InMemoryHouseholdStore()
        try await store.save(h)
        let loaded = try await store.loadAll().households
        #expect(loaded == [h] && loaded.first?.people.first?.statusWord == nil)
    }
}
