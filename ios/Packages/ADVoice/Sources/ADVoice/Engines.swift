import Foundation
import ADCore
import ADLocale

/// Speech to text for one language at a time (Apple engines are per-locale; the server proxy
/// takes a language hint). Language identification is NOT the engine's job: it lives in
/// `LanguageIdentification`, because audio language ID labels Creole as French.
public protocol SpeechRecognizing: Sendable {
    var id: EngineID { get }
    var location: EngineLocation { get }
    func supports(_ language: Locale.Language) async -> Bool
    func transcribe(_ audio: RecordedAudio, language: Locale.Language) async throws -> Transcript
}

/// A voice an engine offers. `language` is the voice's REAL language (AVSpeechSynthesisVoice
/// .language), which `VoicePolicy` checks itself.
public struct VoiceInfo: Hashable, Sendable {
    public enum Quality: Int, Hashable, Sendable, Comparable {
        case compact, enhanced, premium
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    public let identifier: String
    public let language: Locale.Language
    public let quality: Quality
    public let engine: EngineID
    public let location: EngineLocation

    public init(identifier: String, language: Locale.Language, quality: Quality, engine: EngineID, location: EngineLocation) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
        self.engine = engine
        self.location = location
    }
}

/// Text to speech. Engines report what they CLAIM; the policy decides what is acceptable.
public protocol SpeechSynthesizing: Sendable {
    var id: EngineID { get }
    var location: EngineLocation { get }
    func voices(for language: Locale.Language) async -> [VoiceInfo]
    func speak(_ segment: SpokenText.Segment, voice: VoiceInfo) async throws
    func stop() async
    /// False when the engine cannot work at all (e.g. a server engine with no transport).
    /// Default: true.
    var isConfigured: Bool { get }
}

extension SpeechSynthesizing {
    public var isConfigured: Bool { true }
}

/// Plays a bundled audio file (AVAudioPlayer on Apple; a recorder in tests).
public protocol AudioClipPlaying: Sendable {
    func play(_ clip: PrerenderedClip) async throws
    func stop() async
}

/// Push-to-talk capture (AVAudioEngine on Apple, owned by the app for now).
public protocol AudioCapturing: Sendable {
    func start() async throws
    func stop() async throws -> RecordedAudio
}

public enum VoiceError: Error, Hashable, Sendable {
    case notConfigured(EngineID)
    case unsupportedLanguage(String)
    case notAuthorized
    case engineFailed(String)
}

// MARK: Server proxy (Creole speech-in and dynamic Creole speech-out)

/// Talks to OUR server's speech proxy (decision D7), which fronts the chosen STT/TTS provider
/// (to be picked by measured WER, Creole report §7.5). The app implements it (e.g. inside
/// ADAgentsClient); ADVoice has no URLs, provider SDKs, or keys. Languages are plain BCP-47.
public protocol SpeechProxyTransport: Sendable {
    func transcribe(audio: RecordedAudio, language: String) async throws -> (text: String, confidence: Double?)
    /// Returns a local audio file of `text` spoken in `language`.
    func synthesize(text: String, language: String) async throws -> URL
    /// BCP-47 languages the proxy can speak (its voices' real languages).
    func voiceLanguages() async throws -> [String]
}

/// Server-proxy engine. Without a transport (today: the server does not exist yet) it supports
/// nothing, so the policies fall back honestly instead of pretending.
public struct ServerProxySpeechEngine: SpeechRecognizing, SpeechSynthesizing {
    public let id: EngineID = "server.proxy"
    public let location: EngineLocation = .server
    let transport: (any SpeechProxyTransport)?
    let listenLanguages: [Locale.Language]
    let player: (any AudioClipPlaying)?

    /// `listenLanguages`: languages sent to the proxy for STT (default: Creole only; es/en stay
    /// on the phone, Creole report §7.2).
    public init(transport: (any SpeechProxyTransport)?, listenLanguages: [Locale.Language] = [SurfaceLanguage.ht.language],
                player: (any AudioClipPlaying)? = nil) {
        self.transport = transport
        self.listenLanguages = listenLanguages
        self.player = player
    }

    public func supports(_ language: Locale.Language) async -> Bool {
        transport != nil && listenLanguages.contains { $0.hasSameLanguageCode(as: language) }
    }

    public func transcribe(_ audio: RecordedAudio, language: Locale.Language) async throws -> Transcript {
        guard let transport else { throw VoiceError.notConfigured(id) }
        let r = try await transport.transcribe(audio: audio, language: language.minimalIdentifier)
        return Transcript(text: r.text, language: language, confidence: r.confidence, engine: id)
    }

    public func voices(for language: Locale.Language) async -> [VoiceInfo] {
        guard let transport, let langs = try? await transport.voiceLanguages() else { return [] }
        return langs.map { Locale.Language(identifier: $0) }
            .filter { $0.hasSameLanguageCode(as: language) }
            .map { VoiceInfo(identifier: "server.\($0.minimalIdentifier)", language: $0, quality: .premium, engine: id, location: .server) }
    }

    public func speak(_ segment: SpokenText.Segment, voice: VoiceInfo) async throws {
        guard let transport, let player else { throw VoiceError.notConfigured(id) }
        let url = try await transport.synthesize(text: segment.text, language: voice.language.minimalIdentifier)
        try await player.play(PrerenderedClip(key: nil, language: voice.language, contentHash: "", fileURL: url))
    }

    public func stop() async { await player?.stop() }

    /// No transport (today's wiring) means no server voice exists.
    public var isConfigured: Bool { transport != nil }
}

// MARK: Credentials (runtime only; nothing in the bundle, Info.plist, or any file in the tree)

public struct CloudService: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let speechProxy = CloudService(rawValue: "speech-proxy")
}

/// A short-lived bearer for OUR proxy, minted by our server at runtime. Never logged.
public struct Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let bearer: String
    public let expires: Date?
    public init(bearer: String, expires: Date?) {
        self.bearer = bearer
        self.expires = expires
    }
    public var description: String { "Credential(redacted)" }
    public var debugDescription: String { description }
}

/// Supplies credentials at runtime (the transport uses it). nil = not available -> the engine
/// reports unsupported.
public protocol CredentialProvider: Sendable {
    func credential(for service: CloudService) async throws -> Credential?
}
