import XCTest
import ADCore
@testable import ADLocale

final class SurfaceLanguageTests: XCTestCase {
    func testRawValuesAreWireValues() throws {
        XCTAssertEqual(SurfaceLanguage.allCases.map(\.rawValue),
                       ["es", "en", "ht", "pt", "fr", "ar", "zh", "ru", "tl", "vi"])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([SurfaceLanguage.ht]), as: UTF8.self), #"["ht"]"#)
    }

    func testMapsTagsToSurfaces() {
        for (tag, want) in [("es", SurfaceLanguage.es), ("es-US", .es), ("es-419", .es), ("spa", .es),
                            ("en-US", .en), ("en-GB", .en), ("ht", .ht), ("ht-HT", .ht), ("hat", .ht),
                            ("pt", .pt), ("pt-BR", .pt), ("fr", .fr), ("fr-HT", .fr), ("ar", .ar),
                            ("zh", .zh), ("zh-Hans", .zh), ("cmn", .zh), ("ru", .ru),
                            ("tl", .tl), ("fil", .tl), ("vi", .vi)] {
            XCTAssertEqual(SurfaceLanguage(lang(tag)), want, tag)
            XCTAssertEqual(SurfaceLanguage(languageTag: tag), want, tag)
        }
        for tag in ["hi", "ha", "ja", "de", ""] {
            XCTAssertNil(SurfaceLanguage(languageTag: tag), tag)
        }
    }

    func testFormattingLocales() {
        XCTAssertEqual(SurfaceLanguage.es.formattingLocale.identifier, "es-US")
        XCTAssertEqual(SurfaceLanguage.en.formattingLocale.identifier, "en-US")
        XCTAssertEqual(SurfaceLanguage.ht.formattingLocale.identifier, "en-US")   // digits only (D8)
    }

    func testHeroCompanionD3() {
        XCTAssertEqual(SurfaceLanguage.es.heroCompanion, .en)
        XCTAssertEqual(SurfaceLanguage.en.heroCompanion, .es)
        XCTAssertEqual(SurfaceLanguage.ht.heroCompanion, .en)
        XCTAssertEqual(SurfaceLanguage.pt.heroCompanion, .en)
        XCTAssertEqual(SurfaceLanguage.ar.heroCompanion, .en)
    }

    func testSpokenLanguageIsAPlainStringOnTheWire() throws {
        struct Payload: Codable { var thinkIn: SpokenLanguage }
        let json = String(decoding: try JSONEncoder().encode(Payload(thinkIn: SpokenLanguage(lang("hi")))), as: UTF8.self)
        XCTAssertEqual(json, #"{"thinkIn":"hi"}"#)
        XCTAssertFalse(json.contains("components"))
        let back = try JSONDecoder().decode(Payload.self, from: Data(#"{"thinkIn":"es-419"}"#.utf8))
        XCTAssertEqual(back.thinkIn.bcp47, "es-419")
        XCTAssertEqual(back.thinkIn.surface, .es)
        XCTAssertThrowsError(try JSONDecoder().decode(Payload.self, from: Data(#"{"thinkIn":""}"#.utf8)))
    }

    func testSameLanguageCode() {
        XCTAssertTrue(lang("es-US").hasSameLanguageCode(as: lang("es-419")))
        XCTAssertTrue(lang("hat").hasSameLanguageCode(as: lang("ht")))
        XCTAssertFalse(lang("fr-HT").hasSameLanguageCode(as: lang("ht")))
        XCTAssertFalse(lang("fr").hasSameLanguageCode(as: lang("ht")))
    }
}

@MainActor
final class LanguageSettingsTests: XCTestCase {
    func testFirstLaunchD4() {
        XCTAssertEqual(LanguageSettings.firstLaunchSurface(systemLanguages: ["de", "ja"]), .es)
        XCTAssertEqual(LanguageSettings.firstLaunchSurface(systemLanguages: ["fr-FR", "ht-HT", "en"]), .fr)
        XCTAssertEqual(LanguageSettings.firstLaunchSurface(systemLanguages: ["en-US"]), .en)
        XCTAssertEqual(LanguageSettings.firstLaunchSurface(systemLanguages: []), .es)
        let s = LanguageSettings(store: .inMemory(), systemLanguages: ["hi-IN"])
        XCTAssertEqual(s.surface, .es)
        XCTAssertFalse(s.hasChosenSurface)
    }

    func testLiveSwitchPersistsPlainStrings() {
        let store = LanguagePreferenceStore.inMemory()
        let s = LanguageSettings(store: store, systemLanguages: ["en-US"])
        s.surface = .ht
        s.thinkIn = lang("hi")
        XCTAssertTrue(s.hasChosenSurface)
        XCTAssertEqual(store.load(), .init(surface: "ht", thinkIn: "hi"))
        let reloaded = LanguageSettings(store: store, systemLanguages: ["en-US"])
        XCTAssertEqual(reloaded.surface, .ht)
        XCTAssertEqual(reloaded.thinkInTag, "hi")
        XCTAssertTrue(reloaded.hasChosenSurface)
    }

    func testThinkInMayDifferAndFollowNeverTouchesSurface() {
        let s = LanguageSettings(surface: .es)
        let person = Person(displayName: "A", thinkIn: lang("hi"), surfaceLanguage: lang("en"), goal: .arrive)
        s.follow(person)
        XCTAssertEqual(s.surface, .es)
        XCTAssertEqual(s.thinkInTag, "hi")
        XCTAssertEqual(s.surfaceTag, "es")
    }
}
