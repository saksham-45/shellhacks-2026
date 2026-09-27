import XCTest
import ADCore
@testable import ADLocale

/// Names the tree's existing callers use (ios/App, ADRouter) keep working.
final class CompatibilityTests: XCTestCase {
    func testADLocaleStringsBundleIsTheADLocaleBundle() {
        XCTAssertEqual(ADLocaleStrings.bundle.bundleURL, ADLocaleResources.bundle.bundleURL)
        // AppStrings.weekday pattern: day.stringKey's table looked up in ADLocaleStrings.bundle.
        let key = Weekday.tuesday.stringKey
        let registry = CatalogRegistry([CatalogRegistration(table: key.table, bundle: ADLocaleStrings.bundle)])
        let localizer = Localizer(registry: registry, surface: .es)
        XCTAssertEqual(localizer.text(key).plain, "martes")
        XCTAssertEqual(localizer.text(key, in: .en).plain, "Tuesday")
    }

    /// Transition for AppModel.swift:171 (`languages.thinkIn = thinkIn.language`): LanguageSettings.thinkIn
    /// stays Locale.Language (brief); SpokenLanguage exposes the Locale.Language it wraps.
    @MainActor
    func testSpokenLanguageExposesLocaleLanguageForThinkIn() {
        let spoken = SpokenLanguage(bcp47: "hi")
        let language: Locale.Language = spoken.language
        XCTAssertEqual(language.minimalIdentifier, "hi")
        XCTAssertEqual(SpokenLanguage(.ht).language.minimalIdentifier, "ht")
        XCTAssertEqual(SpokenLanguage(lang("es-419")).language, Locale.Language(identifier: "es-419"))

        let settings = LanguageSettings(surface: .es)
        settings.thinkIn = spoken.language
        XCTAssertEqual(settings.thinkInTag, "hi")
        XCTAssertEqual(settings.surface, .es)
        XCTAssertEqual(SpokenLanguage(settings.thinkIn), spoken)
    }
}
