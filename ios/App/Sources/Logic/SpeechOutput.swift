import Foundation

/// App speech output. The rule (ARCHITECTURE.md §13.z, docs/accessibility.md): text in Creole is never
/// read with a Spanish or English voice. When no voice exists for the text's language, `speak`
/// returns `.unavailable` and the app shows (and announces) the Creole notice instead.
public enum SpeakResult: Equatable, Sendable {
    case speaking(voice: String?)
    case unavailable(language: String)
}

@MainActor
public protocol SpeechOutput: AnyObject {
    /// Starts speaking `text` in `language` (BCP-47); `finished` runs when it ends or is stopped.
    func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void) -> SpeakResult
    func stop()
    /// Language codes (base, e.g. "es") this output has a real voice for.
    var voiceLanguages: Set<String> { get }
}

/// `-myadVoiceStub` / `-myadUITest`: records instead of speaking. Deterministic: it "speaks" until
/// stopped (so `a11y.card.stopReading` stays visible), and like iOS today it has no Creole voice.
@MainActor
public final class StubSpeechOutput: SpeechOutput {
    public private(set) var spoken: [(text: String, language: String)] = []
    public var voiceLanguages: Set<String> = ["es", "en"]
    private var pending: (@MainActor () -> Void)?

    public init() {}

    public func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void) -> SpeakResult {
        let base = String(language.prefix(2)).lowercased()
        guard voiceLanguages.contains(base) else { return .unavailable(language: language) }
        stop()
        spoken.append((text, language))
        pending = finished
        return .speaking(voice: "stub-\(base)")
    }

    public func stop() {
        let done = pending
        pending = nil
        done?()
    }
}
