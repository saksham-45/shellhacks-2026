import Foundation
import Testing
@testable import ADCore

@Suite("Store and schema")
struct StoreCodecTests {
    @Test func inMemoryStoreRoundTripSortedAndWipe() async throws {
        let store: any HouseholdStore = InMemoryHouseholdStore()
        var p = person("A", origin: "IN", goal: .study, thinkIn: hi)
        p.papers = [Paper(kind: "i-20", isImmigrationDocument: true)]
        let h1 = household([p]), h2 = household([])
        try await store.save(h1)
        try await store.save(h2)
        let load = try await store.loadAll()
        #expect(load.failures.isEmpty)
        #expect(load.households.map(\.id) == [h1, h2].map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
        #expect(load.households.first { $0.id == h1.id } == h1)
        try await store.delete(h2.id)
        #expect(try await store.loadAll().households == [h1])
        try await store.deleteEverything()
        #expect(try await store.loadAll().households.isEmpty)
    }

    // Review finding 13: the SwiftData adapter carried an unused schemaVersion column and returned
    // households in fetch order. The order is now HouseholdLoad's, shared by every store.
    @Test func everyStoreReturnsHouseholdsSortedById() async throws {
        let homes = (0..<6).map { _ in household([]) }
        let expected = homes.map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let rows = homes.reversed().map { (id: $0.id, payload: try! HouseholdCodec.encode($0)) }
        #expect(HouseholdLoad.decoding(rows).households.map(\.id) == expected)
        #expect(HouseholdLoad.decoding(rows.shuffled()).households.map(\.id) == expected)
        let store = InMemoryHouseholdStore()
        for home in homes.shuffled() { try await store.save(home) }
        #expect(await store.loadAll().households.map(\.id) == expected)
        // The stored payload carries the schema version, so no store needs a version column.
        let payload = try HouseholdCodec.encode(homes[0])
        let envelope = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(envelope?["schemaVersion"] as? Int == HouseholdCodec.schemaVersion)
    }

    // Review finding 7: one bad row made every household unreadable.
    @Test func oneBadRowIsReportedAndDoesNotHideTheRest() async throws {
        let store = InMemoryHouseholdStore()
        let good = household([person()])
        try await store.save(good)
        let badID = HouseholdID()
        await store.insertRaw(Data("{not json".utf8), for: badID)
        let load = await store.loadAll()
        #expect(load.households == [good])
        #expect(load.failures.map(\.id) == [badID])
    }

    @Test func decodesHandWrittenV1Fixture() throws {
        let h = try HouseholdCodec.decode(try fixture("household-v1.json"))
        #expect(h.name == "Test household")
        #expect(h.homeLanguageTag == "es-419")
        #expect(h.people.map(\.thinkInLanguageTag) == ["ht", "hi"])
        #expect(h.people[1].mode == .tourist && h.people[1].stage == .footing)
        #expect(h.people[0].papers.first?.isImmigrationDocument == true)
    }

    @Test func decodesOlderV0Fixture() throws {
        // v0: the unversioned skeleton-stub shape, migrated on read.
        let h = try HouseholdCodec.decode(try fixture("household-v0.json"))
        #expect(h.homeLanguageTag == "es")
        let p = try #require(h.people.first)
        #expect(p.displayName == "Test person" && p.origin?.countryCode == "CU")
        #expect(p.thinkInLanguageTag == "es" && p.surfaceLanguageTag == "es")
        #expect(p.stage == .money && p.mode == .resident && p.statusWord == nil)
        let tourist = h.people[1]
        #expect(tourist.mode == .tourist && tourist.stage == .safeThisWeek && tourist.thinkInLanguageTag == "en")
        // Re-encoding writes the current version.
        #expect(try json(try HouseholdCodec.decode(HouseholdCodec.encode(h))) == (try json(h)))
        #expect(String(decoding: try HouseholdCodec.encode(h), as: UTF8.self).contains("\"schemaVersion\":1"))
    }

    // Review finding 6: the version is read from the header before the household is decoded.
    @Test func futureSchemaOfDifferentShapeIsUnsupported() {
        #expect(throws: HouseholdCodec.CodecError.unsupportedSchema(2)) {
            try HouseholdCodec.decode(try fixture("household-v2-future.json"))
        }
    }

    // Review finding 5: duplicate person ids and invalid tourist stages decoded silently.
    @Test func householdDecodeRejectsDuplicatePeopleAndBadStages() throws {
        let p = person()
        let personJSON = try json(p)
        let dup = #"{"id":"\#(UUID().uuidString)","people":[\#(personJSON),\#(personJSON)]}"#
        #expect(throws: DecodingError.self) { try decode(Household.self, dup) }
        let tourist = personJSON.replacingOccurrences(of: #""mode":"resident""#, with: #""mode":"tourist""#)
            .replacingOccurrences(of: #""stage":1"#, with: #""stage":5"#)
        #expect(throws: DecodingError.self) { try decode(Person.self, tourist) }
    }

    // Review finding 10: origin country codes were not uppercased on decode.
    @Test func originUppercasesOnDecode() throws {
        #expect(try decode(Origin.self, #"{"countryCode":"cu"}"#).countryCode == "CU")
    }
}
