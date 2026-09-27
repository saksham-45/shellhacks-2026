import Foundation
import ADCore
import ADLocale
import ADRouter
import ADCityPack

/// Resolves a StringKey in a given surface language, live (no relaunch): picks the catalog's bundle
/// by table and reads that language's compiled .lproj. Verbatim keys (names, addresses) pass through.
public enum AppStrings {
    /// App-owned tables in the main bundle: Localizable (UI), Cards (demo card titles), InfoPlist.
    public static let appTables: Set<String> = ["Localizable", "Cards", "InfoPlist", "AppShortcuts"]

    public static func bundle(forTable table: String) -> Bundle {
        switch table {
        case StringKey.adCoreTable: ADCoreStrings.bundle
        case RouterText.table: ADRouterStrings.bundle
        case RegionStrings.table: RegionStrings.bundle
        default: Bundle.main
        }
    }

    public static func text(_ key: StringKey, language: String) -> String {
        if key.table == RouterText.verbatimTable { return key.key }
        return text(key.key, table: key.table, bundle: bundle(forTable: key.table), language: language)
    }

    /// App strings (table Localizable in the main bundle).
    public static func app(_ key: String, _ language: String) -> String {
        text(key, table: "Localizable", bundle: .main, language: language)
    }

    public static func text(_ key: String, table: String, bundle: Bundle, language: String) -> String {
        let base = String(language.prefix(2)).lowercased()
        for code in [base, "en"] {
            if let path = bundle.path(forResource: code, ofType: "lproj"), let lproj = Bundle(path: path) {
                let s = lproj.localizedString(forKey: key, value: "\u{0}", table: table)
                if s != "\u{0}" { return s }
            }
        }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }

    /// Weekday names live in ADLocale's own catalog (table "Localizable" of ADLocale's bundle).
    public static func weekday(_ day: Weekday, _ language: String) -> String {
        text(day.stringKey.key, table: day.stringKey.table, bundle: ADLocaleStrings.bundle, language: language)
    }
}

/// Label text for the router's matcher (choice labels, goal names) in the utterance's language.
public struct AppLabels: LabelTextResolving {
    public init() {}
    public func text(for key: StringKey, language: String) -> String? {
        let base = String(language.prefix(2))
        guard SurfaceLanguage(rawValue: base) != nil || key.table == RouterText.verbatimTable else { return nil }
        let s = AppStrings.text(key, language: base)
        return s == key.key && key.table != RouterText.verbatimTable ? nil : s
    }
}
