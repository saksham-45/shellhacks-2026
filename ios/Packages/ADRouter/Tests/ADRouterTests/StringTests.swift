import Foundation
import Testing
@testable import ADRouter

@Suite("ADRouter string catalog")
struct StringTests {
    @Test func everyRouterKeyIsInTheCatalogInThreeLanguages() throws {
        let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ADRouter/Resources/ADRouter.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let strings = catalog["strings"] as! [String: [String: Any]]
        for key in RouterText.all {
            #expect(key.table == RouterText.table)
            let locs = try #require(strings[key.key]?["localizations"] as? [String: Any], "\(key.key) missing")
            #expect(Set(locs.keys).isSuperset(of: ["es", "en", "ht"]), "\(key.key)")
        }
        #expect(Set(strings.keys) == Set(RouterText.all.map(\.key)))
    }
}
