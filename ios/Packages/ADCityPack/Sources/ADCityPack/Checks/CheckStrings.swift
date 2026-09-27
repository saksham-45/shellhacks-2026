import Foundation

/// The languages the demo beats speak and show. The beat's language is the family's choice, not the phone's UI
/// locale, so strings are looked up per language instead of through the current locale.
public enum CheckLanguage: String, CaseIterable, Hashable, Sendable {
    case es, en, ht
}

/// Template lookup by key and language (table "ADCityPack").
public protocol CheckStrings: Sendable {
    func template(_ key: String, _ language: CheckLanguage) -> String?
}

extension CheckStrings {
    /// The filled string, or the key itself when the catalog lacks it (visible in review, never a guessed text).
    public func text(_ key: String, _ language: CheckLanguage, _ args: [String] = []) -> String {
        CheckTemplate.fill(template(key, language) ?? key, args)
    }
}

/// Reads the compiled catalog's per-language tables (<lang>.lproj inside Bundle.module) on Apple platforms.
public struct BundleCheckStrings: CheckStrings {
    public init() {}
    public func template(_ key: String, _ language: CheckLanguage) -> String? {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        let s = bundle.localizedString(forKey: key, value: "\u{0}", table: RegionStrings.table)
        return s == "\u{0}" ? nil : s
    }
}

/// Reads an .xcstrings file directly (tests on Linux, and tools). Values of every state are returned; callers that
/// must not show unreviewed text check `state(_:_:)`.
public struct CatalogCheckStrings: CheckStrings {
    private let entries: [String: [String: (value: String, state: String)]]

    public init(xcstrings data: Data) throws {
        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Loc: Decodable { struct Unit: Decodable { let state: String; let value: String }; let stringUnit: Unit? }
                let localizations: [String: Loc]?
            }
            let strings: [String: Entry]
        }
        let cat = try JSONDecoder().decode(Catalog.self, from: data)
        var out: [String: [String: (String, String)]] = [:]
        for (k, e) in cat.strings {
            for (lang, loc) in e.localizations ?? [:] { if let u = loc.stringUnit { out[k, default: [:]][lang] = (u.value, u.state) } }
        }
        entries = out
    }

    public func template(_ key: String, _ language: CheckLanguage) -> String? { entries[key]?[language.rawValue]?.value }
    public func state(_ key: String, _ language: CheckLanguage) -> String? { entries[key]?[language.rawValue]?.state }
    public var keys: [String] { Array(entries.keys) }
}
