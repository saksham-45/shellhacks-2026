import Foundation
import ADCore

/// The offline ledger slice the Fee Check and Listing Check beats read (Resources/Checks/check-ledger.json,
/// written by server/regionpacks/scripts/export_fixtures.py from myAD Research's verified rows).
/// Rows that are not verified ship with no value; every fact is rebuilt through ADCore's validating `Fact` init,
/// so a "verified" row missing its source, quote or date fails to load instead of showing.
public struct CheckLedger: Sendable {
    public struct DeskEntry: Hashable, Sendable {
        public let desk: Desk
        /// Desk display names by language code ("es", "en", "ht") from content/desks.yaml.
        public let names: [String: String]
    }

    public let facts: [FactID: Fact]
    public let desks: [DeskID: DeskEntry]

    public func fact(_ id: String) -> Fact? { facts[FactID(rawValue: id)] }
    public func desk(_ id: String) -> DeskEntry? { desks[DeskID(rawValue: id)] }

    /// The value the screen may show, nil when the row is unsourced or absent.
    public func value(_ id: String) -> FactValue? { fact(id)?.displayValue }

    public static func bundled() throws -> CheckLedger {
        guard let url = Bundle.module.url(forResource: "check-ledger", withExtension: "json", subdirectory: "Checks") else {
            throw BundledRegionData.LoadError.missing("Checks/check-ledger.json")
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> CheckLedger {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var facts: [FactID: Fact] = [:]
        for row in wire.facts {
            let id = FactID(rawValue: row.id)
            facts[id] = try Fact(
                id: id,
                value: row.value,
                source: row.source.map { Source(id: SourceID(rawValue: $0.id), url: $0.url, publisher: $0.publisher) },
                quote: row.quote,
                quoteLanguage: row.quoteLanguage.map { Locale.Language(identifier: $0) },
                retrievedAt: RegionDates.timestamp(row.retrievedAt),
                status: row.status,
                checkEveryDays: row.checkEveryDays)
        }
        var desks: [DeskID: DeskEntry] = [:]
        for d in wire.desks {
            let desk = Desk(id: DeskID(rawValue: d.id), regionPack: RegionPackID(rawValue: d.pack), contactFacts: d.contactFacts.map { FactID(rawValue: $0) })
            desks[desk.id] = DeskEntry(desk: desk, names: d.names)
        }
        return CheckLedger(facts: facts, desks: desks)
    }

    private struct Wire: Decodable {
        struct Row: Decodable {
            struct Src: Decodable { let id: String; let url: URL; let publisher: String }
            let id: String
            let status: FactStatus
            let value: FactValue?
            let source: Src?
            let quote: String?
            let quoteLanguage: String?
            let retrievedAt: String?
            let checkEveryDays: Int?
            private enum CodingKeys: String, CodingKey {
                case id, status, value, source, quote
                case quoteLanguage = "quote_language", retrievedAt = "retrieved_at", checkEveryDays = "check_every_days"
            }
        }
        struct DeskRow: Decodable {
            let id: String
            let pack: String
            let names: [String: String]
            let contactFacts: [String]
            private enum CodingKeys: String, CodingKey { case id, pack, names, contactFacts = "desk_facts" }
        }
        let facts: [Row]
        let desks: [DeskRow]
    }
}

/// Fills a localized template ("%1$@", "%2$@", or "%@") with already-formatted arguments. Pure, so tests can render
/// every language straight from ADCityPack.xcstrings on Linux, where the catalog is not compiled.
public enum CheckTemplate {
    public static func fill(_ template: String, _ args: [String]) -> String {
        var out = template
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        if let a = args.first { out = out.replacingOccurrences(of: "%@", with: a) }
        return out
    }
}
