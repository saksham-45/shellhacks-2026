import Foundation
import ADCore
import ADLocale

/// Which engine produced or will produce speech: "apple.sfspeech", "apple.avspeech",
/// "server.proxy", "stub".
public struct EngineID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Where audio or text goes. `.server` engines send data off the phone (through OUR proxy,
/// D7) and are used only with explicit consent, online, and never after "never send my voice".
public enum EngineLocation: Hashable, Sendable {
    case onDevice
    case server

    public var requiresConsent: Bool { self == .server }
}

/// The person's privacy choices plus connectivity, read at the moment of use.
public struct VoicePrivacy: Hashable, Sendable {
    /// They said yes to the one-time "your voice goes through our server" question.
    public var cloudVoiceConsent: Bool
    /// The permanent "never send my voice or card text to our server" switch. Wins over both
    /// consents: it blocks server listening AND server read-aloud.
    public var neverSendVoice: Bool
    public var isOnline: Bool
    /// They said yes to `voice.consent.readAloud` ("the app sends the card's words to our
    /// server"). Governs server read-aloud (ht TTS) only; `cloudVoiceConsent` governs listening.
    public var readAloudConsent: Bool

    public init(cloudVoiceConsent: Bool = false, neverSendVoice: Bool = false, isOnline: Bool = true,
                readAloudConsent: Bool = false) {
        self.cloudVoiceConsent = cloudVoiceConsent
        self.neverSendVoice = neverSendVoice
        self.isOnline = isOnline
        self.readAloudConsent = readAloudConsent
    }

    /// Server LISTENING (speech-to-text): voice-input consent.
    public func allows(_ location: EngineLocation) -> Bool {
        switch location {
        case .onDevice: true
        case .server: cloudVoiceConsent && !neverSendVoice && isOnline
        }
    }

    /// Server READ-ALOUD (text-to-speech): read-aloud consent.
    public func allowsReadAloud(_ location: EngineLocation) -> Bool {
        switch location {
        case .onDevice: true
        case .server: readAloudConsent && !neverSendVoice && isOnline
        }
    }
}

/// A push-to-talk recording on disk.
public struct RecordedAudio: Hashable, Sendable {
    public let fileURL: URL
    public let duration: TimeInterval
    public init(fileURL: URL, duration: TimeInterval) {
        self.fileURL = fileURL
        self.duration = duration
    }
}

/// One engine's transcript, in the language the engine was ASKED to listen in (per-locale
/// engines) or claims. Never trusted alone for Creole: text scoring decides.
public struct Transcript: Hashable, Sendable {
    public let text: String
    public let language: Locale.Language
    public let confidence: Double?
    public let engine: EngineID
    public init(text: String, language: Locale.Language, confidence: Double?, engine: EngineID) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.engine = engine
    }
}

/// The only languages speech may be identified as: {es, en, ht} plus the think-in language,
/// deduplicated by language code. Never open-ended, so French can never come out.
public struct LanguageCandidates: Hashable, Sendable {
    public let languages: [Locale.Language]

    public init(thinkIn: Locale.Language?) {
        var out = SurfaceLanguage.allCases.map(\.language)
        if let t = thinkIn, !out.contains(where: { $0.hasSameLanguageCode(as: t) }) {
            out.append(Locale.Language(identifier: t.minimalIdentifier))
        }
        languages = out
    }

    /// The candidate with the same language code, or nil (fr, fr-HT, pt... -> nil).
    public func candidate(for language: Locale.Language) -> Locale.Language? {
        languages.first { $0.hasSameLanguageCode(as: language) }
    }

    public func contains(_ language: Locale.Language) -> Bool { candidate(for: language) != nil }
}

/// Speech in, finished: the transcript and the language of THIS sentence (the reply follows it).
public struct Recognition: Hashable, Sendable {
    public let transcript: String
    /// Always one of the candidates.
    public let language: Locale.Language
    public let confidence: Double
    public let engine: EngineID
    /// Show the transcript and wait for a yes before acting. Always true for Creole (server
    /// STT, unmeasured accuracy) and whenever the language call was close.
    public let needsConfirmation: Bool
    /// Set when only a voice COMMAND was accepted (a key from contracts/intent/command_keys.json,
    /// e.g. "switch_language_es"): the on-device es/en fallback on the Creole path. Always with
    /// `needsConfirmation`.
    public let command: String?

    public init(transcript: String, language: Locale.Language, confidence: Double, engine: EngineID, needsConfirmation: Bool,
                command: String? = nil) {
        self.transcript = transcript
        self.language = language
        self.confidence = confidence
        self.engine = engine
        self.needsConfirmation = needsConfirmation
        self.command = command
    }

    /// Wire form for `Utterance.language` (ARCHITECTURE.md §13.2): plain BCP-47.
    public var bcp47: String { language.minimalIdentifier }
    public var surface: SurfaceLanguage? { SurfaceLanguage(language) }
}

/// Why nothing usable was heard. Each maps to a catalog key shown in the surface language.
public enum ListenUnavailable: Hashable, Sendable {
    /// Creole listening needs the one-time server consent (ask, then retry).
    case consentRequired(Locale.Language)
    /// The person switched on "never send my voice": tap UI only for this language.
    case neverSendVoice(Locale.Language)
    /// The server engine is needed and the phone is offline.
    case offline(Locale.Language)
    /// No engine can listen in this language here.
    case noEngine(Locale.Language)
    case nothingHeard

    public var messageKey: StringKey {
        switch self {
        case .consentRequired: VoiceKey.consentCloud
        case .neverSendVoice, .noEngine: VoiceKey.noSpeechIn
        case .offline: VoiceKey.creoleNeedsInternet
        case .nothingHeard: VoiceKey.notHeard
        }
    }

    /// The notice to show. On the ht surface, when on-device es/en commands still work
    /// (`SpeechInputRouter.commandsOnlyAvailable()`), "no engine" and "never send my voice" say
    /// so (`voice.creole.commandsOnly`, built by `VoiceKey.creoleCommandsOnlyNotice`) instead of
    /// only "use the buttons". Consent and offline keep their own notice: it names the fix.
    public func messageKey(surface: SurfaceLanguage, commandsOnlyAvailable: Bool) -> StringKey {
        switch self {
        case .noEngine(let l), .neverSendVoice(let l):
            surface == .ht && commandsOnlyAvailable && SurfaceLanguage(l) == .ht ? VoiceKey.creoleCommandsOnly : messageKey
        default: messageKey
        }
    }
}

public enum RecognitionOutcome: Hashable, Sendable {
    case heard(Recognition)
    case unavailable(ListenUnavailable)
}

/// What a listener needs to know at the moment of listening.
public struct ListenContext: Hashable, Sendable {
    public var surface: SurfaceLanguage
    public var thinkIn: Locale.Language
    /// The explicit "Mwen pale Kreyòl" setting: listen for Creole first whatever the surface.
    public var prefersCreole: Bool
    /// The language of the last sentence heard, if any (the mic remembers it).
    public var lastHeard: Locale.Language?
    public var privacy: VoicePrivacy

    public init(surface: SurfaceLanguage, thinkIn: Locale.Language, prefersCreole: Bool = false,
                lastHeard: Locale.Language? = nil, privacy: VoicePrivacy = VoicePrivacy()) {
        self.surface = surface
        self.thinkIn = thinkIn
        self.prefersCreole = prefersCreole
        self.lastHeard = lastHeard
        self.privacy = privacy
    }

    public var candidates: LanguageCandidates { LanguageCandidates(thinkIn: thinkIn) }

    /// The language to listen for first: explicit Creole setting or Creole surface -> ht;
    /// else the last sentence's language; else the surface.
    public var prior: Locale.Language {
        if prefersCreole || surface == .ht { return SurfaceLanguage.ht.language }
        if let last = lastHeard, let c = candidates.candidate(for: last) { return c }
        return surface.language
    }
}

/// Speak in the language of the last sentence (plans: "speech in and speech out follow the
/// sentence just spoken"). The surface never changes because of voice.
public enum ReplyLanguagePolicy {
    public static func replyLanguage(for heard: Recognition?, surface: SurfaceLanguage) -> Locale.Language {
        heard?.language ?? surface.language
    }
}
