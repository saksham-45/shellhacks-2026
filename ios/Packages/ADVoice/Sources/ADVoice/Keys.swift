import Foundation
import ADCore
import ADLocale

/// Keys ADVoice owns, in `Resources/ADVoice.xcstrings` (table "ADVoice").
public enum VoiceKey {
    public static let table = "ADVoice"
    static func k(_ key: String) -> StringKey { StringKey(key: key, table: table) }

    public static let unavailable = k("voice.unavailable")                  // no voice for this language
    public static let unavailableCreole = k("voice.unavailable.creole")     // no Creole voice right now
    public static let creoleVoiceOverLimit = k("voice.creole.voiceOverLimit") // notice line: VoiceOver may use another voice for Kreyòl
    public static let creoleNeedsInternet = k("voice.unavailable.offline_creole")
    public static let listenInSpanish = k("voice.listen_in.es")             // labeled choice, never automatic
    public static let listenInEnglish = k("voice.listen_in.en")
    public static let consentCloud = k("voice.consent.cloud")               // speech IN: your voice goes to our server
    public static let consentReadAloud = k("voice.consent.readAloud")       // speech OUT: the card's words go to our server
    public static let neverSendVoice = k("voice.consent.never")
    public static let confirmTranscript = k("voice.confirm_transcript")
    public static let answerIn = k("voice.answer_in")                       // "Answer in <autonym>"
    public static let notHeard = k("voice.error.not_heard")
    public static let noSpeechIn = k("voice.error.no_speech_in")
    /// ht surface, no Creole listening, but es/en on-device commands work (C1). Format with
    /// three language-tagged phrases: use `creoleCommandsOnlyNotice(_:lexicon:)`.
    public static let creoleCommandsOnly = k("voice.creole.commandsOnly")
    public static let listening = k("voice.listening")
    public static let kreyolPlay = k("kreyol.play")                         // "Play in Kreyòl" card action
    public static let kreyolNoRecording = k("kreyol.noRecording")           // no reviewed clip; nothing else plays
    public static let kreyolRestOnScreen = k("kreyol.restOnScreen")         // clip played for parts with no recording
    public static let micLabel = k("mic.label")                             // mic button accessibility label
    public static let micHint = k("mic.hint")                               // mic button accessibility hint
    public static let micStopLabel = k("mic.stopLabel")                     // mic button label while listening
    public static let kreyolCouldNotPlay = k("kreyol.couldNotPlay")         // a reviewed clip existed but failed to play
    public static let textMissing = k("voice.unavailable.missing_text")     // a missing string inside the text: not read
    /// Voice Control input labels, one phrase per key (the mic and its listening state).
    public static let micInputTalk = k("mic.inputLabel.talk")
    public static let micInputMicrophone = k("mic.inputLabel.microphone")
    public static let micStopInputStopListening = k("mic.stopInputLabel.stopListening")

    public static var all: [StringKey] {
        [unavailable, unavailableCreole, creoleVoiceOverLimit, creoleNeedsInternet, listenInSpanish, listenInEnglish, consentCloud,
         neverSendVoice, confirmTranscript, answerIn, notHeard, noSpeechIn, creoleCommandsOnly, listening, kreyolPlay, kreyolNoRecording, kreyolRestOnScreen,
         micLabel, micHint, micStopLabel, kreyolCouldNotPlay, textMissing,
         micInputTalk, micInputMicrophone, micStopInputStopListening, consentReadAloud]
    }

    /// Why a Creole card is not being read aloud.
    public enum CreoleNoticeReason: Hashable, Sendable {
        /// No Creole voice (on device or server) can read it.
        case noVoice
        /// Play in Kreyòl: no reviewed recording for this card.
        case noRecording
    }

    /// The Creole notice as ONE announcement, in this fixed order:
    /// 1. what is missing (`voice.unavailable.creole` for `.noVoice`, `kreyol.noRecording` for
    ///    `.noRecording`), then 2. `voice.creole.voiceOverLimit`.
    public static func creoleNotice(for reason: CreoleNoticeReason) -> [StringKey] {
        [reason == .noVoice ? unavailableCreole : kreyolNoRecording, creoleVoiceOverLimit]
    }

    /// A Voice Control input label: the key and the language to resolve it in.
    public struct InputLabel: Hashable, Sendable {
        public let key: StringKey
        public let language: SurfaceLanguage
    }

    /// Mic input labels for `accessibilityInputLabels`, first = the visible label's word.
    /// Voice Control does not recognize Creole, so on the ht surface the es and en names follow
    /// the ht ones.
    public static func micInputLabels(surface: SurfaceLanguage) -> [InputLabel] {
        inputLabels([micInputTalk, micInputMicrophone], surface: surface)
    }

    /// Input labels while listening (the stop state).
    public static func micStopInputLabels(surface: SurfaceLanguage) -> [InputLabel] {
        inputLabels([micStopInputStopListening], surface: surface)
    }

    static func inputLabels(_ keys: [StringKey], surface: SurfaceLanguage) -> [InputLabel] {
        let languages: [SurfaceLanguage] = surface == .ht ? [.ht, .es, .en] : [surface]
        return languages.flatMap { l in keys.map { InputLabel(key: $0, language: l) } }
    }

    /// The labeled "listen in ..." choice for a surface (only es and en have on-device voices).
    public static func listenIn(_ s: SurfaceLanguage) -> StringKey? {
        switch s {
        case .es: listenInSpanish
        case .en: listenInEnglish
        default: nil
        }
    }
}

/// ADVoice's resource bundle, for the app's `CatalogRegistry`.
public enum ADVoiceResources {
    public static var bundle: Bundle { .module }
    public static var registration: CatalogRegistration { CatalogRegistration(table: VoiceKey.table, bundle: .module) }
}

// MARK: C1: the commands-only notice, with each quoted phrase in its own language

extension VoiceKey {
    /// The phrases quoted by `voice.creole.commandsOnly`: "en español" (es), "in English" (en)
    /// and "back" in the notice's language ("atrás" on the es and ht surfaces, where the es/en
    /// on-device engines listen; "back" on en). Each preferred phrase is used only if the bundled
    /// lexicon accepts it for that command; otherwise the lexicon's first phrase is quoted.
    public static func commandsOnlyPhrases(surface: SurfaceLanguage, lexicon: CommandLexicon) -> [(text: String, language: SurfaceLanguage)] {
        func phrase(_ preferred: String, _ command: String, _ lang: SurfaceLanguage) -> (text: String, language: SurfaceLanguage)? {
            if lexicon.match(preferred, in: [lang]).first?.command == command { return (preferred, lang) }
            return lexicon.tables[lang]?.commands[command]?.first.map { ($0.text, lang) }
        }
        let back = surface == .en ? phrase("back", "back", .en) : phrase("atrás", "back", .es)
        return [phrase("en español", "switch_language_es", .es), phrase("in English", "switch_language_en", .en), back].compactMap { $0 }
    }

    /// `voice.creole.commandsOnly` in the localizer's surface, each quoted phrase a run tagged with
    /// its own language (so VoiceOver says "en español" in Spanish and "in English" in English).
    public static func creoleCommandsOnlyNotice(_ localizer: Localizer, lexicon: CommandLexicon) -> ResolvedText {
        let args = commandsOnlyPhrases(surface: localizer.surface, lexicon: lexicon).map {
            LocalizedArgument.text(ResolvedText(runs: [.init($0.text, language: $0.language.language)], language: $0.language.language))
        }
        return localizer.text(creoleCommandsOnly, arguments: args)
    }
}
