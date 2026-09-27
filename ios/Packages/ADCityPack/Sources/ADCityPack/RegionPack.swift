import Foundation
import ADCore

/// One region pack: country, state, county, or city.
public protocol RegionPack: Sendable {
    var manifest: RegionPackManifest { get }
    /// True when the pin is inside this government's boundary. The phone does no point-in-polygon: packs
    /// answer from the server's result (`pack_ids`) for the pin.
    func contains(_ pin: Pin) async throws -> Bool
    /// Outcomes for the question at the pin: sourced facts, not applicable (e.g. county trash inside the City of
    /// Miami, deferring to the city fact), unsourced or unavailable with the desk. Never guesses.
    func answer(_ question: Question, at pin: Pin) async throws -> [FactOutcome]
}

/// Which pack answered a question at a pin, and which packs passed it on.
public struct QuestionResolution: Sendable {
    public let question: Question
    /// The pack whose outcomes stand. Nil when no applicable pack declares the question.
    public let owner: RegionPackID?
    public let outcomes: [FactOutcome]
    /// More local packs whose outcomes were all `notApplicable` (most local first).
    public let passedOver: [RegionPackID]
}

/// Resolves which packs apply to a pin and which pack owns each question.
public struct RegionPackRegistry: Sendable {
    public let packs: [any RegionPack]

    public init(packs: [any RegionPack]) { self.packs = packs }

    /// Nesting depth: country 0, state 1, county 2, city 3.
    public func depth(of id: RegionPackID) -> Int {
        var depth = 0
        var current = packs.first { $0.manifest.id == id }?.manifest.parent
        while let parentID = current {
            depth += 1
            current = packs.first { $0.manifest.id == parentID }?.manifest.parent
        }
        return depth
    }

    /// Packs that contain the pin, ordered country first, most local last.
    public func applicablePacks(for pin: Pin) async throws -> [any RegionPack] {
        var hits: [any RegionPack] = []
        for pack in packs where try await pack.contains(pin) {
            hits.append(pack)
        }
        return hits.sorted { depth(of: $0.manifest.id) < depth(of: $1.manifest.id) }
    }

    /// The most local applicable pack that declares an adapter for the question.
    public func owner(of question: Question, at pin: Pin) async throws -> (any RegionPack)? {
        try await applicablePacks(for: pin).last { $0.manifest.answers(question) }
    }

    /// Most local pack that declares the question wins. If every outcome it gives is `notApplicable`, the
    /// question falls through to its parent (the county defers to the city, never the other way). Any
    /// `unsourced` or `unavailable` outcome stops there and hands over that pack's desk: no silent fallback.
    public func resolve(_ question: Question, at pin: Pin) async throws -> QuestionResolution {
        var passed: [RegionPackID] = []
        var lastNotApplicable: [FactOutcome] = []
        for pack in try await applicablePacks(for: pin).reversed() where pack.manifest.answers(question) {
            let outcomes = try await pack.answer(question, at: pin)
            if outcomes.isEmpty || outcomes.allSatisfy(\.isNotApplicable) {
                passed.append(pack.manifest.id)
                if !outcomes.isEmpty { lastNotApplicable = outcomes }
                continue
            }
            return QuestionResolution(question: question, owner: pack.manifest.id, outcomes: outcomes, passedOver: passed)
        }
        return QuestionResolution(question: question, owner: nil, outcomes: lastNotApplicable, passedOver: passed)
    }
}

extension FactOutcome {
    var isNotApplicable: Bool {
        if case .notApplicable = self { return true }
        return false
    }
}
