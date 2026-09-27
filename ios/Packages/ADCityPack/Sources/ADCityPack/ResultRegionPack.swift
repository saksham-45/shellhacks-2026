import Foundation
import ADCore

/// A pack that answers from server results (live responses, or the bundled demo fixtures). Membership and
/// values both come from the server's result for the pin; nothing is computed on the phone.
public struct ResultRegionPack: RegionPack {
    public let manifest: RegionPackManifest
    public let pins: [RegionPinAnswers]

    public init(manifest: RegionPackManifest, pins: [RegionPinAnswers]) {
        self.manifest = manifest
        self.pins = pins
    }

    public func contains(_ pin: Pin) async throws -> Bool {
        pins.first { $0.matches(pin) }?.packIDs.contains(manifest.id) ?? false
    }

    public func answer(_ question: Question, at pin: Pin) async throws -> [FactOutcome] {
        guard let answers = pins.first(where: { $0.matches(pin) }), answers.packIDs.contains(manifest.id) else { return [] }
        let byID = Dictionary(answers.results.filter { $0.pack == manifest.id }.map { ($0.factID, $0) },
                              uniquingKeysWith: { first, _ in first })
        return manifest.factIDs(answering: question).compactMap { byID[$0] }.map(RegionOutcomeMapper.outcome(for:))
    }
}

/// The demo data bundled for offline use: the four manifests and both demo pins' answers.
public enum BundledRegionData {
    public enum LoadError: Error, Equatable { case missing(String) }

    public static func manifests() throws -> [RegionPackManifest] {
        try ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"].map { try decode(RegionPackManifest.self, "Manifests", $0) }
    }

    /// Demo pins in a stable order: "pin-sw137" (unincorporated), "pin-nw1st" (City of Miami).
    public static func demoPins() throws -> [RegionPinAnswers] {
        try ["pin-sw137", "pin-nw1st"].map { try decode(RegionPinAnswers.self, "Fixtures", $0) }
    }

    /// A registry over the bundled demo answers.
    public static func demoRegistry() throws -> RegionPackRegistry {
        let pins = try demoPins()
        return RegionPackRegistry(packs: try manifests().map { ResultRegionPack(manifest: $0, pins: pins) })
    }

    static func decode<T: Decodable>(_ type: T.Type, _ folder: String, _ name: String) throws -> T {
        guard let dir = Bundle.module.url(forResource: folder, withExtension: nil) else { throw LoadError.missing(folder) }
        let url = dir.appendingPathComponent("\(name).json")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
