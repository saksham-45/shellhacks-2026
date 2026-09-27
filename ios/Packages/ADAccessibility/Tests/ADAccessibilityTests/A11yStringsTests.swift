import Foundation
import Testing
@testable import ADAccessibility

@Suite struct A11yStringsTests {
    private func catalogStrings() throws -> [String: Any] {
        let url = try #require(A11yStrings.bundle.url(forResource: A11yStrings.table, withExtension: "xcstrings"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    /// The Magic Tap hint (A11Y-VC-04) stays in ADAccessibility: ADVoice has no equivalent key.
    @Test func playInKreyolHintExistsInCatalogForEveryLanguage() throws {
        let strings = try catalogStrings()
        let key = A11yStrings.playInKreyolHint
        let entry = try #require(strings[key] as? [String: Any], "missing \(key)")
        let locs = try #require(entry["localizations"] as? [String: Any])
        #expect(Set(locs.keys).isSuperset(of: ["es", "en", "ht"]), "\(key) lacks a language")
    }

    /// The action label key is ADVoice's `kreyol.play`; the ADAccessibility duplicate is retired
    /// (A11Y-LANG-03 part 3) and must not come back.
    @Test func retiredPlayInKreyolLabelKeyIsGone() throws {
        let strings = try catalogStrings()
        #expect(strings["a11y.card.playInKreyol"] == nil, "a11y.card.playInKreyol is retired: use ADVoice VoiceKey.kreyolPlay")
    }
}
