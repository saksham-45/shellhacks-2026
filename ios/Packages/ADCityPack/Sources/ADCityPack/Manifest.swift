import Foundation
import ADCore

/// A question a pack can answer, dotted lowercase, e.g. "trash.schedule", "government.which".
public struct Question: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

/// Where a pack sits in the nesting.
public enum RegionLevel: String, Hashable, Codable, Sendable, CaseIterable {
    case country, state, county, city
}

/// What decides that a pin is inside the pack. Evaluated on the server; the phone only reads the resulting
/// pack ids (it does no point-in-polygon).
public struct PackBoundary: Hashable, Codable, Sendable {
    /// "always" | "any_child" | "fact_ok" | "fact_equals"
    public var method: String
    public var fact: FactID?
    public var value: String?

    public init(method: String, fact: FactID? = nil, value: String? = nil) {
        self.method = method
        self.fact = fact
        self.value = value
    }
}

/// One fact id an adapter can emit, with its topic tags (Research's vocabulary, research/topics.yaml).
/// Decodes from an object `{"id": ..., "topics": [...]}` or a bare id string.
public struct AdapterFact: Hashable, Codable, Sendable {
    public var id: FactID
    public var topics: [String]

    public init(id: FactID, topics: [String] = []) {
        self.id = id
        self.topics = topics
    }

    private enum CodingKeys: String, CodingKey { case id, topics }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let id = try? single.decode(FactID.self) {
            self.init(id: id)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(FactID.self, forKey: .id), topics: try c.decodeIfPresent([String].self, forKey: .topics) ?? [])
    }
}

/// A deterministic adapter declared by a pack (GIS layer, GTFS feed, ...). Runs on the server.
public struct AdapterDescriptor: Hashable, Codable, Sendable {
    public var id: String
    /// Questions this adapter answers.
    public var answers: [Question]
    /// Source ids (research/sources.yaml) the adapter reads.
    public var sources: [String]
    /// The desk its not-applicable, unavailable and unsourced answers hand over to. Optional for old manifests.
    public var desk: DeskID?
    /// Every fact id the adapter can emit (ranked lists spelled out as .1, .2, .3). Empty for old manifests.
    public var facts: [AdapterFact]

    public init(id: String, answers: [Question], sources: [String], desk: DeskID? = nil, facts: [AdapterFact] = []) {
        self.id = id
        self.answers = answers
        self.sources = sources
        self.desk = desk
        self.facts = facts
    }

    private enum CodingKeys: String, CodingKey { case id, answers, sources, desk, facts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  answers: try c.decode([Question].self, forKey: .answers),
                  sources: try c.decode([String].self, forKey: .sources),
                  desk: try c.decodeIfPresent(DeskID.self, forKey: .desk),
                  facts: try c.decodeIfPresent([AdapterFact].self, forKey: .facts) ?? [])
    }
}

/// Manifest shipped with every pack (server/regionpacks/<id>/manifest.json). A new place is data plus adapters.
/// `level`, `boundary`, per-adapter `desk`/`facts` and `desksPlaceholder` are optional extensions
/// (ARCHITECTURE.md §12), so the skeleton's manifests still decode.
public struct RegionPackManifest: Hashable, Codable, Sendable {
    public var id: RegionPackID
    /// Parent pack id; nil only for a country.
    public var parent: RegionPackID?
    public var level: RegionLevel?
    public var boundary: PackBoundary?
    public var adapters: [AdapterDescriptor]
    public var sources: [String]
    /// Desk ids declared by this pack. Ids only: phone, address and hours come from `<desk-id>.*` ledger facts.
    public var desks: [DeskID]
    /// True while the desk ids are placeholders (myAD Research posts the final ids).
    public var desksPlaceholder: Bool?
    /// BCP-47 tags the pack's desks and content support.
    public var languages: [String]

    public init(id: RegionPackID, parent: RegionPackID?, level: RegionLevel? = nil, boundary: PackBoundary? = nil,
                adapters: [AdapterDescriptor], sources: [String], desks: [DeskID], desksPlaceholder: Bool? = nil,
                languages: [String]) {
        self.id = id
        self.parent = parent
        self.level = level
        self.boundary = boundary
        self.adapters = adapters
        self.sources = sources
        self.desks = desks
        self.desksPlaceholder = desksPlaceholder
        self.languages = languages
    }

    private enum CodingKeys: String, CodingKey {
        case id, parent, level, boundary, adapters, sources, desks, languages
        case desksPlaceholder = "desks_placeholder"
    }

    public func answers(_ question: Question) -> Bool {
        adapters.contains { $0.answers.contains(question) }
    }

    /// Fact ids this pack emits for the question, in manifest order.
    public func factIDs(answering question: Question) -> [FactID] {
        adapters.filter { $0.answers.contains(question) }.flatMap { $0.facts.map(\.id) }
    }

    /// The adapter that declares the fact id.
    public func adapter(emitting fact: FactID) -> AdapterDescriptor? {
        adapters.first { $0.facts.contains { $0.id == fact } }
    }
}
