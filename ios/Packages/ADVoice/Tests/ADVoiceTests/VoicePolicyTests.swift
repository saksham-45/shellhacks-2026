import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// GAPS item 3 (part A): speech-out voice policy.
final class VoicePolicyTests: XCTestCase {
    func testOnlyAnExactLanguageCodeIsAccepted() {
        XCTAssertTrue(VoicePolicy.accepts(voice("ht"), for: lang("ht")))
        XCTAssertTrue(VoicePolicy.accepts(voice("ht-HT"), for: lang("ht")))
        XCTAssertTrue(VoicePolicy.accepts(voice("es-US"), for: lang("es-419")))
        XCTAssertTrue(VoicePolicy.accepts(voice("en-GB"), for: lang("en-US")))
        for french in ["fr", "fr-FR", "fr-CA", "fr-HT"] {
            XCTAssertFalse(VoicePolicy.accepts(voice(french), for: lang("ht")), french)
        }
        XCTAssertFalse(VoicePolicy.accepts(voice("en-US"), for: lang("es")))
        XCTAssertFalse(VoicePolicy.accepts(voice("es-US"), for: lang("ht")))
    }

    func testCreoleNeverFallsBackToAFrenchVoice() {
        let french = [voice("fr-FR", .premium), voice("fr-HT", .premium), voice("fr-CA"),
                      voice("fr-FR", engine: "server.proxy", at: .server)]
        let route = VoicePolicy.route(for: lang("ht"), offers: french, prerendered: nil, privacy: consented)
        guard case .unavailable(let u) = route else { return XCTFail("expected .unavailable, got \(route)") }
        XCTAssertEqual(u.notice, VoiceKey.unavailableCreole)
        XCTAssertEqual(u.labeledAlternatives, [.es, .en])
    }

    func testCreoleOrderPrerenderedThenServerThenUnavailable() {
        let server = voice("ht", engine: "server.proxy", at: .server)
        // 1. A bundled clip in Creole wins, even when the server could speak.
        XCTAssertEqual(VoicePolicy.route(for: lang("ht"), offers: [server], prerendered: clip("ht"), text: "Fatra", privacy: consented),
                       .prerendered(clip("ht")))
        // 2. No clip: the server voice, only when online and consented.
        XCTAssertEqual(VoicePolicy.route(for: lang("ht"), offers: [server], prerendered: nil, privacy: consented),
                       .voice(server))
        // 3. Otherwise unavailable, with the notice that says why.
        let cases: [(VoicePrivacy, StringKey)] = [
            // Read-aloud consent (not voice-input consent) governs server read-aloud.
            (VoicePrivacy(cloudVoiceConsent: true, isOnline: true), VoiceKey.consentReadAloud),
            (VoicePrivacy(isOnline: false), VoiceKey.consentReadAloud),
            (VoicePrivacy(neverSendVoice: true, isOnline: true, readAloudConsent: true), VoiceKey.unavailableCreole),
            (VoicePrivacy(neverSendVoice: true, isOnline: false, readAloudConsent: true), VoiceKey.unavailableCreole),
            (VoicePrivacy(isOnline: false, readAloudConsent: true), VoiceKey.creoleNeedsInternet),
        ]
        for (privacy, notice) in cases {
            let route = VoicePolicy.route(for: lang("ht"), offers: [server], prerendered: nil, privacy: privacy)
            guard case .unavailable(let u) = route else { XCTFail("\(privacy): expected .unavailable, got \(route)"); continue }
            XCTAssertEqual(u.notice, notice, "\(privacy)")
            XCTAssertEqual(u.language, lang("ht"))
        }
    }

    func testAClipInAnotherLanguageIsNeverPlayed() {
        let route = VoicePolicy.route(for: lang("ht"), offers: [], prerendered: clip("es"), text: "Fatra", privacy: consented)
        guard case .unavailable = route else { return XCTFail("expected .unavailable, got \(route)") }
    }

    func testCreoleUsesARealOnDeviceCreoleVoiceIfOneAppears() {
        let onDevice = voice("ht")
        XCTAssertEqual(VoicePolicy.route(for: lang("ht"), offers: [onDevice], prerendered: nil, privacy: VoicePrivacy()),
                       .voice(onDevice))
    }

    func testSpanishAndEnglishStayOnDeviceAndPickTheBestVoice() {
        let compact = voice("es-US", .compact), premium = voice("es-US", .premium), enhanced = voice("es-MX", .enhanced)
        XCTAssertEqual(VoicePolicy.route(for: lang("es"), offers: [compact, premium, enhanced, voice("en-US", .premium)],
                                         prerendered: nil, privacy: VoicePrivacy()), .voice(premium))
        // es/en never go to the server, even with consent.
        let server = voice("es-US", .premium, engine: "server.proxy", at: .server)
        let route = VoicePolicy.route(for: lang("es"), offers: [server], prerendered: nil, privacy: consented)
        guard case .unavailable(let u) = route else { return XCTFail("expected .unavailable, got \(route)") }
        XCTAssertEqual(u.notice, VoiceKey.unavailable)
        XCTAssertEqual(u.labeledAlternatives, [.en], "never offers the same language as an alternative")
    }

    func testThinkInLanguageOnDeviceThenConsentedServerThenUnavailable() {
        let onDevice = voice("hi"), server = voice("hi", engine: "server.proxy", at: .server)
        XCTAssertEqual(VoicePolicy.route(for: lang("hi"), offers: [server, onDevice], prerendered: nil, privacy: consented), .voice(onDevice))
        XCTAssertEqual(VoicePolicy.route(for: lang("hi"), offers: [server], prerendered: nil, privacy: consented), .voice(server))
        let route = VoicePolicy.route(for: lang("hi"), offers: [server], prerendered: nil, privacy: VoicePrivacy())
        guard case .unavailable(let u) = route else { return XCTFail("expected .unavailable, got \(route)") }
        XCTAssertEqual(u.notice, VoiceKey.unavailable)
        XCTAssertEqual(u.labeledAlternatives, [.es, .en])
    }

    func testListenInChoicesAreLabeledKeysOnlyForSpanishAndEnglish() {
        XCTAssertEqual(VoiceKey.listenIn(.es), VoiceKey.listenInSpanish)
        XCTAssertEqual(VoiceKey.listenIn(.en), VoiceKey.listenInEnglish)
        XCTAssertNil(VoiceKey.listenIn(.ht))
    }
}

/// VoiceSpeaker with the stub engine: each segment in its own language, never substituted.
final class VoiceSpeakerTests: XCTestCase {
    func testCreoleIsNotSpokenByTheStubAndAlternativesAreOnlyOffered() async {
        let stub = StubSpeechSynthesizer()
        let output = VoiceSpeaker(synthesizers: [stub])
        let result = await output.speak(SpokenText("Demen se jou fatra.", language: lang("ht")), privacy: consented, language: .ht)
        XCTAssertFalse(result.isFullySpoken)
        XCTAssertEqual(result.unavailable?.notice, VoiceKey.unavailableCreole)
        XCTAssertEqual(result.unavailable?.labeledAlternatives, [.es, .en])
        let spoken = await stub.spoken
        XCTAssertTrue(spoken.isEmpty, "Spanish/English audio is never played in place of Creole")
    }

    func testEachSegmentIsSpokenInItsOwnLanguage() async {
        let stub = StubSpeechSynthesizer()
        let output = VoiceSpeaker(synthesizers: [stub])
        let text = SpokenText(segments: [.init("Mañana pasan la basura. ", language: lang("es")),
                                         .init("Miami-Dade ", language: lang("en")),
                                         .init("Demen.", language: lang("ht"))])
        let result = await output.speak(text, privacy: VoicePrivacy(), language: .es)
        XCTAssertEqual(result.segments.count, 3)
        guard case .played(.voice(let es)) = result.segments[0], case .played(.voice(let en)) = result.segments[1],
              case .unavailable = result.segments[2] else { return XCTFail("\(result.segments)") }
        XCTAssertTrue(es.language.hasSameLanguageCode(as: lang("es")))
        XCTAssertTrue(en.language.hasSameLanguageCode(as: lang("en")))
        let spoken = await stub.spoken
        XCTAssertEqual(spoken.map(\.text), ["Mañana pasan la basura. ", "Miami-Dade "])
    }

    func testServerIsNotAskedForVoicesWhenOffline() async {
        let server = FakeSynthesizer("server.proxy", location: .server, languages: ["ht"])
        let output = VoiceSpeaker(synthesizers: [server])
        let offline = VoicePrivacy(cloudVoiceConsent: true, isOnline: false, readAloudConsent: true)
        let route = await output.route(.init("Bonjou", language: lang("ht")), sourceKey: nil, privacy: offline)
        guard case .unavailable(let u) = route else { return XCTFail("expected .unavailable, got \(route)") }
        XCTAssertEqual(u.notice, VoiceKey.creoleNeedsInternet)
        let result = await output.speak(SpokenText("Bonjou", language: lang("ht")), privacy: consented, language: .ht)
        XCTAssertTrue(result.isFullySpoken)
        let spoken = await server.spoken
        XCTAssertEqual(spoken.map(\.text), ["Bonjou"])
    }

    func testPrerenderedClipPlaysThroughThePlayerForASingleCatalogString() async {
        let key = StringKey(key: "card.test.title", table: "Cards")
        let player = RecordingPlayer(), stub = StubSpeechSynthesizer()
        let output = VoiceSpeaker(synthesizers: [stub], prerendered: OneClipLibrary(clip: clip("ht")), player: player)
        let result = await output.speak(SpokenText("Fatra", language: lang("ht")), sourceKey: key, privacy: VoicePrivacy(), language: .ht)
        XCTAssertEqual(result.segments, [.played(.prerendered(clip("ht")))])
        let played = await player.played
        XCTAssertEqual(played, [clip("ht")])
        // No key (dynamic text): no clip, so Creole is honestly unavailable.
        let dynamic = await output.speak(SpokenText("Fatra", language: lang("ht")), privacy: VoicePrivacy(), language: .ht)
        XCTAssertNotNil(dynamic.unavailable)
    }

    func testNoPlayerMeansNoPrerenderedRoute() async {
        let key = StringKey(key: "card.test.title", table: "Cards")
        let output = VoiceSpeaker(synthesizers: [StubSpeechSynthesizer()], prerendered: OneClipLibrary(clip: clip("ht")))
        let route = await output.route(.init("Fatra", language: lang("ht")), sourceKey: key, privacy: VoicePrivacy())
        guard case .unavailable = route else { return XCTFail("expected .unavailable, got \(route)") }
    }

    /// Review swap2 #5: the speech policy uses the same check as KreyolAudio.
    func testUnreviewedOrStaleClipIsNeverChosen() async {
        let good = clip("ht")
        let unreviewed = PrerenderedClip(key: good.key, language: good.language, contentHash: good.contentHash, fileURL: good.fileURL, reviewed: false)
        for bad in [unreviewed] {
            let r = VoicePolicy.route(for: lang("ht"), offers: [], prerendered: bad, text: "Fatra", privacy: consented)
            guard case .unavailable = r else { return XCTFail("unreviewed clip chosen: \(r)") }
        }
        let stale = VoicePolicy.route(for: lang("ht"), offers: [], prerendered: good, text: "Fatra!", privacy: consented)
        guard case .unavailable = stale else { return XCTFail("stale clip chosen: \(stale)") }
        let noText = VoicePolicy.route(for: lang("ht"), offers: [], prerendered: good, privacy: consented)
        guard case .unavailable = noText else { return XCTFail("clip chosen without text: \(noText)") }
        let player = RecordingPlayer()
        let speaker = VoiceSpeaker(synthesizers: [StubSpeechSynthesizer()], prerendered: OneClipLibrary(clip: unreviewed), player: player)
        let result = await speaker.speak(SpokenText("Fatra", language: lang("ht")), sourceKey: good.key, privacy: VoicePrivacy(), language: .ht)
        XCTAssertNotNil(result.unavailable)
        let played = await player.played
        XCTAssertTrue(played.isEmpty)
    }
}
