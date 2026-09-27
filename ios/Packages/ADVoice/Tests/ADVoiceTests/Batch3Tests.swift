import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// Review items 2 and 11, and the en != key check for ADLocale and ADVoice catalogs.
final class CreoleInputAndNoticeTests: XCTestCase {
    let creole = "Kote mwen ka jwenn biwo a, tanpri?"

    func testCreoleTextWithNoCreoleEngineNeedsConfirmation() async throws {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice, heard: ["es": (creole, 0.9), "en": ("Coat when can journey", 0.4)])
        let router = SpeechInputRouter(recognizers: [onDevice], detector: try TextLanguageDetector.bundled())
        let out = await router.listen(recording, context: ListenContext(surface: .es, thinkIn: lang("es")))
        XCTAssertEqual(out, .unavailable(.noEngine(lang("ht"))), "never act on a garbled es/en transcript of Creole")
        XCTAssertEqual(ListenUnavailable.noEngine(lang("ht")).messageKey, VoiceKey.noSpeechIn)
    }

    func testFrenchNeverWinsForCreole() async throws {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice,
                                      heard: ["fr": ("Coté moi que je trouve bureau", 0.99), "es": (creole, 0.3)])
        let router = SpeechInputRouter(recognizers: [onDevice], detector: try TextLanguageDetector.bundled())
        let out = await router.listen(recording, context: ListenContext(surface: .es, thinkIn: lang("fr")))
        XCTAssertEqual(out, .unavailable(.noEngine(lang("ht"))), "Creole is never answered as French")
    }

    /// swap2 #6: a French engine hides Creole from the detector; French must be confirmed.
    func testFrenchWinWithoutCreoleFlagNeedsConfirmation() async throws {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice,
                                      heard: ["fr": ("Où est le bureau du comté ?", 0.99), "es": ("Donde es el bureau", 0.2)])
        let router = SpeechInputRouter(recognizers: [onDevice], detector: try TextLanguageDetector.bundled())
        let out = await router.listen(recording, context: ListenContext(surface: .es, thinkIn: lang("fr")))
        guard case .heard(let r) = out else { return XCTFail("\(out)") }
        if r.language.hasSameLanguageCode(as: lang("fr")) { XCTAssertTrue(r.needsConfirmation) }
    }

    /// swap2 #6: think-in French with the ht surface: Creole path only, never French.
    func testThinkInFrenchWithCreoleSurface() async throws {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice, heard: ["fr": ("Coté moi que je trouve bureau", 0.99)])
        let noServer = SpeechInputRouter(recognizers: [onDevice], detector: try TextLanguageDetector.bundled())
        let ctx = ListenContext(surface: .ht, thinkIn: lang("fr"), privacy: consented)
        let out = await noServer.listen(recording, context: ctx)
        XCTAssertEqual(out, .unavailable(.noEngine(lang("ht"))))
        let asked = await onDevice.asked
        XCTAssertTrue(asked.isEmpty, "the French engine is never asked for Creole")
        let server = FakeRecognizer("server.proxy", location: .server, heard: ["ht": (creole, 0.7)])
        let withServer = SpeechInputRouter(recognizers: [onDevice, server], detector: try TextLanguageDetector.bundled())
        guard case .heard(let r) = await withServer.listen(recording, context: ctx) else { return XCTFail("expected heard") }
        XCTAssertEqual(r.language, lang("ht"))
        XCTAssertTrue(r.needsConfirmation)
    }

    func testOfflineAndUnconsentedCreoleAsksForConsent() {
        let server = voice("ht", engine: "server.proxy", at: .server)
        let route = VoicePolicy.route(for: lang("ht"), offers: [server], prerendered: nil,
                                      privacy: VoicePrivacy(cloudVoiceConsent: false, isOnline: false))
        guard case .unavailable(let u) = route else { return XCTFail("\(route)") }
        XCTAssertEqual(u.notice, VoiceKey.consentReadAloud)
    }

    func testNoEnglishValueEqualsItsKey() throws {
        for (table, bundle) in [("ADLocale", ADLocaleResources.bundle), ("ADVoice", ADVoiceResources.bundle)] {
            let url = try XCTUnwrap(bundle.url(forResource: table, withExtension: "xcstrings"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let strings = try XCTUnwrap(json["strings"] as? [String: Any])
            XCTAssertFalse(strings.isEmpty)
            for (key, entry) in strings {
                let en = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any]
                let value = (en?["stringUnit"] as? [String: Any])?["value"] as? String
                XCTAssertNotEqual(value, key, "\(table): en value equals key \(key)")
            }
        }
    }

    func testMicKeysExist() {
        let l = Localizer(registry: CatalogRegistry([ADVoiceResources.registration]), surface: .es)
        XCTAssertEqual(l.text(VoiceKey.micLabel).plain, "Hablar")
        XCTAssertEqual(l.text(VoiceKey.micInputMicrophone, in: .ht).plain, "mikwofòn")
    }
}
