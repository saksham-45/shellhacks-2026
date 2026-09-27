import Foundation

/// Stable beat id. Must be one of the ids in contracts/beat/beats.json.
public struct BeatID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let coldOpen = BeatID("cold_open")
    public static let feeCheck = BeatID("fee_check")
    public static let deskCopilot = BeatID("desk_copilot")
    public static let warmHandoff = BeatID("warm_handoff")
    public static let familyVoiceNote = BeatID("family_voice_note")
    public static let abuelaMode = BeatID("abuela_mode")
    public static let listingCheck = BeatID("listing_check")
    public static let familyCouncil = BeatID("family_council")
}

/// A beat title in the three surface languages. `key` is the ADBeat catalog key
/// (`beat.<id>.title`); es/en/ht are the catalog values so a feature can show it without a Localizer.
public struct BeatTitle: Hashable, Sendable, Codable {
    public let key: String
    public let es: String
    public let en: String
    public let ht: String
    public init(key: String, es: String, en: String, ht: String) {
        self.key = key; self.es = es; self.en = en; self.ht = ht
    }
    /// `language` is a BCP-47 code: "es", "en" or "ht". Anything else gets en.
    public func text(for language: String) -> String {
        switch language { case "es": es; case "ht": ht; default: en }
    }
}

/// Which run the runner chose.
public enum BeatMode: String, Hashable, Sendable, Codable {
    /// The real app, live services.
    case live
    /// The saved output of the same scripted line, stored on the phone (not live; not necessarily a
    /// recording). Always shown with the replay chip (`isReplay == true`); never presented as live.
    case cachedReplay
}

/// What a finished run reports. The runner fills `mode` and `isReplay`; the beat fills the rest.
public struct BeatOutcome: Hashable, Sendable {
    public var beatID: BeatID
    public var mode: BeatMode
    /// Drives the visible "replay" chip. True whenever `mode == .cachedReplay`.
    public var isReplay: Bool { mode == .cachedReplay }
    /// True when the beat's conversation happened without a family member translating
    /// (it then bumps the "Conversaciones que Sofi no tuvo que traducir" counter).
    public var spareTheInterpreter: Bool
    /// Why a live run fell back to the replay, for the log only (never shown as a fact).
    public var fallbackReason: FallbackReason?

    public init(beatID: BeatID, mode: BeatMode, spareTheInterpreter: Bool, fallbackReason: FallbackReason? = nil) {
        self.beatID = beatID; self.mode = mode
        self.spareTheInterpreter = spareTheInterpreter; self.fallbackReason = fallbackReason
    }
}

public enum FallbackReason: Hashable, Sendable {
    case demoModeOn
    case liveTimedOut(seconds: Double)
    case liveFailed(String)
}

/// Passed to both runs. `language` is the surface language ("es", "en", "ht").
public struct BeatContext: Sendable {
    public var language: String
    public var thinkIn: String
    public init(language: String, thinkIn: String) { self.language = language; self.thinkIn = thinkIn }
}

/// One demo beat. A conforming type does the work; the App shows its view.
///
/// Rules (contracts/beat/README.md):
/// - `runLive` uses the real app; `runCachedReplay` plays the saved output of the same scripted line and
///   adds no new fact. Both return when the beat's visible moment is over. Payloads go through
///   `BeatOutputSink` (live: `publishUnlessCancelled`).
/// - Neither run bumps the counter itself: the runner calls `onComplete` exactly once per run.
/// - Both runs must honour Task cancellation (the Demo screen's stop / next). The runner does not rely on
///   it: at `liveTimeout` it cancels the live task, does not wait for it, and ignores a late result.
public protocol Beat: Sendable {
    var id: BeatID { get }
    var title: BeatTitle { get }
    /// Seconds the live run may take before the runner switches to the replay (nil: no limit).
    var liveTimeout: Double? { get }
    /// Whether finishing this beat counts toward the counter (the parent and grandparent beats).
    var countsTowardCounter: Bool { get }
    func runLive(_ context: BeatContext) async throws -> BeatOutcome
    func runCachedReplay(_ context: BeatContext) async throws -> BeatOutcome
}

public extension Beat {
    var liveTimeout: Double? { nil }
    var countsTowardCounter: Bool { true }
}
