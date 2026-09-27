import Foundation
import ADCore

/// The full surfaces. Census ACS 2024 top languages spoken at home in Florida, plus Kreyòl
/// as its own surface (Haitian is 3rd in the state). Raw values are wire values
/// (`surface_language` in /v1): never rename a case.
public enum SurfaceLanguage: String, CaseIterable, Codable, Sendable {
    case es, en, ht, pt, fr, ar, zh, ru, tl, vi

    /// Maps any BCP-47 language to a surface by its language code, or nil when it is not one
    /// of the surfaces. "es-US", "es-419", "spa" -> es; "ht-HT", "hat" -> ht; "pt-BR" -> pt;
    /// "zh-Hans", "cmn" -> zh; "fil" -> tl. "hi" -> nil.
    public init?(_ language: Locale.Language) {
        let alpha2 = language.languageCode?.identifier(.alpha2)?.lowercased()
        let ident = (language.languageCode?.identifier ?? "").lowercased()
        if let alpha2, let mapped = SurfaceLanguage(rawValue: alpha2) {
            self = mapped
            return
        }
        switch ident {
        case "hat": self = .ht
        case "spa": self = .es
        case "por": self = .pt
        case "fra", "fre": self = .fr
        case "ara": self = .ar
        case "zho", "chi", "cmn", "yue": self = .zh
        case "rus": self = .ru
        case "fil", "tgl": self = .tl
        case "vie": self = .vi
        default: return nil
        }
    }

    /// Maps a BCP-47 tag string (wire form). Uses the full tag, not a two-letter prefix,
    /// so "hat" is Creole (not Hausa) and "spa" is Spanish.
    public init?(languageTag: String) {
        let tag = languageTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        self.init(Locale.Language(identifier: tag))
    }

    /// Wire tag: "es" / "en" / "ht" / "pt" / …
    public var language: Locale.Language { Locale.Language(identifier: rawValue) }

    /// Locale for Foundation digits, currency and dates. es -> es-US (Miami: `$1.32`,
    /// never Spain's `1,32 US$`), en -> en-US. ht -> en-US for digits and currency only
    /// (decision D8, needs review); Creole WORDS never come from Foundation because CLDR's
    /// ht data falls back to French. pt -> pt-BR (Florida's Portuguese speakers). zh -> zh-Hans.
    /// tl -> fil (Apple's Tagalog/Filipino locale).
    public var formattingLocale: Locale {
        switch self {
        case .es: Locale(identifier: "es-US")
        case .en, .ht: Locale(identifier: "en-US")
        case .pt: Locale(identifier: "pt-BR")
        case .fr: Locale(identifier: "fr")
        case .ar: Locale(identifier: "ar")
        case .zh: Locale(identifier: "zh-Hans")
        case .ru: Locale(identifier: "ru")
        case .tl: Locale(identifier: "fil")
        case .vi: Locale(identifier: "vi")
        }
    }

    /// The companion line under the stacked hero (decision D3): es <-> en; every other
    /// surface sits on English so a mixed household can share the phone.
    public var heroCompanion: SurfaceLanguage? {
        switch self {
        case .en: .es
        default: .en
        }
    }

    /// Autonym key ("language.es"); the value is identical in every catalog.
    public var autonymKey: StringKey { StringKey(key: "language.\(rawValue)", table: ADLocaleKey.table) }

    /// Autonym shown on the picker, identical on every surface. Proper names of languages.
    public var autonym: String {
        switch self {
        case .es: "Español"
        case .en: "English"
        case .ht: "Kreyòl"
        case .pt: "Português"
        case .fr: "Français"
        case .ar: "العربية"
        case .zh: "中文"
        case .ru: "Русский"
        case .tl: "Tagalog"
        case .vi: "Tiếng Việt"
        }
    }

    /// Kept for existing callers (`\.locale`). Same as `formattingLocale`.
    public var locale: Locale { formattingLocale }
}

/// A language someone speaks or thinks in, any BCP-47 tag. Encodes as a plain string
/// (`minimalIdentifier`, ARCHITECTURE.md §12), never the nested `Locale.Language` JSON.
/// Exists for wire types (e.g. ADRouter's `AppAction.setThinkIn`); in-memory state uses
/// `Locale.Language` directly.
public struct SpokenLanguage: Hashable, Codable, Sendable, CustomStringConvertible {
    public let language: Locale.Language

    public init(_ language: Locale.Language) {
        self.language = Locale.Language(identifier: language.minimalIdentifier)
    }
    public init(_ surface: SurfaceLanguage) { self.init(surface.language) }
    public init(bcp47: String) { self.init(Locale.Language(identifier: bcp47)) }

    /// The wire form, e.g. "es", "ht", "hi", "es-419".
    public var bcp47: String { language.minimalIdentifier }
    public var surface: SurfaceLanguage? { SurfaceLanguage(language) }
    public var description: String { bcp47 }

    public init(from decoder: any Decoder) throws {
        let tag = try decoder.singleValueContainer().decode(String.self)
        guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty BCP-47 tag"))
        }
        self.init(bcp47: tag)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(bcp47)
    }
}

extension Locale.Language {
    /// True when both languages share an ISO 639 language code (es-US ~ es-419, ht ~ hat).
    /// This is the "exact language" test the voice policy uses: fr-HT never matches ht.
    public func hasSameLanguageCode(as other: Locale.Language) -> Bool {
        guard let a = languageCode?.identifier(.alpha2) ?? languageCode?.identifier,
              let b = other.languageCode?.identifier(.alpha2) ?? other.languageCode?.identifier else { return false }
        return a.lowercased() == b.lowercased()
    }
}
