import Foundation
import ADCore
import ADLocale

/// How the app starts voice: live engines, or the stub for UI tests.
///
/// Launch arguments: `-myadVoiceStub` switches every engine to the stub (no microphone, no
/// network, no speech permission prompt). `-myadVoiceScript <name>` loads
/// `<name>.voicescript.json` and replays it, one step per push-to-talk.
public enum VoiceLaunchOptions: Hashable, Sendable {
    case live
    case stub(script: String?)

    public static func parse(_ arguments: [String]) -> VoiceLaunchOptions {
        guard arguments.contains("-myadVoiceStub") else { return .live }
        if let i = arguments.firstIndex(of: "-myadVoiceScript"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") {
            return .stub(script: arguments[i + 1])
        }
        return .stub(script: nil)
    }
}

/// A scripted voice session for no-touch UI tests and Linux script tests.
///
/// File: `<name>.voicescript.json`, looked up in the bundles you pass (the app bundle first,
/// then ADVoice's own `VoiceScripts/`). Format:
/// ```json
/// {
///   "name": "language-switch",
///   "review": { "state": "needs_review", "note": "Creole lines are unreviewed drafts" },
///   "steps": [
///     { "say": "en español", "language": "es",
///       "expect": { "command": "switch_language_es" } },
///     { "say": "¿y el peaje?", "language": "es", "confidence": 0.9,
///       "expect": { "command": null, "reply_language": "es", "speech": "spoken" } },
///     { "say": "li sa a", "language": "ht",
///       "expect": { "command": "read_this", "confirm": true, "speech": "unavailable" } }
///   ]
/// }
/// ```
/// - `say`: the transcript the stub "hears". `language`: the BCP-47 language the stub reports
///   as detected; must be es, en, ht or the think-in language set for the test (never fr).
/// - `confidence` (optional, default 1.0).
/// - `expect` (all optional): `command` is a key from contracts/intent/command_keys.json, or
///   null for an open question that goes to /v1/ask; `reply_language` is the language the answer
///   must be spoken/shown in; `speech` is "spoken" or "unavailable" (the stub voices speak es and
///   en only, like Apple today, so Creole is "unavailable" unless a clip or server voice is
///   configured); `confirm` is whether the transcript must be confirmed first (always true for ht).
/// Steps replay in order, one per push-to-talk; after the last step the stub hears nothing.
public struct VoiceScript: Hashable, Sendable, Decodable {
    public struct Expectation: Hashable, Sendable, Decodable {
        public var command: String?
        public var replyLanguage: String?
        public var speech: String?
        public var confirm: Bool?
        enum CodingKeys: String, CodingKey { case command, replyLanguage = "reply_language", speech, confirm }
    }
    public struct Step: Hashable, Sendable, Decodable {
        public var say: String
        public var language: String
        public var confidence: Double?
        public var expect: Expectation?
    }

    public var name: String
    public var steps: [Step]

    public init(data: Data) throws { self = try JSONDecoder().decode(VoiceScript.self, from: data) }

    public static func load(named name: String, bundles: [Bundle] = [.main]) throws -> VoiceScript {
        for bundle in bundles + [Bundle.module] {
            if let url = bundle.url(forResource: "\(name).voicescript", withExtension: "json", subdirectory: "VoiceScripts")
                ?? bundle.url(forResource: "\(name).voicescript", withExtension: "json") {
                return try VoiceScript(data: Data(contentsOf: url))
            }
        }
        throw VoiceError.notConfigured(EngineID(rawValue: "script:\(name)"))
    }

    /// Checks one step's actual results against its expectation; returns human-readable
    /// mismatches (empty = pass). Access's tests and the Linux script tests share it.
    public static func mismatches(_ step: Step, recognition: Recognition?, command: String?,
                                  replyLanguage: Locale.Language?, speech: SynthesisResult?) -> [String] {
        guard let e = step.expect else { return [] }
        var out: [String] = []
        if e.command != command, !(e.command == nil && command == nil) {
            out.append("'\(step.say)': command \(command ?? "nil") != expected \(e.command ?? "nil")")
        }
        if let want = e.replyLanguage, replyLanguage?.minimalIdentifier != Locale.Language(identifier: want).minimalIdentifier {
            out.append("'\(step.say)': reply language \(replyLanguage?.minimalIdentifier ?? "nil") != \(want)")
        }
        if let want = e.speech, let speech {
            let got = speech.unavailable == nil ? "spoken" : "unavailable"
            if got != want { out.append("'\(step.say)': speech \(got) != \(want)") }
        }
        if let want = e.confirm, recognition?.needsConfirmation != want {
            out.append("'\(step.say)': confirm \(recognition?.needsConfirmation.description ?? "nil") != \(want)")
        }
        return out
    }
}

/// Replays a `VoiceScript` as speech input. Reports each step's language as detected, but only
/// if it is a candidate: a script that says "fr" is heard as nothing, never as French.
public actor ScriptedSpeechInput: SpeechInput {
    let script: VoiceScript
    private var next = 0

    public init(script: VoiceScript) { self.script = script }

    public var remainingSteps: Int { script.steps.count - next }
    public var currentStep: VoiceScript.Step? { next > 0 && next <= script.steps.count ? script.steps[next - 1] : nil }

    public func listen(_ audio: RecordedAudio?, context: ListenContext) async -> RecognitionOutcome {
        guard next < script.steps.count else { return .unavailable(.nothingHeard) }
        let step = script.steps[next]
        next += 1
        guard let language = context.candidates.candidate(for: Locale.Language(identifier: step.language)) else {
            return .unavailable(.nothingHeard)
        }
        let isCreole = SurfaceLanguage(language) == .ht
        return .heard(Recognition(transcript: step.say, language: language, confidence: step.confidence ?? 1,
                                  engine: "stub", needsConfirmation: isCreole))
    }
}

/// Stub voices for `-myadVoiceStub`: es-US and en-US only, like Apple today, so the Creole
/// fallback path is exercised. Records what it would have said.
public actor StubSpeechSynthesizer: SpeechSynthesizing {
    public nonisolated let id: EngineID = "stub"
    public nonisolated let location: EngineLocation = .onDevice
    let offered: [Locale.Language]
    public private(set) var spoken: [SpokenText.Segment] = []

    public init(languages: [Locale.Language] = [Locale.Language(identifier: "es-US"), Locale.Language(identifier: "en-US")]) {
        offered = languages
    }

    public func voices(for language: Locale.Language) async -> [VoiceInfo] {
        offered.map { VoiceInfo(identifier: "stub.\($0.minimalIdentifier)", language: $0, quality: .enhanced, engine: id, location: .onDevice) }
    }

    public func speak(_ segment: SpokenText.Segment, voice: VoiceInfo) async throws {
        guard voice.language.hasSameLanguageCode(as: segment.language) else { throw VoiceError.unsupportedLanguage(segment.language.minimalIdentifier) }
        spoken.append(segment)
    }

    public func stop() async {}
}
