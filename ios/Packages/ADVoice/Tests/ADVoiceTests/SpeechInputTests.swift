import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// GAPS item 4 (part B): speech in, language ID, scripts, prerendered hashes, catalog.
final class LanguageIdentificationTests: XCTestCase {
    func testBundledDetectorReadsEsEnHt() throws {
        let d = try TextLanguageDetector.bundled()
        XCTAssertEqual(d.detect("¿Dónde está la oficina del condado?"), .es)
        XCTAssertEqual(d.detect("Where is the tax office, please?"), .en)
        XCTAssertEqual(d.detect("Kote mwen ka jwenn biwo a, tanpri?"), .ht)
        XCTAssertNil(d.detect("12345"))
    }

    func testFrenchInTheModelIsIgnoredAndNeverOutput() throws {
        let model = #"{"languages": {"de": {"words": ["und", "ich", "nicht"], "marks": "ß"},"#
            + #" "en": {"words": ["the"], "marks": ""}}}"#
        let d = try TextLanguageDetector(modelData: Data(model.utf8))
        XCTAssertTrue(d.scores("Und ich weiß nicht.").isEmpty)
        XCTAssertNil(d.detect("nicht"))
    }

    func testCandidatesAreTheThreeSurfacesPlusThinkIn() {
        XCTAssertEqual(LanguageCandidates(thinkIn: lang("hi")).languages.map(\.minimalIdentifier),
                       ["es", "en", "ht", "pt", "fr", "ar", "zh", "ru", "tl", "vi", "hi"])
        XCTAssertEqual(LanguageCandidates(thinkIn: lang("es-419")).languages.count, 10)
        XCTAssertEqual(LanguageCandidates(thinkIn: nil).languages.count, 10)
        let c = LanguageCandidates(thinkIn: lang("hi"))
        for other in ["de", "ja", "ko"] { XCTAssertNil(c.candidate(for: lang(other)), other) }
        XCTAssertEqual(c.candidate(for: lang("es-US"))?.minimalIdentifier, "es")
        XCTAssertEqual(c.candidate(for: lang("fr-CA"))?.minimalIdentifier, "fr")
    }

    func testChooseDiscardsNonCandidateTranscripts() throws {
        let d = try TextLanguageDetector.bundled()
        let c = LanguageCandidates(thinkIn: lang("en"))
        let french = Transcript(text: "Kote biwo a ye", language: lang("de"), confidence: 0.99, engine: "x")
        XCTAssertNil(LanguageIdentification.choose([french], detector: d, candidates: c, prior: lang("es")))
        let es = Transcript(text: "¿Dónde está la oficina?", language: lang("es"), confidence: 0.6, engine: "x")
        // The English engine hears the same Spanish sentence; its text is still Spanish, so text agreement favours es.
        let en = Transcript(text: "Donde esta la oficina", language: lang("en"), confidence: 0.6, engine: "x")
        let pick = try XCTUnwrap(LanguageIdentification.choose([french, es, en], detector: d, candidates: c, prior: lang("en")))
        XCTAssertEqual(pick.language.minimalIdentifier, "es")
    }

    func testPriorIsExplicitCreoleThenLastSentenceThenSurface() {
        XCTAssertEqual(ListenContext(surface: .en, thinkIn: lang("en"), prefersCreole: true).prior, lang("ht"))
        XCTAssertEqual(ListenContext(surface: .ht, thinkIn: lang("en"), lastHeard: lang("es")).prior, lang("ht"))
        XCTAssertEqual(ListenContext(surface: .en, thinkIn: lang("en"), lastHeard: lang("es-US")).prior.minimalIdentifier, "es")
        XCTAssertEqual(ListenContext(surface: .en, thinkIn: lang("en"), lastHeard: lang("de")).prior, lang("en"))
    }

    func testReplyFollowsTheSentenceJustSpoken() {
        let heard = Recognition(transcript: "¿y el peaje?", language: lang("es"), confidence: 1, engine: "stub", needsConfirmation: false)
        XCTAssertEqual(ReplyLanguagePolicy.replyLanguage(for: heard, surface: .en), lang("es"))
        XCTAssertEqual(ReplyLanguagePolicy.replyLanguage(for: nil, surface: .ht), lang("ht"))
        XCTAssertEqual(heard.bcp47, "es")
    }
}

final class SpeechInputRouterTests: XCTestCase {
    func makeRouter(server: FakeRecognizer? = nil) throws -> (SpeechInputRouter, FakeRecognizer) {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice, heard: [
            "es": ("¿Dónde está la oficina del condado?", 0.8),
            "en": ("Don't they send the con dado", 0.5),
        ])
        let recognizers: [any SpeechRecognizing] = [onDevice] + (server.map { [$0] } ?? [])
        return (SpeechInputRouter(recognizers: recognizers, detector: try TextLanguageDetector.bundled()), onDevice)
    }

    func creoleServer() -> FakeRecognizer {
        FakeRecognizer("server.proxy", location: .server, heard: ["ht": ("Kote mwen ka jwenn biwo a, tanpri?", 0.7)])
    }

    func testNoAudioIsNothingHeard() async throws {
        let (router, _) = try makeRouter()
        let out = await router.listen(nil, context: ListenContext(surface: .es, thinkIn: lang("es")))
        XCTAssertEqual(out, .unavailable(.nothingHeard))
    }

    func testSpanishIsPickedFromTextAndStaysOnDevice() async throws {
        let server = creoleServer()
        let (router, onDevice) = try makeRouter(server: server)
        let out = await router.listen(recording, context: ListenContext(surface: .en, thinkIn: lang("en"), privacy: consented))
        guard case .heard(let r) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(r.language.minimalIdentifier, "es")
        XCTAssertEqual(r.engine, "apple.sfspeech")
        let asked = await onDevice.asked, serverAsked = await server.asked
        XCTAssertEqual(Set(asked), ["en", "es"])
        XCTAssertTrue(serverAsked.isEmpty, "es/en audio never goes to the server")
    }

    func testCreoleGoesOnlyToTheServerWithConsentAndIsConfirmed() async throws {
        let server = creoleServer()
        let (router, onDevice) = try makeRouter(server: server)
        let ctx = ListenContext(surface: .es, thinkIn: lang("es"), prefersCreole: true, privacy: consented)
        let out = await router.listen(recording, context: ctx)
        guard case .heard(let r) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(r.language, lang("ht"))
        XCTAssertEqual(r.engine, "server.proxy")
        XCTAssertTrue(r.needsConfirmation)
        let asked = await onDevice.asked
        XCTAssertTrue(asked.isEmpty, "Creole is never identified from on-device audio")
    }

    func testCreoleWithoutPermissionSaysWhy() async throws {
        let (router, _) = try makeRouter(server: creoleServer())
        let cases: [(VoicePrivacy, ListenUnavailable)] = [
            (VoicePrivacy(cloudVoiceConsent: false), .consentRequired(lang("ht"))),
            (VoicePrivacy(cloudVoiceConsent: true, neverSendVoice: true), .neverSendVoice(lang("ht"))),
            (VoicePrivacy(cloudVoiceConsent: true, isOnline: false), .offline(lang("ht"))),
        ]
        for (privacy, reason) in cases {
            let out = await router.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"), privacy: privacy))
            XCTAssertEqual(out, .unavailable(reason), "\(privacy)")
        }
        XCTAssertEqual(ListenUnavailable.consentRequired(lang("ht")).messageKey, VoiceKey.consentCloud)
        XCTAssertEqual(ListenUnavailable.offline(lang("ht")).messageKey, VoiceKey.creoleNeedsInternet)
    }

    func testNoCreoleEngineIsNoEngine() async throws {
        let (router, _) = try makeRouter()
        let out = await router.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"), privacy: consented))
        XCTAssertEqual(out, .unavailable(.noEngine(lang("ht"))))
    }

    func testCreoleHeardByASpanishEngineIsNotActedOnWithoutConsent() async throws {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice, heard: ["es": ("Kote mwen ka jwenn biwo a, tanpri?", 0.9)])
        let router = SpeechInputRouter(recognizers: [onDevice, creoleServer()], detector: try TextLanguageDetector.bundled())
        let out = await router.listen(recording, context: ListenContext(surface: .es, thinkIn: lang("es")))
        XCTAssertEqual(out, .unavailable(.consentRequired(lang("ht"))))
    }

    func testServerEngineWithoutTransportSupportsNothing() async {
        let engine = ServerProxySpeechEngine(transport: nil)
        let supportsHT = await engine.supports(lang("ht"))
        let voices = await engine.voices(for: lang("ht"))
        XCTAssertFalse(supportsHT)
        XCTAssertTrue(voices.isEmpty)
        XCTAssertEqual(engine.location, .server)
        XCTAssertEqual(String(describing: Credential(bearer: "x-test", expires: nil)), "Credential(redacted)")
    }
}

final class VoiceScriptTests: XCTestCase {
    func testLaunchOptions() {
        XCTAssertEqual(VoiceLaunchOptions.parse(["app"]), .live)
        XCTAssertEqual(VoiceLaunchOptions.parse(["app", "-myadVoiceScript", "smoke"]), .live)
        XCTAssertEqual(VoiceLaunchOptions.parse(["app", "-myadVoiceStub"]), .stub(script: nil))
        XCTAssertEqual(VoiceLaunchOptions.parse(["app", "-myadVoiceStub", "-myadVoiceScript", "smoke"]), .stub(script: "smoke"))
        XCTAssertEqual(VoiceLaunchOptions.parse(["app", "-myadVoiceStub", "-myadVoiceScript", "-x"]), .stub(script: nil))
    }

    func testSmokeScriptReplaysWithCreoleConfirmedAndFrenchNeverHeard() async throws {
        let script = try VoiceScript.load(named: "smoke", bundles: [])
        XCTAssertEqual(script.name, "smoke")
        XCTAssertEqual(script.steps.count, 7)
        XCTAssertEqual(script.steps[2].expect?.replyLanguage, "es")
        let input = ScriptedSpeechInput(script: script)
        let ctx = ListenContext(surface: .es, thinkIn: lang("es"))
        var outcomes: [RecognitionOutcome] = []
        for _ in 0..<8 { outcomes.append(await input.listen(nil, context: ctx)) }
        guard case .heard(let first) = outcomes[0], case .heard(let creole) = outcomes[3] else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(first.transcript, "en español")
        XCTAssertFalse(first.needsConfirmation)
        XCTAssertEqual(creole.language, lang("ht"))
        XCTAssertTrue(creole.needsConfirmation)
        XCTAssertEqual(outcomes[7], .unavailable(.nothingHeard), "after the last step the stub hears nothing")

        let french = ScriptedSpeechInput(script: try VoiceScript(data: Data(#"{"name":"f","steps":[{"say":"bonjour","language":"fr"}]}"#.utf8)))
        let heard = await french.listen(nil, context: ctx)
        XCTAssertEqual(heard, .unavailable(.nothingHeard))
    }

    func testMismatchesReportsEachExpectation() throws {
        let script = try VoiceScript.load(named: "smoke", bundles: [])
        let step = script.steps[4]   // "li sa a": read_this, reply ht, confirm, unavailable
        let r = Recognition(transcript: step.say, language: lang("ht"), confidence: 1, engine: "stub", needsConfirmation: true)
        let unavailable = SynthesisResult(segments: [.unavailable(UnavailableSpeech(language: lang("ht"), notice: VoiceKey.unavailableCreole, labeledAlternatives: [.es, .en]))])
        XCTAssertEqual(VoiceScript.mismatches(step, recognition: r, command: "read_this", replyLanguage: lang("ht"), speech: unavailable), [])
        let bad = VoiceScript.mismatches(step, recognition: r, command: "go_back", replyLanguage: lang("en"),
                                         speech: SynthesisResult(segments: []))
        XCTAssertEqual(bad.count, 3, "\(bad)")
    }
}

final class PrerenderedAudioTests: XCTestCase {
    func testSHA256MatchesHashlib() {
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data("Fatra".utf8)), "a30e3284695b50456d333d3c266c23a66fdf9a72ee596b5576de6137e6e8a2c5")
    }

    func testClipPlaysOnlyForTheCurrentTextAndLanguage() throws {
        let manifest = #"{"clips":[{"table":"Cards","key":"card.test.title","language":"ht-HT","#
            + #""sha256":"A30E3284695B50456D333D3C266C23A66FDF9A72EE596B5576DE6137E6E8A2C5","file":"t.ht.m4a","reviewed":true}]}"#
        let lib = try BundledPrerenderedAudio(manifest: Data(manifest.utf8), audioDirectory: URL(fileURLWithPath: "/audio"))
        let key = StringKey(key: "card.test.title", table: "Cards")
        let hit = try XCTUnwrap(lib.clip(for: key, language: lang("ht"), text: "Fatra"))
        XCTAssertEqual(hit.fileURL.path, "/audio/t.ht.m4a")
        XCTAssertNil(lib.clip(for: key, language: lang("ht"), text: "Fatra!"), "edited text never plays stale audio")
        XCTAssertNil(lib.clip(for: key, language: lang("es"), text: "Fatra"))
        XCTAssertNil(lib.clip(for: StringKey(key: "card.other.title", table: "Cards"), language: lang("ht"), text: "Fatra"))
    }

    func testBundledManifestIsEmptyUntilReviewed() throws {
        XCTAssertEqual(try BundledPrerenderedAudio.bundled().count, 0)
    }
}

final class VoiceCatalogTests: XCTestCase {
    func testEveryVoiceKeyHasEsEnHt() throws {
        let url = try XCTUnwrap(ADVoiceResources.bundle.url(forResource: "ADVoice", withExtension: "xcstrings"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for key in VoiceKey.all {
            XCTAssertEqual(key.table, "ADVoice")
            let locs = (strings[key.key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for l in ["es", "en", "ht"] {
                let unit = (locs[l] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                XCTAssertFalse(value.isEmpty, "\(key.key) [\(l)]")
                if l == "en" { XCTAssertNotEqual(value, key.key) }
            }
        }
    }
}
