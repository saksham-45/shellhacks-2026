import Foundation
import ADCore
import ADLocale

/// The canonical command keys. Mirrors `contracts/intent/command_keys.json` exactly (a test checks
/// both directions). Adding a key means editing that file first (ARCHITECTURE.md §13.y).
public enum CommandKey: String, CaseIterable, Codable, Sendable {
    case back
    case home
    case readThis = "read_this"
    case stop
    case `repeat`
    case nextStep = "next_step"
    case previousStep = "previous_step"
    case callDesk = "call_desk"
    case openMap = "open_map"
    case switchLanguageES = "switch_language_es"
    case switchLanguageEN = "switch_language_en"
    case switchLanguageHT = "switch_language_ht"
    case switchLanguagePT = "switch_language_pt"
    case switchLanguageFR = "switch_language_fr"
    case switchLanguageAR = "switch_language_ar"
    case switchLanguageZH = "switch_language_zh"
    case switchLanguageRU = "switch_language_ru"
    case switchLanguageTL = "switch_language_tl"
    case switchLanguageVI = "switch_language_vi"
    case yes
    case no
    case ordinalFirst = "ordinal_first"
    case ordinalSecond = "ordinal_second"
    case ordinalThird = "ordinal_third"

    /// The action this command means here. Nil when the screen gives it nothing to act on
    /// (for example "call the desk" on a screen with no desk, or "the third one" with two choices).
    public func action(in context: RouteContext) -> AppAction? {
        switch self {
        case .back: .back
        case .home: .home
        case .readThis: .readAloud(context.cardID.map(ReadTarget.card) ?? .screen)
        case .stop: .stopSpeaking
        case .repeat: .repeatLast
        case .nextStep: .nextStep
        case .previousStep: .previousStep
        case .callDesk: context.deskID.map(AppAction.callDesk)
        case .openMap: context.deskID.map { .openMap(.desk($0)) }
        case .switchLanguageES: .setSurfaceLanguage(.es)
        case .switchLanguageEN: .setSurfaceLanguage(.en)
        case .switchLanguageHT: .setSurfaceLanguage(.ht)
        case .switchLanguagePT: .setSurfaceLanguage(.pt)
        case .switchLanguageFR: .setSurfaceLanguage(.fr)
        case .switchLanguageAR: .setSurfaceLanguage(.ar)
        case .switchLanguageZH: .setSurfaceLanguage(.zh)
        case .switchLanguageRU: .setSurfaceLanguage(.ru)
        case .switchLanguageTL: .setSurfaceLanguage(.tl)
        case .switchLanguageVI: .setSurfaceLanguage(.vi)
        case .yes: .confirm(true)
        case .no: .confirm(false)
        case .ordinalFirst: Self.choose(0, context)
        case .ordinalSecond: Self.choose(1, context)
        case .ordinalThird: Self.choose(2, context)
        }
    }

    private static func choose(_ index: Int, _ context: RouteContext) -> AppAction? {
        context.choiceIDs.indices.contains(index) ? .choose(context.choiceIDs[index]) : nil
    }
}

/// Command key -> phrases per language. myAD Language ships the real one as `CommandLexicon` in
/// ADLocale (`Commands/{es,en,ht}.json`); it conforms to this protocol with a one-line extension.
/// Until then the app uses `KeyNameLexicon`, and tests use `InMemoryCommandLexicon`.
public protocol CommandLexiconProviding: Sendable {
    /// Phrases for a command key in a BCP-47 language ("es", "en", "ht"). Empty when none.
    func phrases(for key: CommandKey, language: String) -> [String]
    /// Languages the lexicon has phrases for.
    var languages: [String] { get }
}

/// Plain in-memory lexicon (tests; or a lexicon decoded from `Commands/<lang>.json`).
public struct InMemoryCommandLexicon: CommandLexiconProviding {
    /// language -> command key raw value -> phrases
    public let table: [String: [String: [String]]]

    public init(_ table: [String: [String: [String]]]) { self.table = table }

    /// Decodes one `Commands/<lang>.json` file: `{"<command key>": ["phrase", ...], ...}`.
    public static func decode(language: String, json: Data) throws -> [String: [String]] {
        try JSONDecoder().decode([String: [String]].self, from: json)
    }

    public func phrases(for key: CommandKey, language: String) -> [String] {
        table[Self.base(language)]?[key.rawValue] ?? []
    }

    public var languages: [String] { table.keys.sorted() }

    static func base(_ tag: String) -> String { String(tag.lowercased().split(separator: "-").first ?? "") }
}

/// Fallback until Language ships the lexicon: the command key's own words, English only
/// ("next_step" -> "next step"). Writes no Spanish or Creole on anyone's behalf.
public struct KeyNameLexicon: CommandLexiconProviding {
    public init() {}
    public func phrases(for key: CommandKey, language: String) -> [String] {
        InMemoryCommandLexicon.base(language) == "en" ? [key.rawValue.replacingOccurrences(of: "_", with: " ")] : []
    }
    public var languages: [String] { ["en"] }
}

/// Natural ways a person asks for a card, per language (content/cards `utterances`).
public struct CardUtterances: Hashable, Sendable, Codable {
    public let cardID: CardID
    /// BCP-47 -> phrases
    public let phrases: [String: [String]]

    public init(cardID: CardID, phrases: [String: [String]]) {
        self.cardID = cardID
        self.phrases = phrases
    }
}

/// Resolves a string key to its text in a language, so a spoken option label or goal name can be
/// matched. The app backs it with the package bundles; tests with a dictionary.
public protocol LabelTextResolving: Sendable {
    func text(for key: StringKey, language: String) -> String?
}
