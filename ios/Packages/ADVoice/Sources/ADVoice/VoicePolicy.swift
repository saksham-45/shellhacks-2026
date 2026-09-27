import Foundation
import ADCore
import ADLocale

/// Honest "no voice" result: the text stays on screen with a notice in its language, and
/// other-language audio is offered only as labeled choices (never played automatically).
public struct UnavailableSpeech: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// No acceptable voice for the language.
        case noVoice
        /// The text is fallback English for a missing es/ht string. Not read automatically; the
        /// UI offers `VoiceKey.listenInEnglish` and replays with `allowEnglishFallback: true`.
        case untranslatedFallback
        /// The segment is a missing-string marker (`⟦table:key⟧`): never read aloud.
        case missingText
    }
    public let language: Locale.Language
    public let notice: StringKey
    /// Surfaces whose version of the same text may be offered as "Listen in Spanish/English".
    public let labeledAlternatives: [SurfaceLanguage]
    public let reason: Reason

    public init(language: Locale.Language, notice: StringKey, labeledAlternatives: [SurfaceLanguage], reason: Reason = .noVoice) {
        self.language = language
        self.notice = notice
        self.labeledAlternatives = labeledAlternatives
        self.reason = reason
    }
}

public enum SpeechRoute: Hashable, Sendable {
    case prerendered(PrerenderedClip)
    case voice(VoiceInfo)
    case unavailable(UnavailableSpeech)
}

/// Speech-out rules. A voice is acceptable only on an exact language match (same ISO 639
/// code): a French voice (fr-FR, fr-CA, fr-HT) is never used for Creole, and an es/en voice
/// never reads text in another language.
///
/// Order for ht (Creole report §7.1): bundled prerendered clip -> server TTS (online and
/// consented) -> `.unavailable`. For es/en: prerendered -> on-device voice -> `.unavailable`
/// (es/en never go to the server). Think-in languages: on-device voice -> server TTS if
/// consented -> `.unavailable`.
public enum VoicePolicy {
    public static func accepts(_ voice: VoiceInfo, for language: Locale.Language) -> Bool {
        voice.language.hasSameLanguageCode(as: language)
    }

    /// `text` is the exact segment text; a clip is used only if `PrerenderedClip.verified` accepts
    /// it (reviewed, same language code, hash of `text`). No text means no clip.
    public static func route(for language: Locale.Language, offers: [VoiceInfo], prerendered: PrerenderedClip?,
                             text: String? = nil, serverAvailable: Bool? = nil, privacy: VoicePrivacy) -> SpeechRoute {
        if let text, let clip = PrerenderedClip.verified(prerendered, language: language, text: text) { return .prerendered(clip) }
        let acceptable = offers.filter { accepts($0, for: language) }
        let surface = SurfaceLanguage(language)
        let onDevice = acceptable.filter { $0.location == .onDevice }.max { $0.quality < $1.quality }
        let server = acceptable.first { $0.location == .server }
        switch surface {
        case .ht?:
            if let v = onDevice { return .voice(v) }   // none on Apple today; allowed if a real ht voice appears
            if let v = server, privacy.allowsReadAloud(.server) { return .voice(v) }
        case .es?, .en?, .pt?, .fr?, .ar?, .zh?, .ru?, .tl?, .vi?:
            if let v = onDevice { return .voice(v) }
            if let v = server, privacy.allowsReadAloud(.server) { return .voice(v) }
        case nil:
            if let v = onDevice { return .voice(v) }
            if let v = server, privacy.allowsReadAloud(.server) { return .voice(v) }
        }
        return .unavailable(unavailable(language, privacy: privacy, serverAvailable: serverAvailable ?? (server != nil)))
    }

    /// `serverAvailable`: a server voice for the language is configured (offline) or offered
    /// (online). Without one, consent or internet would not help, so the notice is the Creole one.
    static func unavailable(_ language: Locale.Language, privacy: VoicePrivacy, serverAvailable: Bool) -> UnavailableSpeech {
        let isCreole = SurfaceLanguage(language) == .ht
        let notice: StringKey
        if !isCreole {
            notice = VoiceKey.unavailable
        } else if privacy.neverSendVoice || !serverAvailable {
            notice = VoiceKey.unavailableCreole
        } else if !privacy.readAloudConsent {
            // No read-aloud consent (online or offline): its question is the one action that fixes it.
            notice = VoiceKey.consentReadAloud
        } else if !privacy.isOnline {
            notice = VoiceKey.creoleNeedsInternet
        } else {
            notice = VoiceKey.unavailableCreole
        }
        let alternatives: [SurfaceLanguage] = [.es, .en].filter { $0 != SurfaceLanguage(language) }
        return UnavailableSpeech(language: language, notice: notice, labeledAlternatives: alternatives)
    }
}

/// Result of speaking: one outcome per language segment. `.unavailable` means that segment was
/// NOT read (shown only, with the notice).
public enum SegmentOutcome: Hashable, Sendable {
    case played(SpeechRoute)
    case unavailable(UnavailableSpeech)
    case failed(String)
    /// `stop()` was called before or while this segment was read; it was not (fully) read.
    case stopped
}

public struct SynthesisResult: Hashable, Sendable {
    public let segments: [SegmentOutcome]
    /// The first unavailable segment, if any (drives the notice).
    public var unavailable: UnavailableSpeech? {
        segments.lazy.compactMap { if case .unavailable(let u) = $0 { u } else { nil } }.first
    }
    /// Every distinct notice for the unavailable segments, in order (announce them all, e.g. a
    /// fallback title AND a missing desk).
    public var notices: [UnavailableSpeech] {
        var seen = Set<StringKey>()
        return segments.compactMap { if case .unavailable(let u) = $0, seen.insert(u.notice).inserted { u } else { nil } }
    }
    /// True when there was nothing to say (empty text). Never "fully spoken".
    public var isEmpty: Bool { segments.isEmpty }
    public var isFullySpoken: Bool { !segments.isEmpty && segments.allSatisfy { if case .played = $0 { true } else { false } } }
    /// True when `stop()` cut the text short.
    public var wasStopped: Bool { segments.contains { if case .stopped = $0 { true } else { false } } }
}

/// One read, issued only by `VoiceSpeaker.beginRead()` (so a made-up id can't skip superseding).
public struct ReadToken: Hashable, Sendable {
    let id: Int
    init(id: Int) { self.id = id }
}

/// Speech out. Tries the prerendered clip for a catalog key first, then voices by policy.
public actor VoiceSpeaker {
    let synthesizers: [any SpeechSynthesizing]
    let prerendered: (any PrerenderedAudioLibrary)?
    let player: (any AudioClipPlaying)?
    private var generation = 0
    private var stoppedGeneration = 0
    /// Read in progress, if any.
    private var reading: Int?
    var startListener: (any PlaybackStartListener)?

    /// Told when the first segment of a read starts (e.g. a `PlaybackStopper`, for its grace window).
    public func setStartListener(_ listener: (any PlaybackStartListener)?) { startListener = listener }

    public init(synthesizers: [any SpeechSynthesizing], prerendered: (any PrerenderedAudioLibrary)? = nil,
                player: (any AudioClipPlaying)? = nil) {
        self.synthesizers = synthesizers
        self.prerendered = prerendered
        self.player = player
    }

    /// Decides without speaking (Settings "what works" screen, tests).
    public func route(_ segment: SpokenText.Segment, sourceKey: StringKey?, privacy: VoicePrivacy) async -> SpeechRoute {
        let clip = sourceKey.flatMap { prerendered?.clip(for: $0, language: segment.language, text: segment.text) }
        var offers: [VoiceInfo] = []
        // A server is asked for its voices only when read-aloud is allowed (consent, online, not
        // never-send): no contact with the server before consent. Otherwise decide from
        // configuration alone.
        let mayAskServer = privacy.allowsReadAloud(.server)
        for s in synthesizers where s.isConfigured && (s.location == .onDevice || mayAskServer) {
            offers += await s.voices(for: segment.language)
        }
        let serverConfigured = synthesizers.contains { $0.location == .server && $0.isConfigured }
        let serverAvailable = mayAskServer
            ? offers.contains { $0.location == .server && VoicePolicy.accepts($0, for: segment.language) }
            : serverConfigured
        return VoicePolicy.route(for: segment.language, offers: offers, prerendered: player == nil ? nil : clip,
                                 text: segment.text, serverAvailable: serverAvailable, privacy: privacy)
    }

    /// Speaks each segment in its own language or reports it unavailable. `sourceKey` is the
    /// catalog key when the text is one static string (enables prerendered clips).
    ///
    /// Per segment: a missing-string marker is never read (`.unavailable`, reason `.missingText`);
    /// fallback English (a missing es/ht string) is not read unless `allowEnglishFallback` (reason
    /// `.untranslatedFallback`, with a labeled "Listen in English" alternative). Every other
    /// segment is read. `language` is the requested surface (required: notices and the
    /// "Listen in English" prompt are in it). Segments that are only spaces or punctuation are
    /// skipped (no outcome). `stop()` ends the whole text: the interrupted and remaining segments
    /// come back `.stopped`.
    ///
    /// A new read supersedes the one in progress (it comes back `.stopped`), so two cards never
    /// interleave. To make a Stop that lands before the first segment count, call `beginRead()`
    /// when the person taps Read and pass the token as `readID`.
    public func speak(_ text: SpokenText, sourceKey: StringKey? = nil, privacy: VoicePrivacy,
                      language: SurfaceLanguage, allowEnglishFallback: Bool = false,
                      readID: ReadToken? = nil) async -> SynthesisResult {
        let mine: Int
        if let readID { mine = readID.id } else { mine = await beginRead().id }
        defer { if reading == mine { reading = nil } }
        let requestedIsEnglish = language == .en
        let requested = language.language
        // A segment of only spaces or punctuation (" . ", "¿?") is never sent to a voice.
        let segments = text.segments.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
        var out: [SegmentOutcome] = []
        let singleSegment = segments.count == 1
        var started = false
        func stopRest() { out += Array(repeating: .stopped, count: segments.count - out.count) }
        for segment in segments {
            if stoppedGeneration >= mine { stopRest(); break }
            if segment.isMissing {
                out.append(.unavailable(UnavailableSpeech(language: requested, notice: VoiceKey.textMissing,
                                                          labeledAlternatives: [], reason: .missingText)))
                continue
            }
            if segment.isFallback, !requestedIsEnglish, !allowEnglishFallback {
                out.append(.unavailable(UnavailableSpeech(language: requested, notice: ADLocaleKey.fallbackEnglishHint,
                                                          labeledAlternatives: [.en], reason: .untranslatedFallback)))
                continue
            }
            let route = await route(segment, sourceKey: singleSegment ? sourceKey : nil, privacy: privacy)
            if stoppedGeneration >= mine { stopRest(); break }
            if case .unavailable = route {} else if !started {
                started = true
                await startListener?.playbackStarted()
            }
            do {
                switch route {
                case .prerendered(let clip):
                    try await player?.play(clip)
                case .voice(let v):
                    guard let engine = synthesizers.first(where: { $0.id == v.engine }) else { out.append(.failed("no engine \(v.engine)")); continue }
                    try await engine.speak(segment, voice: v)
                case .unavailable(let u):
                    out.append(.unavailable(u))
                    continue
                }
                if stoppedGeneration >= mine { stopRest(); break }
                out.append(.played(route))
            } catch {
                if stoppedGeneration >= mine { stopRest(); break }
                out.append(.failed(String(describing: error)))
            }
        }
        return SynthesisResult(segments: out)
    }

    /// Starts a read: supersedes (stops) any read in progress and returns this read's token. A
    /// `stop()` after this and before `speak(readID:)` makes the whole read `.stopped`.
    public func beginRead() async -> ReadToken {
        let wasReading = reading != nil
        stoppedGeneration = generation
        generation += 1
        let id = generation
        reading = id
        if wasReading {
            for s in synthesizers { await s.stop() }
            await player?.stop()
        }
        return ReadToken(id: id)
    }

    /// Stops the text being read, including its remaining segments.
    public func stop() async {
        stoppedGeneration = generation
        for s in synthesizers { await s.stop() }
        await player?.stop()
    }
}
