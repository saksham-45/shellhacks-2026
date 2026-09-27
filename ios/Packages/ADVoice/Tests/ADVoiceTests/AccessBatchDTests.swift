import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// myAD Access review: S3 (stop policy), S4 (screen-reader gate), S8 (commands on the Creole path).
final class AccessBatchDTests: XCTestCase {
    // MARK: S3
    actor CountingStop: StoppablePlayback {
        var stops = 0
        func stop() async { stops += 1 }
    }

    func testStopPolicy() {
        XCTAssertTrue(PlaybackStopPolicy.shouldStop(on: .focusChanged(source: .voiceOver, element: nil)))
        XCTAssertFalse(PlaybackStopPolicy.shouldStop(on: .focusChanged(source: .switchControl, element: nil)))
        XCTAssertTrue(PlaybackStopPolicy.shouldStop(on: .screenDisappeared))
        XCTAssertTrue(PlaybackStopPolicy.shouldStop(on: .sceneLeftForeground))
        XCTAssertFalse(PlaybackStopPolicy.shouldStop(on: .sceneBecameActive))
        XCTAssertFalse(PlaybackStopPolicy.shouldStop(on: .magicTap), "Magic Tap is the app's call")
    }

    func testStopperStopsEveryTargetOnlyWhenThePolicySays() async {
        let a = CountingStop(), b = CountingStop()
        let stopper = PlaybackStopper([a, b])
        let ignored = await stopper.handle(.magicTap)
        XCTAssertFalse(ignored)
        let stopped = await stopper.handle(.focusChanged(source: .voiceOver, element: nil))
        XCTAssertTrue(stopped)
        let sa = await a.stops, sb = await b.stops
        XCTAssertEqual([sa, sb], [1, 1])
    }

    func testStopperStopsARealKreyolPlayAndVoiceSpeaker() async {
        let player = KreyolAudioTests.RecordingPlayer(blocks: true)
        let key = StringKey(key: "card.test.title", table: "Cards")
        let clip = PrerenderedClip(key: key, language: lang("ht"), contentHash: SHA256.hex(Data("Fatra".utf8)),
                                   fileURL: URL(fileURLWithPath: "/c.m4a"), reviewed: true)
        let audio = KreyolAudio(library: OneClipLibrary(clip: clip), player: player, restOnScreenText: nil)
        let stopper = PlaybackStopper([audio, VoiceSpeaker(synthesizers: [])])
        let task = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        while !(await player.isPlaying) { await Task.yield() }
        await stopper.handle(.screenDisappeared)
        let r = await task.value
        XCTAssertEqual(r, .stopped)
    }

    // MARK: S4
    actor HeldGate: ScreenReaderGate {
        var waitingCount = 0
        private var c: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { c != nil }
        func waitUntilQuiet() async { waitingCount += 1; await withCheckedContinuation { c = $0 } }
        func cancelWait() async { release() }
        func release() { c?.resume(); c = nil }
    }

    func setup(gate: HeldGate) -> (KreyolAudio, KreyolAudioTests.RecordingPlayer, StringKey) {
        let player = KreyolAudioTests.RecordingPlayer()
        let key = StringKey(key: "card.test.title", table: "Cards")
        let clip = PrerenderedClip(key: key, language: lang("ht"), contentHash: SHA256.hex(Data("Fatra".utf8)),
                                   fileURL: URL(fileURLWithPath: "/c.m4a"), reviewed: true)
        return (KreyolAudio(library: OneClipLibrary(clip: clip), player: player, restOnScreenText: nil, gate: gate), player, key)
    }

    func testPlayWaitsForTheScreenReader() async {
        let gate = HeldGate()
        let (audio, player, key) = setup(gate: gate)
        let task = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        while !(await gate.isWaiting) { await Task.yield() }
        let before = await player.played
        XCTAssertTrue(before.isEmpty, "nothing plays while VoiceOver is speaking")
        await gate.release()
        let r = await task.value
        XCTAssertEqual(r, .played)
        let after = await player.played
        XCTAssertEqual(after.count, 1)
    }

    func testStopDuringTheWaitIsStoppedAndNothingPlays() async {
        let gate = HeldGate()
        let (audio, player, key) = setup(gate: gate)
        let task = Task { await audio.playKreyol(cardKey: key, text: "Fatra") }
        while !(await gate.isWaiting) { await Task.yield() }
        await audio.stop()
        let r = await task.value
        XCTAssertEqual(r, .stopped)
        let played = await player.played
        XCTAssertTrue(played.isEmpty)
    }

    // MARK: S8
    func router(_ heard: [String: (text: String, confidence: Double)], server: FakeRecognizer? = nil) throws -> (SpeechInputRouter, FakeRecognizer) {
        let onDevice = FakeRecognizer("apple.sfspeech", location: .onDevice, heard: heard)
        let rs: [any SpeechRecognizing] = [onDevice] + (server.map { [$0] } ?? [])
        return (SpeechInputRouter(recognizers: rs, detector: try TextLanguageDetector.bundled()), onDevice)
    }

    func testEnEspanolOnCreoleSurfaceWithNoCreoleEngineIsACommandWithoutConfirmation() async throws {
        let (r, _) = try router(["es": ("en español", 0.9), "en": ("in a spaniel", 0.3)])
        let out = await r.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht")))
        guard case .heard(let rec) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(rec.command, "switch_language_es")
        XCTAssertFalse(rec.needsConfirmation, "C3: an exact on-device phrase match leaves no recognition doubt")
        XCTAssertEqual(rec.language, lang("es"))
    }

    func testNonCommandSpanishOnCreoleSurfaceKeepsTheUnavailableOutcome() async throws {
        let (r, _) = try router(["es": ("dónde queda la oficina del condado", 0.9)])
        let out = await r.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht")))
        XCTAssertEqual(out, .unavailable(.noEngine(lang("ht"))))
    }

    func testNeverSendVoiceSendsNothingToTheServer() async throws {
        let server = FakeRecognizer("server.proxy", location: .server, heard: ["ht": ("Kote biwo a?", 0.7)])
        let (r, _) = try router(["es": ("atrás", 0.9)], server: server)
        let never = VoicePrivacy(cloudVoiceConsent: true, neverSendVoice: true, isOnline: true)
        let cmd = await r.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"), privacy: never))
        guard case .heard(let rec) = cmd else { return XCTFail("\(cmd)") }
        XCTAssertEqual(rec.command, "back")
        XCTAssertFalse(rec.needsConfirmation)
        let (r2, _) = try router(["es": ("quiero ayuda con la renta", 0.9)], server: server)
        let q = await r2.listen(recording, context: ListenContext(surface: .ht, thinkIn: lang("ht"), privacy: never))
        XCTAssertEqual(q, .unavailable(.neverSendVoice(lang("ht"))))
        let asked = await server.asked
        XCTAssertTrue(asked.isEmpty, "never-send-voice: no audio to the server")
    }
}
