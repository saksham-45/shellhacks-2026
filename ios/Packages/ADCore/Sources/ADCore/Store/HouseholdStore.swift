import Foundation

/// On-device persistence (name pinned by Lead). SwiftData adapter on iOS (ADCoreSwiftData);
/// in-memory here. No account, no network. Stores return FULL households: privacy is enforced
/// only in the domain layer (`PrivacyPolicy`, `Household.view(for:)`), never by storage.
public protocol HouseholdStore: Sendable {
    /// Every row decodes on its own: one bad row is reported in `failures`, never hides the rest.
    func loadAll() async throws -> HouseholdLoad
    func save(_ household: Household) async throws
    func delete(_ id: HouseholdID) async throws
    func deleteEverything() async throws
}

/// The result of loading every stored household.
public struct HouseholdLoad: Hashable, Sendable {
    /// Sorted by id (the UUID string, ascending). Every `HouseholdStore` returns this order
    /// because the sort lives here, not in each adapter.
    public let households: [Household]
    /// Rows that did not decode. They stay in storage untouched (quarantined), so nothing is lost.
    public let failures: [HouseholdLoadFailure]

    public init(households: [Household], failures: [HouseholdLoadFailure]) {
        self.households = households.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        self.failures = failures.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    /// Decodes each row independently.
    public static func decoding(_ rows: [(id: HouseholdID, payload: Data)]) -> HouseholdLoad {
        var households: [Household] = []
        var failures: [HouseholdLoadFailure] = []
        for row in rows {
            do { households.append(try HouseholdCodec.decode(row.payload)) }
            catch { failures.append(HouseholdLoadFailure(id: row.id, reason: String(describing: error))) }
        }
        return HouseholdLoad(households: households, failures: failures)
    }
}

public struct HouseholdLoadFailure: Hashable, Sendable {
    public let id: HouseholdID
    public let reason: String
}

public actor InMemoryHouseholdStore: HouseholdStore {
    private var rows: [HouseholdID: Data] = [:]

    public init() {}

    public func loadAll() -> HouseholdLoad {
        .decoding(rows.map { (id: $0.key, payload: $0.value) })
    }

    public func save(_ household: Household) throws {
        rows[household.id] = try HouseholdCodec.encode(household)
    }

    public func delete(_ id: HouseholdID) { rows[id] = nil }

    public func deleteEverything() { rows.removeAll() }

    /// Test hook: store a raw payload as-is (e.g. an old or corrupt row).
    func insertRaw(_ payload: Data, for id: HouseholdID) { rows[id] = payload }
}
