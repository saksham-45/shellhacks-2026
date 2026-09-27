import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// Play in Kreyòl: only a native-reviewed clip whose hash matches the current text; never TTS.
final class KreyolAudioTests: XCTestCase {
    let key = StringKey(key: "card.test.title", table: "Cards")
    let text = "Demen, fatra"
    let url = URL(fileURLWithPath: "/clips/card.test.title.ht.m4a")

    struct StubLibrary: PrerenderedAudioLibrary {
        var clips: [String: PrerenderedClip] = [:]
        init(clip: PrerenderedClip?) { if let clip, let k = clip.key { clips[k.key] = clip } }
        init(_ list: [PrerenderedClip]) { for c in list { if let k = c.key { clips[k.key] = c } } }
        func clip(for key: StringKey, language: Locale.Language, text: String) -> PrerenderedClip? { clips[key.key] }
    }

    actor RecordingPlayer: ClipPlayer {
        var played: [URL] = []
        var stops = 0
        let blocks: Bool
        private var waiting: CheckedContinuation<Void, Never>?
        init(blocks: Bool = false) { self.blocks = blocks }
        func play(_ url: URL) async throws {
            played.append(url)
            if blocks { await withCheckedContinuation { waiting = $0 } }
        }
        func stop() async {
            stops += 1
            waiting?.resume()
            waiting = nil
        }
        var isPlaying: Bool { waiting != nil }
        func release() { waiting?.resume(); waiting = nil }
    }

    func clip(reviewed: Bool, hashOf s: String? = nil) -> PrerenderedClip {
        PrerenderedClip(key: key, language: lang("ht"), contentHash: SHA256.hex(Data((s ?? text).utf8)), fileURL: url, reviewed: reviewed)
    }

    func testNoClipGivesNoticeAndNeverCallsThePlayer() async {
        let player = RecordingPlayer()
        let audio = KreyolAudio(library: StubLibrary(clip: nil), player: player)
        let r = await audio.playKreyol(cardKey: key, text: text)
        XCTAssertEqual(r, .noClip(notice: VoiceKey.kreyolNoRecording))
        let played = await player.played
        XCTAssertTrue(played.isEmpty)
    }

    func testUnreviewedClipGivesNoClip() async {
        let player = RecordingPlayer()
        let r = await KreyolAudio(library: StubLibrary(clip: clip(reviewed: false)), player: player).playKreyol(cardKey: key, text: text)
        XCTAssertEqual(r, .noClip(notice: VoiceKey.kreyolNoRecording))
        let played = await player.played
        XCTAssertTrue(played.isEmpty)
    }

    func testChangedTextHashMismatchGivesNoClip() async {
        let player = RecordingPlayer()
        let audio = KreyolAudio(library: StubLibrary(clip: clip(reviewed: true, hashOf: "Demen, fatra ak resiklaj")), player: player)
        let r = await audio.playKreyol(cardKey: key, text: text)
        XCTAssertEqual(r, .noClip(notice: VoiceKey.kreyolNoRecording))
        let played = await player.played
        XCTAssertTrue(played.isEmpty)
    }

    func testReviewedMatchingClipPlaysItsURL() async {
        let player = RecordingPlayer()
        let r = await KreyolAudio(library: StubLibrary(clip: clip(reviewed: true)), player: player).playKreyol(cardKey: key, text: text)
        XCTAssertEqual(r, .played)
        let played = await player.played
        XCTAssertEqual(played, [url])
    }

    func testStopDuringPlaybackReturnsStopped() async {
        let player = RecordingPlayer(blocks: true)
        let audio = KreyolAudio(library: StubLibrary(clip: clip(reviewed: true)), player: player)
        let k = key, t = text
        let task = Task { await audio.playKreyol(cardKey: k, text: t) }
        while !(await player.isPlaying) { await Task.yield() }
        await audio.stop()
        let r = await task.value
        XCTAssertEqual(r, .stopped)
        let stops = await player.stops
        XCTAssertEqual(stops, 1)
    }

    /// Structural: KreyolAudio's only stored dependencies are a library and a ClipPlayer; it
    /// has no synthesizer or server transport to fall back to.
    func testHoldsNoSynthesizerOrTransport() {
        let audio = KreyolAudio(library: StubLibrary(clip: nil), player: RecordingPlayer())
        let children = Mirror(reflecting: audio).children
        XCTAssertFalse(children.contains { $0.value is any SpeechSynthesizing })
        XCTAssertFalse(children.contains { $0.value is [any SpeechSynthesizing] })
        XCTAssertEqual(Set(children.compactMap(\.label).filter { !$0.hasPrefix("$") }), ["library", "player", "restOnScreenText", "gate", "generation", "stoppedGeneration", "active", "gateWait", "startListener"])
    }

    func testManifestEntryWithoutReviewedIsUnreviewedAndDropped() throws {
        let hash = SHA256.hex(Data(text.utf8))
        let json = """
        { "clips": [
          { "table": "Cards", "key": "card.test.title", "language": "ht", "sha256": "\(hash)", "file": "a.m4a" },
          { "table": "Cards", "key": "card.other.title", "language": "ht", "sha256": "\(hash)", "file": "b.m4a", "reviewed": false },
          { "table": "Cards", "key": "card.ok.title", "language": "ht", "sha256": "\(hash)", "file": "c.m4a", "reviewed": true } ] }
        """
        let m = try JSONDecoder().decode(BundledPrerenderedAudio.Manifest.self, from: Data(json.utf8))
        XCTAssertNil(m.clips[0].reviewed)
        XCTAssertFalse(m.clips[0].isReviewed)
        let lib = try BundledPrerenderedAudio(manifest: Data(json.utf8), audioDirectory: URL(fileURLWithPath: "/clips"))
        XCTAssertEqual(lib.count, 1)
        XCTAssertNil(lib.clip(for: key, language: lang("ht"), text: text))
        let ok = lib.clip(for: StringKey(key: "card.ok.title", table: "Cards"), language: lang("ht"), text: text)
        XCTAssertEqual(ok?.reviewed, true)
        XCTAssertEqual(try BundledPrerenderedAudio.bundled().count, 0, "shipped manifest stays empty")
    }

    // MARK: Whole card

    let restText = "Rès la sou ekran an."
    func sclip(_ k: String, _ t: String, table: String = "Cards", reviewed: Bool = true) -> PrerenderedClip {
        PrerenderedClip(key: StringKey(key: k, table: table), language: lang("ht"), contentHash: SHA256.hex(Data(t.utf8)),
                        fileURL: URL(fileURLWithPath: "/clips/\(k).m4a"), reviewed: reviewed)
    }
    func part(_ k: String, _ t: String) -> KreyolPart { .string(key: StringKey(key: k, table: "Cards"), text: t) }

    func testBundledRestTextIsTheCreoleString() {
        XCTAssertEqual(KreyolAudio.bundledRestOnScreenText(), restText)
    }

    func testMixedSequencePlaysInOrderAndLivePartGetsTheRestClip() async {
        let player = RecordingPlayer()
        let lib = StubLibrary([sclip("card.a.title", "A"), sclip("card.a.body", "B"),
                               sclip("kreyol.restOnScreen", restText, table: "ADVoice")])
        let audio = KreyolAudio(library: lib, player: player, restOnScreenText: restText)
        let parts = [part("card.a.title", "A"), .live(label: "305-555-0100"), .live(label: "25 septanm 2026"),
                     part("card.a.body", "B"), part("card.a.unreviewed", "C")]
        let r = await audio.playKreyol(parts: parts)
        XCTAssertEqual(r, .partial(played: [StringKey(key: "card.a.title", table: "Cards"), StringKey(key: "card.a.body", table: "Cards")],
                                   missing: [parts[1], parts[2], parts[4]]))
        let played = await player.played.map(\.lastPathComponent)
        XCTAssertEqual(played, ["card.a.title.m4a", "kreyol.restOnScreen.m4a", "card.a.body.m4a", "kreyol.restOnScreen.m4a"],
                       "rest clip at most once in a row")
    }

    func testNoRestClipStillPartialAndNamesTheMissingPart() async {
        let player = RecordingPlayer()
        let audio = KreyolAudio(library: StubLibrary([sclip("card.a.title", "A"), sclip("card.a.body", "old text")]),
                                player: player, restOnScreenText: restText)
        let parts = [part("card.a.title", "A"), part("card.a.body", "new text")]
        let r = await audio.playKreyol(parts: parts)
        XCTAssertEqual(r, .partial(played: [StringKey(key: "card.a.title", table: "Cards")], missing: [parts[1]]))
        let played = await player.played.map(\.lastPathComponent)
        XCTAssertEqual(played, ["card.a.title.m4a"])
    }

    func testAllMissingGivesNoClipEvenWithRestClip() async {
        let player = RecordingPlayer()
        let audio = KreyolAudio(library: StubLibrary([sclip("kreyol.restOnScreen", restText, table: "ADVoice")]),
                                player: player, restOnScreenText: restText)
        let r = await audio.playKreyol(parts: [.live(label: "305")])
        XCTAssertEqual(r, .noClip(notice: VoiceKey.kreyolNoRecording))
    }

    func testStopMidSequenceHaltsRemainingParts() async {
        let player = RecordingPlayer(blocks: true)
        let audio = KreyolAudio(library: StubLibrary([sclip("card.a.title", "A"), sclip("card.a.body", "B")]),
                                player: player, restOnScreenText: nil)
        let parts = [part("card.a.title", "A"), part("card.a.body", "B")]
        let task = Task { await audio.playKreyol(parts: parts) }
        while !(await player.isPlaying) { await Task.yield() }
        await audio.stop()
        let r = await task.value
        XCTAssertEqual(r, .stopped)
        let played = await player.played.map(\.lastPathComponent)
        XCTAssertEqual(played, ["card.a.title.m4a"], "second part never started")
        let stops = await player.stops
        XCTAssertEqual(stops, 1)
    }

    actor ThrowingPlayer: ClipPlayer {
        struct Broken: Error {}
        let failing: Set<String>
        var played: [String] = []
        init(failing: Set<String>) { self.failing = failing }
        func play(_ url: URL) async throws {
            if failing.contains(url.lastPathComponent) { throw Broken() }
            played.append(url.lastPathComponent)
        }
        func stop() async {}
    }

    func testBrokenFileIsFailedNotNoClip() async {
        let audio = KreyolAudio(library: StubLibrary(clip: clip(reviewed: true)), player: ThrowingPlayer(failing: [url.lastPathComponent]))
        let r = await audio.playKreyol(cardKey: key, text: text)
        XCTAssertEqual(r, .failed(played: [], missing: [.string(key: key, text: text)]))
    }

    func testSequenceWithAThrowingPartIsFailedAndListsMissing() async {
        let player = ThrowingPlayer(failing: ["card.a.body.m4a"])
        let audio = KreyolAudio(library: StubLibrary([sclip("card.a.title", "A"), sclip("card.a.body", "B")]),
                                player: player, restOnScreenText: nil)
        let parts = [part("card.a.title", "A"), part("card.a.body", "B"), .live(label: "305")]
        let r = await audio.playKreyol(parts: parts)
        XCTAssertEqual(r, .failed(played: [StringKey(key: "card.a.title", table: "Cards")], missing: [parts[1], parts[2]]))
        let played = await player.played
        XCTAssertEqual(played, ["card.a.title.m4a"])
    }

    func testOverlappingPlaySupersedesThePreviousOne() async {
        let player = RecordingPlayer(blocks: true)
        let audio = KreyolAudio(library: StubLibrary([sclip("card.a.title", "A"), sclip("card.a.body", "B"), sclip("card.c.title", "C")]),
                                player: player, restOnScreenText: nil)
        let first = [part("card.a.title", "A"), part("card.a.body", "B")]
        let second = [part("card.c.title", "C")]
        let t1 = Task { await audio.playKreyol(parts: first) }
        while !(await player.isPlaying) { await Task.yield() }
        let t2 = Task { await audio.playKreyol(parts: second) }
        let r1 = await t1.value
        XCTAssertEqual(r1, .stopped, "the earlier call is cancelled")
        while true {
            let playing = await player.isPlaying, count = await player.played.count
            if playing && count == 2 { break }
            await Task.yield()
        }
        await player.release()
        let r2 = await t2.value
        XCTAssertEqual(r2, .played)
        let played = await player.played.map(\.lastPathComponent)
        XCTAssertEqual(played, ["card.a.title.m4a", "card.c.title.m4a"], "card A's body never plays over card C")
    }
}
