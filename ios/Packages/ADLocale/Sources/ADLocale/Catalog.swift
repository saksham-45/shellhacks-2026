import Foundation

/// One language's value for one key, as ADLocale needs it: a plain value or plural forms.
struct CatalogLocalization: Hashable, Sendable {
    var value: String?
    /// CLDR plural category ("one", "other", ...) -> value.
    var plural: [String: String]
    var state: String?

    func string(pluralCount: Int?) -> String? {
        if !plural.isEmpty {
            let category = (pluralCount == 1) ? "one" : "other"
            return plural[category] ?? plural["other"] ?? value
        }
        return value
    }
}

/// Where a table's strings come from. Two implementations, chosen per bundle at init.
protocol CatalogBackend: Sendable {
    func localization(key: String, language: SurfaceLanguage) -> CatalogLocalization?
    var keys: Set<String> { get }
}

/// Reads a raw String Catalog (`.xcstrings` JSON). SwiftPM on Linux copies the catalog into the
/// bundle uncompiled (proven in the architect pass), and tests use it everywhere.
struct XCStringsCatalog: CatalogBackend, Hashable {
    let table: String
    let entries: [String: [String: CatalogLocalization]]   // key -> language -> localization
    let sourceLanguage: String

    init(table: String, data: Data) throws {
        let root = try JSONDecoder().decode(RawCatalog.self, from: data)
        self.table = table
        self.sourceLanguage = root.sourceLanguage ?? "en"
        var out: [String: [String: CatalogLocalization]] = [:]
        for (key, entry) in root.strings ?? [:] {
            var langs: [String: CatalogLocalization] = [:]
            for (lang, loc) in entry.localizations ?? [:] {
                var plural: [String: String] = [:]
                var state = loc.stringUnit?.state
                for (category, variant) in loc.variations?.plural ?? [:] {
                    if let v = variant.stringUnit?.value { plural[category] = v }
                    state = state ?? variant.stringUnit?.state
                }
                langs[lang] = CatalogLocalization(value: loc.stringUnit?.value, plural: plural, state: state)
            }
            out[key] = langs
        }
        entries = out
    }

    var keys: Set<String> { Set(entries.keys) }

    func localization(key: String, language: SurfaceLanguage) -> CatalogLocalization? {
        guard let loc = entries[key]?[language.rawValue] else { return nil }
        let hasText = !(loc.value ?? "").isEmpty || !loc.plural.isEmpty
        return hasText ? loc : nil
    }

    /// Every (key, language, state) triple, for review counts and parity tests.
    func states() -> [(key: String, language: String, state: String?)] {
        entries.flatMap { key, langs in langs.map { (key, $0.key, $0.value.state) } }
    }

    // Only the parts of the format ADLocale reads.
    private struct RawCatalog: Decodable {
        var sourceLanguage: String?
        var strings: [String: RawEntry]?
    }
    private struct RawEntry: Decodable { var localizations: [String: RawLocalization]? }
    private struct RawLocalization: Decodable {
        var stringUnit: RawUnit?
        var variations: RawVariations?
    }
    private struct RawVariations: Decodable { var plural: [String: RawVariant]? }
    private struct RawVariant: Decodable { var stringUnit: RawUnit? }
    private struct RawUnit: Decodable {
        var state: String?
        var value: String?
    }
}

/// `Bundle` wrapper: lookups are thread-safe, and this keeps the backend `Sendable` whatever
/// the SDK says about `Bundle`.
final class BundleBox: @unchecked Sendable {
    let bundle: Bundle
    init(_ bundle: Bundle) { self.bundle = bundle }
}

/// Compiled catalog (Xcode builds `<lang>.lproj/<table>.strings` + `.stringsdict`). Looks in the
/// lproj of the REQUESTED language explicitly, because Bundle's own choice follows the system
/// language list, not the in-app surface. Unverified until the captain's Mac run (checks 1-2).
struct LprojCatalog: CatalogBackend {
    let table: String
    let perLanguage: [SurfaceLanguage: BundleBox]
    private static let missing = "\u{1}ADLOCALE-MISSING\u{1}"

    init(table: String, bundle: Bundle) {
        self.table = table
        var map: [SurfaceLanguage: BundleBox] = [:]
        for lang in SurfaceLanguage.allCases {
            if let path = bundle.path(forResource: lang.rawValue, ofType: "lproj"), let b = Bundle(path: path) {
                map[lang] = BundleBox(b)
            }
        }
        perLanguage = map
    }

    var isEmpty: Bool { perLanguage.isEmpty }
    var keys: Set<String> { [] }   // compiled tables cannot be enumerated cheaply; parity runs on the JSON

    func localization(key: String, language: SurfaceLanguage) -> CatalogLocalization? {
        guard let box = perLanguage[language] else { return nil }
        let b = box.bundle
        if let plural = Self.pluralForms(bundle: b, table: table, key: key) {
            return CatalogLocalization(value: nil, plural: plural, state: nil)
        }
        let v = b.localizedString(forKey: key, value: Self.missing, table: table)
        guard v != Self.missing else { return nil }
        return CatalogLocalization(value: v, plural: [:], state: nil)
    }

    /// Reads plural forms out of the compiled `.stringsdict` (one variable per key).
    static func pluralForms(bundle: Bundle, table: String, key: String) -> [String: String]? {
        guard let url = bundle.url(forResource: table, withExtension: "stringsdict"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entry = plist[key] as? [String: Any] else { return nil }
        for (name, value) in entry where name != "NSStringLocalizedFormatKey" {
            guard let rule = value as? [String: Any], (rule["NSStringFormatSpecTypeKey"] as? String) == "NSStringPluralRuleType" else { continue }
            var forms: [String: String] = [:]
            for category in ["zero", "one", "two", "few", "many", "other"] {
                if let s = rule[category] as? String { forms[category] = s }
            }
            if !forms.isEmpty { return forms }
        }
        return nil
    }
}

/// One table -> where its strings live. The table name equals the catalog file name and
/// `StringKey.table` (ARCHITECTURE.md §12).
public struct CatalogRegistration: Sendable {
    public let table: String
    let backend: any CatalogBackend

    /// Picks the raw `<table>.xcstrings` in `bundle` when present (Linux, tests), else the
    /// compiled `<lang>.lproj/<table>.strings` (Apple builds).
    public init(table: String, bundle: Bundle) {
        self.table = table
        if let url = bundle.url(forResource: table, withExtension: "xcstrings"),
           let data = try? Data(contentsOf: url),
           let catalog = CatalogRegistration.decode(table: table, data: data) {
            backend = catalog
        } else {
            backend = LprojCatalog(table: table, bundle: bundle)
        }
    }

    /// Release: a malformed catalog falls back to the lproj backend (visible ⟦table:key⟧ markers).
    /// Debug: fails loudly with the table name and the decode error.
    static func decode(table: String, data: Data) -> XCStringsCatalog? {
        do {
            return try XCStringsCatalog(table: table, data: data)
        } catch {
            assertionFailure("ADLocale: \(table).xcstrings failed to decode: \(error)")
            return nil
        }
    }

    /// A catalog from raw `.xcstrings` bytes (tests, previews, content bundles).
    public init(table: String, xcstrings data: Data) throws {
        self.table = table
        backend = try XCStringsCatalog(table: table, data: data)
    }
}

/// Immutable, built once at app start. No global mutable singleton (Swift 6 strict concurrency).
public struct CatalogRegistry: Sendable {
    let backends: [String: any CatalogBackend]

    /// Later registrations of the same table replace earlier ones (asserts in debug).
    public init(_ registrations: [CatalogRegistration]) {
        var map: [String: any CatalogBackend] = [:]
        for r in registrations {
            assert(map[r.table] == nil, "duplicate string table \(r.table)")
            map[r.table] = r.backend
        }
        backends = map
    }

    /// ADLocale's own table only.
    public static var adLocaleOnly: CatalogRegistry { CatalogRegistry([ADLocaleResources.registration]) }

    public var tables: [String] { backends.keys.sorted() }

    func localization(_ table: String, _ key: String, _ language: SurfaceLanguage) -> CatalogLocalization? {
        backends[table]?.localization(key: key, language: language)
    }

    func hasTable(_ table: String) -> Bool { backends[table] != nil }
}

/// ADLocale's resource bundle and its registration.
public enum ADLocaleResources {
    public static var bundle: Bundle { .module }
    public static var registration: CatalogRegistration { CatalogRegistration(table: ADLocaleKey.table, bundle: .module) }
}

/// Kept for existing callers (ios/App AppStrings.weekday): same bundle as `ADLocaleResources.bundle`.
public enum ADLocaleStrings {
    public static var bundle: Bundle { .module }
}
