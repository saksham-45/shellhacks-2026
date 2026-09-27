import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// myAD Access review (locale-voice-review.md): B1, S1, S2, S5, S6, S7, S10, S11, strings.
final class AccessBatchCTests: XCTestCase {
    /// Offers es/en on-device voices; `speak` records the segment and waits until stop().
    actor BlockingSynth: SpeechSynthesizing {
        nonisolated let id: EngineID = "blocking"
        nonisolated let location: EngineLocation = .onDevice
        var spoken: [SpokenText.Segment] = []
        private var waiting: CheckedContinuation<Void, Never>?
        var isSpeaking: Bool { waiting != nil }
        func voices(for language: Locale.Language) async -> [VoiceInfo] {
            ["es", "en"].contains(language.minimalIdentifier)
                ? [VoiceInfo(identifier: "b.\(language.minimalIdentifier)", language: language, quality: .enhanced, engine: id, location: .onDevice)] : []
        }
        func speak(_ segment: SpokenText.Segment, voice: VoiceInfo) async throws {
            spoken.append(segment)
            await withCheckedContinuation { waiting = $0 }
        }
        func stop() async { waiting?.resume(); waiting = nil }
    }

    // B1
    func testStopMidCardSpeaksNoFurtherSegments() async {
        let synth = BlockingSynth()
        let speaker = VoiceSpeaker(synthesizers: [synth])
        let text = SpokenText(segments: [.init("Mañana pasan la basura. ", language: lang("es")),
                                         .init("Miami-Dade ", language: lang("en")), .init("lo confirma.", language: lang("es"))])
        let task = Task { await speaker.speak(text, privacy: VoicePrivacy(), language: .es) }
        while !(await synth.isSpeaking) { await Task.yield() }
        await speaker.stop()
        let result = await task.value
        XCTAssertEqual(result.segments, [.stopped, .stopped, .stopped])
        XCTAssertTrue(result.wasStopped)
        XCTAssertFalse(result.isFullySpoken)
        let spoken = await synth.spoken
        XCTAssertEqual(spoken.count, 1, "no segment after stop")
    }

    // S7
    func testOnlyTheFallbackSegmentIsRefused() async {
        let stub = StubSpeechSynthesizer()
        let speaker = VoiceSpeaker(synthesizers: [stub])
        let text = SpokenText(segments: [.init("Pregunte en ", language: lang("es")),
                                         .init("Test Desk", language: lang("en"), isFallback: true),
                                         .init(" hoy.", language: lang("es"))])
        let result = await speaker.speak(text, privacy: VoicePrivacy(), language: .es)
        guard case .played = result.segments[0], case .unavailable(let u) = result.segments[1], case .played = result.segments[2] else {
            return XCTFail("\(result.segments)")
        }
        XCTAssertEqual(u.reason, .untranslatedFallback)
        XCTAssertEqual(u.labeledAlternatives, [.en])
        let spoken = await stub.spoken
        XCTAssertEqual(spoken.map(\.text), ["Pregunte en ", " hoy."])
    }

    // S6
    func testMissingKeyInsideASentenceIsNeverSpoken() async {
        let reg = CatalogRegistry([ADLocaleResources.registration])
        let l = Localizer(registry: reg, surface: .es)
        let sentence = l.text(ADLocaleKey.listPair, .text(l.text(StringKey(key: "desk.nope", table: "ADCityPack"))), .name("Miami"))
        XCTAssertTrue(sentence.isMissing, "missing flag reaches the sentence")
        XCTAssertTrue(sentence.spoken.containsMissing)
        let stub = StubSpeechSynthesizer()
        let result = await VoiceSpeaker(synthesizers: [stub]).speak(sentence.spoken, privacy: VoicePrivacy(), language: .es)
        let spoken = await stub.spoken
        XCTAssertFalse(spoken.contains { $0.text.contains("⟦") }, "the marker is never read: \(spoken)")
        XCTAssertTrue(result.segments.contains { if case .unavailable(let u) = $0 { u.reason == .missingText && u.notice == VoiceKey.textMissing } else { false } })
    }

    // S5
    func testCreoleWithoutAnyServerVoiceShowsTheCreoleNoticeNotConsent() async {
        let route = VoicePolicy.route(for: lang("ht"), offers: [], prerendered: nil, privacy: VoicePrivacy())
        guard case .unavailable(let u) = route else { return XCTFail("\(route)") }
        XCTAssertEqual(u.notice, VoiceKey.unavailableCreole)
        let speaker = VoiceSpeaker(synthesizers: [StubSpeechSynthesizer()])
        for privacy in [VoicePrivacy(), VoicePrivacy(isOnline: false), consented] {
            let r = await speaker.route(.init("Bonjou", language: lang("ht")), sourceKey: nil, privacy: privacy)
            guard case .unavailable(let u2) = r else { return XCTFail("\(r)") }
            XCTAssertEqual(u2.notice, VoiceKey.unavailableCreole, "\(privacy)")
        }
        let server = voice("ht", engine: "server.proxy", at: .server)
        guard case .unavailable(let u3) = VoicePolicy.route(for: lang("ht"), offers: [server], prerendered: nil, privacy: VoicePrivacy()) else { return XCTFail() }
        XCTAssertEqual(u3.notice, VoiceKey.consentReadAloud, "consent only when a server voice exists")
    }

    // S1
    actor LoadingPlayer: ClipPlayer {
        var started: [URL] = []
        var loading = false
        private var stopped = false
        private var gate: CheckedContinuation<Void, Never>?
        func beginSession() async { stopped = false }
        func play(_ url: URL) async throws {
            loading = true
            await withCheckedContinuation { gate = $0 }   // "loading"
            loading = false
            if stopped { return }                          // contract: a stop during load wins
            started.append(url)
        }
        func stop() async { stopped = true }
        func finishLoading() { gate?.resume(); gate = nil }
    }

    func testStopDuringLoadIsStoppedAndNothingPlays() async {
        let url = URL(fileURLWithPath: "/clips/card.test.title.m4a")
        let key = StringKey(key: "card.test.title", table: "Cards")
        let clip = PrerenderedClip(key: key, language: lang("ht"), contentHash: SHA256.hex(Data("Fatra".utf8)), fileURL: url, reviewed: true)
        let player = LoadingPlayer()
        let audio = KreyolAudio(library: OneClipLibrary(clip: clip), player: player, restOnScreenText: nil)
        let task = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        while !(await player.loading) { await Task.yield() }
        await audio.stop()
        await player.finishLoading()
        let r = await task.value
        XCTAssertEqual(r, .stopped)
        let started = await player.started
        XCTAssertTrue(started.isEmpty)
    }

    // S2
    func testEveryNonPlayedResultHasANotice() {
        let k = StringKey(key: "card.a", table: "Cards")
        XCTAssertNil(KreyolPlayback.played.notice)
        XCTAssertNil(KreyolPlayback.stopped.notice)
        XCTAssertEqual(KreyolPlayback.partial(played: [k], missing: [.live(label: "305")]).notice, VoiceKey.kreyolRestOnScreen)
        XCTAssertEqual(KreyolPlayback.noClip(notice: VoiceKey.kreyolNoRecording).notice, VoiceKey.kreyolNoRecording)
        XCTAssertEqual(KreyolPlayback.failed(played: [], missing: [.live(label: "305")]).notice, VoiceKey.kreyolCouldNotPlay)
    }

    // S11
    func testCreoleNoticeOrder() {
        XCTAssertEqual(VoiceKey.creoleNotice(for: .noVoice), [VoiceKey.unavailableCreole, VoiceKey.creoleVoiceOverLimit])
        XCTAssertEqual(VoiceKey.creoleNotice(for: .noRecording), [VoiceKey.kreyolNoRecording, VoiceKey.creoleVoiceOverLimit])
    }

    // S10
    func testMicInputLabelsOnePhrasePerKeyAndHtAddsEsEn() {
        let es = VoiceKey.micInputLabels(surface: .es)
        XCTAssertEqual(es.map(\.language), [.es, .es])
        let ht = VoiceKey.micInputLabels(surface: .ht)
        XCTAssertEqual(ht.map(\.language), [.ht, .ht, .es, .es, .en, .en], "Voice Control does not recognize Creole")
        XCTAssertEqual(VoiceKey.micStopInputLabels(surface: .en).map(\.key), [VoiceKey.micStopInputStopListening])
        let reg = CatalogRegistry([ADVoiceResources.registration])
        for surface in SurfaceLanguage.allCases {
            for label in VoiceKey.micInputLabels(surface: surface) + VoiceKey.micStopInputLabels(surface: surface) {
                let t = Localizer(registry: reg, surface: label.language).text(label.key)
                XCTAssertFalse(t.isMissing || t.isFallback, "\(label)")
                XCTAssertFalse(t.plain.contains(","), "one phrase per key: \(t.plain)")
            }
        }
        XCTAssertEqual(Localizer(registry: reg, surface: .en).text(VoiceKey.micInputTalk).plain.lowercased(),
                       Localizer(registry: reg, surface: .en).text(VoiceKey.micLabel).plain.lowercased(), "label in name")
    }

    // S9 / N1
    func testHintStatesResultAndLanguageNameIsKreyol() {
        let reg = CatalogRegistry([ADVoiceResources.registration])
        for s in SurfaceLanguage.allCases {
            let hint = Localizer(registry: reg, surface: s).text(VoiceKey.micHint).plain.lowercased()
            XCTAssertFalse(hint.contains("double") || hint.contains("toque dos") || hint.contains("tape de"), hint)
        }
        for s in [SurfaceLanguage.es, .en] {
            for key in VoiceKey.all {
                let v = Localizer(registry: reg, surface: s).text(key).plain.lowercased()
                XCTAssertFalse(v.contains("creole") || v.contains("criollo"), "\(key.key) \(s): \(v)")
            }
        }
    }
}
