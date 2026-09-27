import Foundation
import ADCore

/// ADCityPack's user-facing text: table "ADCityPack" (Resources/ADCityPack.xcstrings, loaded via Bundle.module).
public enum RegionStrings {
    public static let table = "ADCityPack"
    public static var bundle: Bundle { .module }

    public static func key(_ key: String) -> StringKey { StringKey(key: key, table: table) }

    /// Every not-applicable reason the server can send (server/regionpacks/myad_regions/adapters.py NA_REASONS).
    public static let notApplicableReasons: [String] = [
        "regions.na.outside-layer",
        "regions.na.county-trash-not-serviced",
        "regions.na.city-trash-not-serviced",
        "regions.na.none-within-radius",
        "regions.na.parcel-year-not-recorded",
        "regions.na.no-parcel-nearby",
    ]
}
