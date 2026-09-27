import XCTest
import Foundation
import ADCore
import ADLocale
@testable import ADVoice

/// myAD Access re-check round 3: F1, F3, F4, F5, C1, C2, C3, required `language:`.
final class AccessRound3Tests: XCTestCase {
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 100
        var now: TimeInterval { lock.withLock { t } }
    }
    actor CountingStop: StoppablePlayback {
        var stops = 0
        func stop() async { stops += 1 }
    }

    // MARK: F1
    func testFocusGraceWindowSourceAndOrigin() async {
        let clock = TestClock()
        let target = CountingStop()
        let stopper = PlaybackStopper([target], now: { clock.now })
        let button = PlaybackOrigin("card.readButton"), other = PlaybackOrigin("card.body")
        stopper.playbackWillStart(origin: button)
        var r = await stopper.handle(.focusChanged(source: .voiceOver, element: other), at: 100.0)
        XCTAssertFalse(r, "before the first clip starts (screen-reader wait): ignored")
        stopper.playbackStarted(at: 100.0)
        r = await stopper.handle(.focusChanged(source: .voiceOver, element: other), at: 100.03)
        XCTAssertFalse(r, "30 ms after start: ignored")
        r = await stopper.handle(.focusChanged(source: .switchControl, element: other), at: 105)
        XCTAssertFalse(r, "Switch Control focus never stops")
        r = await stopper.handle(.focusChanged(source: .other, element: other), at: 105)
        XCTAssertFalse(r)
        r = await stopper.handle(.focusChanged(source: .voiceOver, element: button), at: 105)
        XCTAssertFalse(r, "focus on the element that started playback never stops")
        var stops = await target.stops
        XCTAssertEqual(stops, 0)
        r = await stopper.handle(.focusChanged(source: .voiceOver, element: other), at: 100.6)
        XCTAssertTrue(r, "0.6 s after start: the next gesture stops")
        stops = await target.stops
        XCTAssertEqual(stops, 1)
    }

    func testScreenDisappearStopsImmediately() async {
        let target = CountingStop()
        let stopper = PlaybackStopper([target], now: { 100 })
        stopper.playbackWillStart(origin: nil)
        stopper.playbackStarted(at: 100)
        let r = await stopper.handle(.screenDisappeared, at: 100.01)
        XCTAssertTrue(r)
        let stops = await target.stops
        XCTAssertEqual(stops, 1)
    }

    actor StartRecorder: PlaybackStartListener {
        var count = 0
        func playbackStarted() async { count += 1 }
    }

    func testPlayersReportTheFirstStart() async {
        let rec = StartRecorder()
        let speaker = VoiceSpeaker(synthesizers: [StubSpeechSynthesizer()])
        await speaker.setStartListener(rec)
        _ = await speaker.speak(SpokenText(segments: [.init("Hola. ", language: lang("es")), .init("Adiós.", language: lang("es"))]),
                                privacy: VoicePrivacy(), language: .es)
        let n = await rec.count
        XCTAssertEqual(n, 1, "once per read, at the first segment")
        let rec2 = StartRecorder()
        let (audio, _, key) = setupAudio(gate: NoScreenReaderGate())
        await audio.setStartListener(rec2)
        _ = await audio.playKreyol(cardKey: key, text: "Fatra")
        let n2 = await rec2.count
        XCTAssertEqual(n2, 1)
    }

    // MARK: F3
    final class StubGate: ScreenReaderGate, @unchecked Sendable {
        let quiet = QuietWait()
        let preRegister: TimeInterval
        let timeout: Duration
        init(preRegister: TimeInterval = 0, timeout: Duration = .seconds(5)) {
            self.preRegister = preRegister
            self.timeout = timeout
        }
        func waitUntilQuiet() async {
            if preRegister > 0 {
                // Not cancellable, like the MainActor hop before the real gate registers.
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + preRegister) { c.resume() }
                }
            }
            await quiet.wait(timeout: timeout)
        }
        func cancelWait() async { quiet.resumeCurrent() }
    }

    func setupAudio(gate: any ScreenReaderGate) -> (KreyolAudio, KreyolAudioTests.RecordingPlayer, StringKey) {
        let player = KreyolAudioTests.RecordingPlayer()
        let key = StringKey(key: "card.test.title", table: "Cards")
        let clip = PrerenderedClip(key: key, language: lang("ht"), contentHash: SHA256.hex(Data("Fatra".utf8)),
                                   fileURL: URL(fileURLWithPath: "/c.m4a"), reviewed: true)
        return (KreyolAudio(library: OneClipLibrary(clip: clip), player: player, restOnScreenText: nil, gate: gate), player, key)
    }

    func testSecondPlayDuringTheWaitEndsTheFirstAndBothReturn() async {
        let gate = StubGate()
        let (audio, player, key) = setupAudio(gate: gate)
        let first = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        while !gate.quiet.isWaiting { await Task.yield() }
        let second = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        let r1 = await first.value
        XCTAssertEqual(r1, .stopped, "the first play is superseded and returns")
        while !gate.quiet.isWaiting { await Task.yield() }
        gate.quiet.resumeCurrent()   // VoiceOver finished
        let r2 = await second.value
        XCTAssertEqual(r2, .played)
        let played = await player.played
        XCTAssertEqual(played.count, 1)
    }

    func testStopBeforeTheWaitRegistersIsNotLost() async throws {
        let gate = StubGate(preRegister: 0.2, timeout: .milliseconds(1500))
        let (audio, player, key) = setupAudio(gate: gate)
        let start = Date()
        let play = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        try await Task.sleep(for: .milliseconds(50))
        await audio.stop()
        let r = await play.value
        XCTAssertEqual(r, .stopped)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "no 1.5 s wait")
        let played = await player.played
        XCTAssertTrue(played.isEmpty)
    }

    func testQuietWaitSupersedesAndHonoursCancellation() async {
        let q = QuietWait()
        let a = Task { await q.wait(timeout: .seconds(5)) }
        while !q.isWaiting { await Task.yield() }
        let b = Task { await q.wait(timeout: .seconds(5)) }
        await a.value   // resumed by b
        while !q.isWaiting { await Task.yield() }
        b.cancel()
        await b.value
        XCTAssertFalse(q.isWaiting)
    }

    // MARK: F5 + required language
    func testPunctuationOnlySegmentsAreNotSent() async {
        let stub = StubSpeechSynthesizer()
        let speaker = VoiceSpeaker(synthesizers: [stub])
        let t = SpokenText(segments: [.init("Hola", language: lang("es")), .init(" . ", language: lang("en")),
                                      .init("¿?", language: lang("es")), .init("Miami", language: lang("en"))])
        let r = await speaker.speak(t, privacy: VoicePrivacy(), language: .es)
        XCTAssertEqual(r.segments.count, 2)
        let spoken = await stub.spoken.map(\.text)
        XCTAssertEqual(spoken, ["Hola", "Miami"])
    }

    func testAllFallbackCardAsksInTheSurfaceLanguage() async {
        let speaker = VoiceSpeaker(synthesizers: [StubSpeechSynthesizer()])
        let t = SpokenText(segments: [.init("Bus card.", language: lang("en"), isFallback: true)])
        let r = await speaker.speak(t, privacy: VoicePrivacy(), language: .ht)
        XCTAssertEqual(r.unavailable?.language, lang("ht"))
        XCTAssertEqual(r.unavailable?.labeledAlternatives, [.en])
    }

    func router(_ heard: [String: (text: String, confidence: Double)], server: FakeRecognizer? = nil) throws -> (SpeechInputRouter, FakeRecognizer) {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice, heard: heard)
        let rs: [any SpeechRecognizing] = [onDevice] + (server.map { [$0] } ?? [])
        return (SpeechInputRouter(recognizers: rs, detector: try TextLanguageDetector.bundled()), onDevice)
    }

    // MARK: C1
    func testCommandsOnlyNoticeTagsEachPhraseWithItsLanguage() throws {
        let lexicon = try CommandLexicon.bundled()
        let reg = CatalogRegistry([ADVoiceResources.registration])
        let ht = VoiceKey.creoleCommandsOnlyNotice(Localizer(registry: reg, surface: .ht), lexicon: lexicon)
        XCTAssertFalse(ht.isMissing)
        func run(_ t: ResolvedText, _ text: String) -> Locale.Language? { t.runs.first { $0.text == text }?.language }
        XCTAssertEqual(run(ht, "en español"), lang("es"))
        XCTAssertEqual(run(ht, "in English"), lang("en"))
        XCTAssertEqual(run(ht, "atrás"), lang("es"), "the es/en engines hear 'atrás' on the ht surface")
        let en = VoiceKey.creoleCommandsOnlyNotice(Localizer(registry: reg, surface: .en), lexicon: lexicon)
        XCTAssertEqual(en.plain, "I can't understand Kreyòl here yet. You can say \"en español\", \"in English\" or \"back\", or use the buttons.")
        let es = VoiceKey.creoleCommandsOnlyNotice(Localizer(registry: reg, surface: .es), lexicon: lexicon)
        XCTAssertEqual(es.plain, "Todavía no entiendo Kreyòl aquí. Puede decir \"en español\", \"in English\" o \"atrás\", o usar los botones.")
        // Every quoted phrase really is accepted by the lexicon.
        for surface in SurfaceLanguage.allCases {
            for p in VoiceKey.commandsOnlyPhrases(surface: surface, lexicon: lexicon) {
                XCTAssertFalse(lexicon.match(p.text, in: [p.language]).isEmpty, "\(p)")
            }
        }
    }

    func testCommandsOnlyNoticeIsUsedOnlyOnHtWhenCommandsWork() async throws {
        let ht = lang("ht")
        XCTAssertEqual(ListenUnavailable.noEngine(ht).messageKey(surface: .ht, commandsOnlyAvailable: true), VoiceKey.creoleCommandsOnly)
        XCTAssertEqual(ListenUnavailable.neverSendVoice(ht).messageKey(surface: .ht, commandsOnlyAvailable: true), VoiceKey.creoleCommandsOnly)
        XCTAssertEqual(ListenUnavailable.noEngine(ht).messageKey(surface: .ht, commandsOnlyAvailable: false), VoiceKey.noSpeechIn)
        XCTAssertEqual(ListenUnavailable.noEngine(ht).messageKey(surface: .es, commandsOnlyAvailable: true), VoiceKey.noSpeechIn)
        XCTAssertEqual(ListenUnavailable.offline(ht).messageKey(surface: .ht, commandsOnlyAvailable: true), VoiceKey.creoleNeedsInternet)
        let (r, _) = try router(["es": ("hola", 0.9)])
        let available = await r.commandsOnlyAvailable()
        XCTAssertTrue(available)
        let none = SpeechInputRouter(recognizers: [], detector: try TextLanguageDetector.bundled())
        let unavailable = await none.commandsOnlyAvailable()
        XCTAssertFalse(unavailable)
    }

    // MARK: C2 + C3
    func testCommandsWorkOfflineAndBeforeConsentAndSendNothing() async throws {
        let server = FakeRecognizer("server.proxy", location: .server, heard: ["ht": ("Kote biwo a?", 0.7)])
        let (r, _) = try router(["es": ("en español", 0.9)], server: server)
        for privacy in [VoicePrivacy(cloudVoiceConsent: true, isOnline: false), VoicePrivacy(cloudVoiceConsent: false, isOnline: true)] {
            let out = await r.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"), privacy: privacy))
            guard case .heard(let rec) = out else { return XCTFail("\(privacy): \(out)") }
            XCTAssertEqual(rec.command, "switch_language_es")
            XCTAssertFalse(rec.needsConfirmation, "exact on-device phrase match")
        }
        let (r2, _) = try router(["es": ("quiero ayuda con la renta", 0.9)], server: server)
        let offline = await r2.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"),
                                                                       privacy: VoicePrivacy(cloudVoiceConsent: true, isOnline: false)))
        XCTAssertEqual(offline, .unavailable(.offline(lang("ht"))), "not a command: the notice stays")
        let noConsent = await r2.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"), privacy: VoicePrivacy()))
        XCTAssertEqual(noConsent, .unavailable(.consentRequired(lang("ht"))))
        let asked = await server.asked
        XCTAssertTrue(asked.isEmpty, "nothing sent to the server")
    }
}
