// Shared type (ARCHITECTURE.md §12).

/// The office a card ends at. Its name is copy keyed by `id`; its phone/url are ledger
/// facts. ADCore holds no numbers.
public struct Desk: Hashable, Codable, Sendable, Identifiable {
    public let id: DeskID
    /// The pack that declares the desk ("us" for USCIS, "us-fl-miamidade" for county 311).
    public let regionPack: RegionPackID
    public let contactFacts: [FactID]

    public init(id: DeskID, regionPack: RegionPackID, contactFacts: [FactID] = []) {
        self.id = id
        self.regionPack = regionPack
        self.contactFacts = contactFacts
    }
}
