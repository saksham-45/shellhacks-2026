#if canImport(SwiftData)
import ADCore
import Foundation
import SwiftData

/// One row per household holding the versioned JSON payload from `HouseholdCodec` (the
/// payload carries its own schema version). The schema lives in ADCore's Codable types.
@Model
final class StoredHousehold {
    @Attribute(.unique) var id: UUID
    var payload: Data

    init(id: UUID, payload: Data) {
        self.id = id
        self.payload = payload
    }
}

/// SwiftData-backed `HouseholdStore`. Stores full data; privacy is ADCore's domain layer.
/// Not compiled on Linux; build and test on the Mac.
@ModelActor
public actor SwiftDataHouseholdStore: HouseholdStore {
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, allowsSave: true)
        return try ModelContainer(for: StoredHousehold.self, configurations: config)
    }

    /// Sorted by id, same as `InMemoryHouseholdStore`: the order comes from `HouseholdLoad`
    /// itself, so every adapter shares it (review finding 13).
    public func loadAll() throws -> HouseholdLoad {
        let rows = try modelContext.fetch(FetchDescriptor<StoredHousehold>())
        return .decoding(rows.map { (id: HouseholdID($0.id), payload: $0.payload) })
    }

    public func save(_ household: Household) throws {
        let id = household.id.rawValue
        let payload = try HouseholdCodec.encode(household)
        let existing = try modelContext.fetch(FetchDescriptor<StoredHousehold>(predicate: #Predicate { $0.id == id }))
        if let row = existing.first {
            row.payload = payload
        } else {
            modelContext.insert(StoredHousehold(id: id, payload: payload))
        }
        try modelContext.save()
    }

    public func delete(_ id: HouseholdID) throws {
        let raw = id.rawValue
        try modelContext.delete(model: StoredHousehold.self, where: #Predicate { $0.id == raw })
        try modelContext.save()
    }

    public func deleteEverything() throws {
        try modelContext.delete(model: StoredHousehold.self)
        try modelContext.save()
    }
}
#endif
