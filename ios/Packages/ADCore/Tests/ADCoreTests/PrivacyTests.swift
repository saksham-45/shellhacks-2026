import Foundation
import Testing
@testable import ADCore

@Suite("Privacy scopes")
struct PrivacyTests {
    let parentA: Person
    let adultB: Person
    let child: Person
    let home: Household

    init() {
        var a = person("A", age: 40, origin: "CU")
        a.statusWord = "test-status-a"
        a.papers = [Paper(kind: "passport", isImmigrationDocument: true, attachmentRefs: ["local://a-passport"]),
                    Paper(kind: "shared-lease", isImmigrationDocument: false, sharedWithHousehold: true)]
        parentA = a
        adultB = person("B", age: 38)
        child = person("Kid", age: 7)
        home = household([a, adultB, child], shared: SharedHousehold(hasCar: true, annualIncome: 1))
    }

    @Test func visibilityTruthTable() {
        let a = parentA.id, b = adultB.id, k = child.id
        func v(_ s: PrivacyScope, _ surface: CardSurface) -> Bool { PrivacyPolicy.isVisible(s, on: surface, in: home) }
        #expect(v(.sharedAddress, .household) && v(.sharedAddress, .person(b)) && v(.sharedAddress, .person(k)))
        #expect(v(.household, .household) && v(.household, .person(a)) && !v(.household, .person(k)))
        #expect(v(.personal(a), .person(a)))
        #expect(!v(.personal(a), .person(b)) && !v(.personal(a), .person(k)) && !v(.personal(a), .household))
        #expect(v(.sharedOnPurpose(by: a), .person(k)) && v(.sharedOnPurpose(by: a), .household))
        let stranger = PersonID()
        #expect(!v(.sharedAddress, .person(stranger)))
        #expect(home.view(for: .person(stranger)) == nil)
    }

    @Test func personAPapersNeverOnPersonBCard() throws {
        let viewB = try #require(home.view(for: .person(adultB.id)))
        let aSeenByB = try #require(viewB.members.first { $0.id == parentA.id })
        #expect(aSeenByB.statusWord == nil)
        #expect(aSeenByB.papers.map(\.kind) == ["shared-lease"])

        let viewHH = try #require(home.view(for: .household))
        #expect(viewHH.members.first { $0.id == parentA.id }?.papers.map(\.kind) == ["shared-lease"])
        #expect(viewHH.members.allSatisfy { $0.statusWord == nil })

        let viewA = try #require(home.view(for: .person(parentA.id)))
        let me = try #require(viewA.members.first { $0.id == parentA.id })
        #expect(me.statusWord == "test-status-a")
        #expect(Set(me.papers.map(\.kind)) == ["passport", "shared-lease"])
    }

    // Review finding 4: other members' cards and the household card got the full PersonProfile.
    @Test func othersSeeOnlyIdAndDisplayName() throws {
        for surface in [CardSurface.household, .person(adultB.id)] {
            let view = try #require(home.view(for: surface))
            let a = try #require(view.members.first { $0.id == parentA.id })
            #expect(a.displayName == "A")
            #expect(a.profile == nil, "no age/origin/goal/mode/stage of another member on \(surface)")
        }
        let own = try #require(home.view(for: .person(parentA.id))?.members.first { $0.id == parentA.id })
        #expect(own.profile?.age == 40 && own.profile?.origin?.countryCode == "CU" && own.profile?.stage == .safeThisWeek)
    }

    @Test func childCardSeesOnlySharedAddressPlusOnPurposeShares() throws {
        let view = try #require(home.view(for: .person(child.id)))
        #expect(view.pin == testPin)
        #expect(view.shared == nil && view.homeLanguage == nil)
        #expect(view.members.first { $0.id == child.id }?.profile?.displayName == "Kid")
        #expect(view.members.first { $0.id == adultB.id } == nil)
        let a = try #require(view.members.first { $0.id == parentA.id })
        #expect(a.displayName == nil && a.profile == nil && a.statusWord == nil)
        #expect(a.papers.map(\.kind) == ["shared-lease"])
    }

    // Review finding 3: a tourist viewer saw other members' on-purpose immigration content.
    @Test func touristViewerNeverSeesImmigrationContent() throws {
        var parent = person("Parent", age: 45, goal: .reunite)
        parent.statusWord = "test-status"
        parent.statusWordSharedWithHousehold = true
        parent.papers = [Paper(kind: "i-797", isImmigrationDocument: true, sharedWithHousehold: true),
                         Paper(kind: "lease", isImmigrationDocument: false, sharedWithHousehold: true)]
        var grandmother = person("Grandmother", age: 70, goal: .visit)
        grandmother.papers = [Paper(kind: "i-94", isImmigrationDocument: true)]
        let h = household([parent, grandmother])

        let touristView = try #require(h.view(for: .person(grandmother.id)))
        let p = try #require(touristView.members.first { $0.id == parent.id })
        #expect(p.statusWord == nil)
        #expect(p.papers.map(\.kind) == ["lease"])
        #expect(touristView.members.first { $0.id == grandmother.id }?.papers.isEmpty == true)

        // A resident viewer still sees what was shared on purpose.
        let residentView = try #require(h.view(for: .person(parent.id)))
        #expect(residentView.members.first { $0.id == parent.id }?.statusWord == "test-status")
    }

    @Test func storeKeepsFullDataAndOnlyTheViewFilters() async throws {
        let store: any HouseholdStore = InMemoryHouseholdStore()
        try await store.save(home)
        let loaded = try #require(try await store.loadAll().households.first)
        #expect(loaded == home)
        #expect(loaded.person(parentA.id)?.statusWord == "test-status-a")
        #expect(loaded.person(parentA.id)?.papers.count == 2)
        #expect(loaded.view(for: .person(adultB.id))?.members.first { $0.id == parentA.id }?.papers.count == 1)
    }

    // Review finding 8: the views are Encodable only.
    @Test func viewsAreEncodableNotDecodable() throws {
        #expect(!((HouseholdView.self as Any) is Decodable.Type))
        #expect(!((MemberView.self as Any) is Decodable.Type))
        #expect(!((PersonProfile.self as Any) is Decodable.Type))
        let text = try json(try #require(home.view(for: .person(parentA.id))))
        #expect(text.contains("\"thinkIn\":\"es\"") && text.contains("\"homeLanguage\":\"es\""))
        #expect(!text.contains("components"))
    }

    @Test func unknownAgeIsNotAChild() {
        #expect(!person(age: nil).isChild && person(age: 17).isChild && !person(age: 18).isChild)
    }
}
