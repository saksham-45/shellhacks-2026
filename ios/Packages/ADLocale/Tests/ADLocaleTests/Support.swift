import Foundation
import ADCore
@testable import ADLocale

/// Builds an in-memory catalog: key -> [lang: value]. Values are test data only.
func catalog(_ table: String, _ entries: [String: [String: String]]) -> CatalogRegistration {
    var strings: [String: Any] = [:]
    for (key, langs) in entries {
        var locs: [String: Any] = [:]
        for (lang, value) in langs { locs[lang] = ["stringUnit": ["state": "translated", "value": value]] }
        strings[key] = ["localizations": locs]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["sourceLanguage": "en", "version": "1.0", "strings": strings])
    return try! CatalogRegistration(table: table, xcstrings: data)
}

let newYork = TimeZone(identifier: "America/New_York")!

/// 2026-09-25 16:00 UTC (noon in Miami).
let sept25 = Date(timeIntervalSince1970: 1_790_352_000)

func lang(_ tag: String) -> Locale.Language { Locale.Language(identifier: tag) }

let testDesk: DeskID = "xx-test.desk"

func registry(extra: [CatalogRegistration] = []) -> CatalogRegistry {
    CatalogRegistry([ADLocaleResources.registration, CatalogRegistration(table: "ADCore", bundle: ADCoreStrings.bundle),
                     catalog("ADCityPack", ["desk.xx-test.desk": ["es": "Oficina de prueba", "en": "Test Desk", "ht": "Biwo tès"]]),
                     catalog("Cards", ["hero.test": ["es": "Mañana, basura", "en": "Tomorrow · trash", "ht": "Demen, fatra"],
                                       "card.test.title": ["es": "Basura", "en": "Trash", "ht": "Fatra"],
                                       "only.en": ["en": "English only"]])] + extra)
}

func localizer(_ s: SurfaceLanguage) -> Localizer { Localizer(registry: registry(), surface: s, timeZone: newYork) }

/// The repo (or staging) root holding contracts/intent/command_keys.json, found from this file.
func contractFile() -> URL? {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent("contracts/intent/command_keys.json")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir.deleteLastPathComponent()
    }
    return nil
}

/// This package's root, from this file.
func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
