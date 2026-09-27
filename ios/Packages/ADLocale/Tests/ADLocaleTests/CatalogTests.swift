import XCTest
@testable import ADLocale

/// Catalog completeness and review honesty for ADLocale.xcstrings (the file shipped in the bundle).
final class CatalogTests: XCTestCase {
    func shipped() throws -> XCStringsCatalog {
        let url = packageRoot().appendingPathComponent("Sources/ADLocale/Resources/ADLocale.xcstrings")
        return try XCStringsCatalog(table: "ADLocale", data: Data(contentsOf: url))
    }

    func testEveryKeyHasAllThreeLanguagesNonEmpty() throws {
        let c = try shipped()
        for (key, langs) in c.entries {
            for l in ["es", "en", "ht"] {
                let loc = try XCTUnwrap(langs[l], "\(key) missing \(l)")
                let values = loc.plural.isEmpty ? [loc.value ?? ""] : Array(loc.plural.values)
                XCTAssertFalse(values.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(key) \(l) empty")
            }
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let c = try shipped()
        for (key, langs) in c.entries {
            let sigs = ["es", "en", "ht"].compactMap { l -> [String]? in
                guard let loc = langs[l] else { return nil }
                return FormatString.signature(loc.plural["other"] ?? loc.value ?? "")
            }
            XCTAssertEqual(Set(sigs.map { $0.joined(separator: ",") }).count, 1, "\(key) format mismatch \(sigs)")
        }
    }

    func testCreoleIsNeverPresentedAsReviewed() throws {
        for s in try shipped().states() where s.language == "ht" {
            XCTAssertEqual(s.state, "needs_review", "\(s.key): Creole stays needs_review until a native-speaker pass (D9)")
        }
    }

    func testEveryOwnedKeyExists() throws {
        let c = try shipped()
        for key in ADLocaleKey.all {
            XCTAssertEqual(key.table, "ADLocale")
            XCTAssertNotNil(c.entries[key.key], key.key)
        }
    }

    func testBundledCatalogLoadsThroughTheRegistry() {
        let l = Localizer(registry: .adLocaleOnly, surface: .es)
        XCTAssertFalse(l.text(ADLocaleKey.everyDay).isMissing)
    }

    func testMiamiSpanishGlossary() throws {
        // Spain-only usage never ships in es (Review/glossary.json lists replacements).
        let forbidden = ["carné de conducir", "cita previa", "ayuntamiento", "móvil", "ordenador", "coche", "aparcar", "vosotros", "tenéis", "podéis"]
        for (key, langs) in try shipped().entries {
            let v = (langs["es"]?.value ?? "") + (langs["es"]?.plural.values.joined() ?? "")
            for f in forbidden { XCTAssertFalse(v.lowercased().contains(f), "\(key): '\(f)'") }
        }
    }
}
