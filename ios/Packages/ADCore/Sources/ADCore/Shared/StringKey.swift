import Foundation

/// A reference to user-facing text. ADCore has no locale and renders no strings;
/// ADLocale looks the key up in `table` (one catalog per package, named after its table:
/// "ADCore", "ADCityPack", "Cards", ...).
public struct StringKey: Hashable, Codable, Sendable {
    public let key: String
    public let table: String

    /// `table` defaults to "ADCore" (ARCHITECTURE.md §12: one catalog per package, named after its table).
    public init(key: String, table: String = StringKey.adCoreTable) {
        self.key = key
        self.table = table
    }

    /// The table ADCore's own keys live in (Resources/ADCore.xcstrings).
    public static let adCoreTable = "ADCore"

    static func adCore(_ key: String) -> StringKey { StringKey(key: key, table: adCoreTable) }
}

/// ADCore's resource bundle, for ADLocale to resolve `StringKey`s with table "ADCore".
public enum ADCoreStrings {
    public static var bundle: Bundle { .module }
}
