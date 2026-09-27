import Foundation
import ADCore
import ADLocale
@testable import ADVoice

func lang(_ tag: String) -> Locale.Language { Locale.Language(identifier: tag) }

func voice(_ tag: String, _ quality: VoiceInfo.Quality = .enhanced, engine: EngineID = "fake",
           at location: EngineLocation = .onDevice) -> VoiceInfo {
    VoiceInfo(identifier: "\(engine).\(tag).\(quality)", language: lang(tag), quality: quality, engine: engine, location: location)
}

func clip(_ tag: String, key: String = "card.test.title") -> PrerenderedClip {
    PrerenderedClip(key: StringKey(key: key, table: "Cards"), language: lang(tag), contentHash: SHA256.hex(Data("Fatra".utf8)),
                    fileURL: URL(fileURLWithPath: "/dev/null/\(key).\(tag).m4a"), reviewed: true)
}

let consented = VoicePrivacy(cloudVoiceConsent: true, neverSendVoice: false, isOnline: true, readAloudConsent: true)

/// A synthesizer that offers the given voice languages from one location and records what it spoke.
actor FakeSynthesizer: SpeechSynthesizing {
    nonisolated let id: EngineID
    nonisolated let location: EngineLocation
    let offered: [Locale.Language]
    private(set) var spoken: [SpokenText.Segment] = []

    init(_ id: EngineID, location: EngineLocation, languages: [String]) {
        self.id = id
        self.location = location
        offered = languages.map(lang)
    }

    func voices(for language: Locale.Language) async -> [VoiceInfo] {
        offered.map { VoiceInfo(identifier: "\(id).\($0.minimalIdentifier)", language: $0, quality: .enhanced, engine: id, location: location) }
    }

    func speak(_ segment: SpokenText.Segment, voice: VoiceInfo) async throws { spoken.append(segment) }
    func stop() async {}
}

/// Records clips instead of playing them.
actor RecordingPlayer: AudioClipPlaying {
    private(set) var played: [PrerenderedClip] = []
    func play(_ clip: PrerenderedClip) async throws { played.append(clip) }
    func stop() async {}
}

/// Returns one clip for one key + language, whatever the text (hash checks are tested separately).
struct OneClipLibrary: PrerenderedAudioLibrary {
    let clip: PrerenderedClip
    func clip(for key: StringKey, language: Locale.Language, text: String) -> PrerenderedClip? {
        key == clip.key && language.hasSameLanguageCode(as: clip.language) ? clip : nil
    }
}

/// A recognizer that "hears" a fixed transcript per language and counts every call.
actor FakeRecognizer: SpeechRecognizing {
    nonisolated let id: EngineID
    nonisolated let location: EngineLocation
    let heard: [String: (text: String, confidence: Double)]
    private(set) var asked: [String] = []

    init(_ id: EngineID, location: EngineLocation, heard: [String: (text: String, confidence: Double)]) {
        self.id = id
        self.location = location
        self.heard = heard
    }

    func supports(_ language: Locale.Language) async -> Bool {
        heard.keys.contains { lang($0).hasSameLanguageCode(as: language) }
    }

    func transcribe(_ audio: RecordedAudio, language: Locale.Language) async throws -> Transcript {
        asked.append(language.minimalIdentifier)
        guard let h = heard.first(where: { lang($0.key).hasSameLanguageCode(as: language) })?.value else {
            throw VoiceError.unsupportedLanguage(language.minimalIdentifier)
        }
        return Transcript(text: h.text, language: language, confidence: h.confidence, engine: id)
    }
}

let recording = RecordedAudio(fileURL: URL(fileURLWithPath: "/dev/null/ptt.m4a"), duration: 2)
