import Foundation
import ADCore
import ADRouter

/// Reads the compiled content bundle (`Resources/Generated/cards.json`, written by
/// tools/build_content_bundle.py; byte copy of contracts/content/cards.json).
public struct CardBundle: Sendable {
    public var cards: [Card]
    public var utterances: [CardUtterances]
    public var isDemo: Bool

    struct Row: Decodable {
        let id: String
        let desk: String
        let scope: String
        let modes: [String]
        let region_pack: String
        let fact_refs: [String]
        let utterances: [String: [String]]
        let immigration: Bool
    }
    struct File: Decodable { let version: Int; let cards: [Row] }

    /// Content's cards if the bundle has any; otherwise the DEMO catalog, clearly marked.
    public static func load(from url: URL? = Bundle.main.url(forResource: "cards", withExtension: "json")) -> CardBundle {
        let rows = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(File.self, from: $0) }?.cards ?? []
        let cards = rows.compactMap { r -> Card? in
            try? Card(id: CardID(rawValue: r.id), regionPack: RegionPackID(rawValue: r.region_pack),
                      subject: r.scope == "household" ? .household : .person,
                      // The bundle has no hero topic yet (gap reported to Content): cards appear in
                      // lists and by voice, not as a stage hero.
                      heroTopic: nil,
                      modes: Set(r.modes.compactMap(Mode.init(rawValue:))),
                      isImmigrationContent: r.immigration,
                      desk: DeskID(rawValue: r.desk), facts: r.fact_refs.map { FactID(rawValue: $0) })
        }
        guard !cards.isEmpty else { return CardBundle(cards: DemoSeed.catalog, utterances: DemoSeed.utterances, isDemo: true) }
        return CardBundle(cards: cards,
                          utterances: rows.map { CardUtterances(cardID: CardID(rawValue: $0.id), phrases: $0.utterances) },
                          isDemo: false)
    }
}
