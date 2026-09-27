import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// myAD Access re-check round 2: R1-R4, read-aloud consent, R7, R8, R6.
final class AccessRound2Tests: XCTestCase {
    actor Flag { var value = false; func set() { value = true } }

    typealias Blocking = AccessBatchCTests.BlockingSynth

    nonisolated static func text(_ tag: String) -> SpokenText {
        SpokenText(segments: [.init("\(tag)1 hola. ", language: lang("es")), .init("\(tag)2 Miami ", language: lang("en")),
                              .init("\(tag)3 adiós.", language: lang("es"))])
    }

    // R1
    func testANewReadSupersedesTheEarlierOneNoInterleave() async {
        let synth = Blocking()
        let speaker = VoiceSpeaker(synthesizers: [synth])
        let ta = Self.text("A"), tb = Self.text("B")
        let a = Task { await speaker.speak(ta, privacy: VoicePrivacy(), language: .es) }
        while !(await synth.isSpeaking) { await Task.yield() }
        let flag = Flag()
        let b = Task {
            let r = await speaker.speak(tb, privacy: VoicePrivacy(), language: .es)
            await flag.set()
            return r
        }
        let ra = await a.value
        XCTAssertTrue(ra.wasStopped, "A stops once B starts")
        // Let B run to the end (each release finishes one segment).
        while !(await flag.value) {
            if await synth.isSpeaking { await synth.stop() }
            await Task.yield()
        }
        let rb = await b.value
        XCTAssertTrue(rb.isFullySpoken, "\(rb.segments)")
        let spoken = await synth.spoken.map { String($0.text.prefix(2)) }
        XCTAssertEqual(spoken, ["A1", "B1", "B2", "B3"])
    }

    func testStopBeforeTheReadStartsStopsTheWholeRead() async {
        let stub = StubSpeechSynthesizer()
        let speaker = VoiceSpeaker(synthesizers: [stub])
        let id = await speaker.beginRead()
        await speaker.stop()
        let r = await speaker.speak(Self.text("A"), privacy: VoicePrivacy(), language: .es, readID: id)
        XCTAssertEqual(r.segments, [.stopped, .stopped, .stopped])
        let spoken = await stub.spoken
        XCTAssertTrue(spoken.isEmpty)
        let next = await speaker.speak(Self.text("B"), privacy: VoicePrivacy(), language: .es)
        XCTAssertTrue(next.isFullySpoken, "a later read is not affected")
    }

    // R2
    actor CountingServer: SpeechSynthesizing {
        nonisolated let id: EngineID = "server.proxy"
        nonisolated let location: EngineLocation = .server
        var voiceQueries = 0
        func voices(for language: Locale.Language) async -> [VoiceInfo] {
            voiceQueries += 1
            return [VoiceInfo(identifier: "s.ht", language: lang("ht"), quality: .premium, engine: id, location: .server)]
        }
        func speak(_ segment: SpokenText.Segment, voice: VoiceInfo) async throws {}
        func stop() async {}
    }

    func testUnconfiguredServerNeverAsksConsentOrInternet() async {
        let speaker = VoiceSpeaker(synthesizers: [ServerProxySpeechEngine(transport: nil)])
        for privacy in [VoicePrivacy(isOnline: false), VoicePrivacy(isOnline: false, readAloudConsent: true),
                        VoicePrivacy(), consented] {
            let r = await speaker.route(.init("Bonjou", language: lang("ht")), sourceKey: nil, privacy: privacy)
            guard case .unavailable(let u) = r else { return XCTFail("\(r)") }
            XCTAssertEqual(u.notice, VoiceKey.unavailableCreole, "\(privacy)")
        }
    }

    func testServerVoicesAreNotQueriedBeforeReadAloudConsent() async {
        let server = CountingServer()
        let speaker = VoiceSpeaker(synthesizers: [server])
        let r = await speaker.route(.init("Bonjou", language: lang("ht")), sourceKey: nil,
                                    privacy: VoicePrivacy(cloudVoiceConsent: true, isOnline: true))
        guard case .unavailable(let u) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(u.notice, VoiceKey.consentReadAloud, "voice-input consent is not read-aloud consent")
        let q = await server.voiceQueries
        XCTAssertEqual(q, 0, "no server contact before consent")
        let r2 = await speaker.route(.init("Bonjou", language: lang("ht")), sourceKey: nil,
                                     privacy: VoicePrivacy(isOnline: true, readAloudConsent: true))
        guard case .voice = r2 else { return XCTFail("\(r2)") }
    }

    func testNeverSendVoiceBlocksServerReadAloudAndLabelSaysSo() {
        let server = voice("ht", engine: "server.proxy", at: .server)
        let r = VoicePolicy.route(for: lang("ht"), offers: [server], prerendered: nil,
                                  privacy: VoicePrivacy(neverSendVoice: true, readAloudConsent: true))
        guard case .unavailable = r else { return XCTFail("\(r)") }
        let reg = CatalogRegistry([ADVoiceResources.registration])
        XCTAssertTrue(Localizer(registry: reg, surface: .en).text(VoiceKey.neverSendVoice).plain.contains("card text"))
        let consent = Localizer(registry: reg, surface: .en).text(VoiceKey.consentReadAloud).plain
        XCTAssertFalse(consent.lowercased().contains("keep"), "no unverified retention promise")
    }

    // R4 + R6
    func testMissingTextNoticeAndNoBareStopLabel() {
        let reg = CatalogRegistry([ADVoiceResources.registration])
        XCTAssertEqual(Localizer(registry: reg, surface: .en).text(VoiceKey.textMissing).plain, "Part of this text is missing, so it was skipped.")
        XCTAssertEqual(Localizer(registry: reg, surface: .es).text(VoiceKey.textMissing).plain, "Falta una parte de este texto, así que no se leyó.")
        XCTAssertEqual(VoiceKey.micStopInputLabels(surface: .ht).map(\.language), [.ht, .es, .en])
        XCTAssertTrue(Localizer(registry: reg, surface: .en).text(StringKey(key: "mic.stopInputLabel.stop", table: "ADVoice")).isMissing)
    }

    // R7b + R8
    func testAllNoticesAndEmptyText() async {
        let speaker = VoiceSpeaker(synthesizers: [StubSpeechSynthesizer()])
        let t = SpokenText(segments: [.init("Title", language: lang("en"), isFallback: true), .init(" hola ", language: lang("es")),
                                      .init("⟦ADCityPack:desk.x⟧", language: lang("es"), isMissing: true)])
        let r = await speaker.speak(t, privacy: VoicePrivacy(), language: .es)
        XCTAssertEqual(r.notices.map(\.notice), [ADLocaleKey.fallbackEnglishHint, VoiceKey.textMissing])
        let empty = await speaker.speak(SpokenText(segments: []), privacy: VoicePrivacy(), language: .es)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(empty.isFullySpoken, "empty text is not fully spoken")
    }
}
