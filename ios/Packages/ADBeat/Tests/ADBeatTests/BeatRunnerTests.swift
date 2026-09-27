import XCTest
@testable import ADBeat

private struct StubBeat: Beat {
    enum Live: Sendable { case ok, fail, hang }
    let id: BeatID
    var live: Live = .ok
    var liveTimeout: Double? = 0.2
    var countsTowardCounter = true
    var title: BeatTitle { BeatTitle(key: "beat.\(id).title", es: "es", en: "en", ht: "ht") }
    func runLive(_ c: BeatContext) async throws -> BeatOutcome {
        switch live {
        case .ok: return BeatOutcome(beatID: id, mode: .live, spareTheInterpreter: true)
        case .fail: throw URLError(.notConnectedToInternet)
        case .hang: try await Task.sleep(nanoseconds: 5_000_000_000); return BeatOutcome(beatID: id, mode: .live, spareTheInterpreter: true)
        }
    }
    func runCachedReplay(_ c: BeatContext) async throws -> BeatOutcome {
        BeatOutcome(beatID: id, mode: .live, spareTheInterpreter: true) // runner must force .cachedReplay
    }
}

private final class Box: @unchecked Sendable { var outcomes: [BeatOutcome] = [] }

final class BeatRunnerTests: XCTestCase {
    let ctx = BeatContext(language: "es", thinkIn: "es")

    func testLiveRunIsNotReplay() async throws {
        let box = Box()
        let o = try await BeatRunner(demoMode: false).run(StubBeat(id: .feeCheck), context: ctx) { box.outcomes.append($0) }
        XCTAssertEqual(o.mode, .live); XCTAssertFalse(o.isReplay); XCTAssertEqual(box.outcomes.count, 1)
    }
    func testDemoModeAlwaysReplaysWithChip() async throws {
        let box = Box()
        let o = try await BeatRunner(demoMode: true).run(StubBeat(id: .feeCheck), context: ctx) { box.outcomes.append($0) }
        XCTAssertTrue(o.isReplay); XCTAssertEqual(o.fallbackReason, .demoModeOn); XCTAssertEqual(box.outcomes, [o])
    }
    func testLiveTimeoutFallsBackToReplay() async throws {
        let start = Date()
        let o = try await BeatRunner(demoMode: false).run(StubBeat(id: .deskCopilot, live: .hang), context: ctx) { _ in }
        XCTAssertTrue(o.isReplay); XCTAssertEqual(o.fallbackReason, .liveTimedOut(seconds: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testLiveErrorFallsBackToReplay() async throws {
        let o = try await BeatRunner(demoMode: false).run(StubBeat(id: .warmHandoff, live: .fail), context: ctx) { _ in }
        XCTAssertTrue(o.isReplay)
        if case .liveFailed = o.fallbackReason {} else { XCTFail("expected liveFailed") }
    }
    func testCancellationDoesNotComplete() async {
        let box = Box()
        let c = BeatContext(language: "es", thinkIn: "es")
        let t = Task { try await BeatRunner(demoMode: false).run(StubBeat(id: .feeCheck, live: .hang, liveTimeout: nil), context: c) { box.outcomes.append($0) } }
        try? await Task.sleep(nanoseconds: 50_000_000); t.cancel()
        let r = await t.result
        if case .success = r { XCTFail("cancelled run must not succeed") }
        XCTAssertTrue(box.outcomes.isEmpty)
    }
    func testCounterCountsEachCountingBeatOnce() {
        var c = ConversationCounter()
        let fee = BeatOutcome(beatID: .feeCheck, mode: .cachedReplay, spareTheInterpreter: true)
        XCTAssertTrue(c.record(fee, countsTowardCounter: true))
        XCTAssertFalse(c.record(fee, countsTowardCounter: true))
        XCTAssertFalse(c.record(BeatOutcome(beatID: .coldOpen, mode: .live, spareTheInterpreter: true), countsTowardCounter: false))
        XCTAssertFalse(c.record(BeatOutcome(beatID: .deskCopilot, mode: .live, spareTheInterpreter: false), countsTowardCounter: true))
        XCTAssertEqual(c.value, 1)
    }

    /// contracts/beat/beats.json and the ADBeat catalog agree: every beat title key exists in es/en/ht with
    /// the same values, ids match BeatID constants, and the table cut counts 4 beats (plan, Batch 8).
    func testManifestMatchesCatalogAndConstants() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repo = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("contracts/beat/beats.json"))) as! [String: Any]
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Sources/ADBeat/Resources/ADBeat.xcstrings"))) as! [String: Any]
        let strings = catalog["strings"] as! [String: [String: Any]]
        let known: Set<String> = [BeatID.coldOpen, .feeCheck, .deskCopilot, .warmHandoff, .familyVoiceNote, .abuelaMode, .listingCheck, .familyCouncil].map(\.rawValue).reduce(into: []) { $0.insert($1) }
        var tableCounted = 0
        for b in manifest["beats"] as! [[String: Any]] {
            let id = b["id"] as! String
            XCTAssertTrue(known.contains(id), id)
            let t = b["title"] as! [String: String]
            let locs = strings[t["key"]!]?["localizations"] as? [String: [String: [String: String]]]
            for lang in ["es", "en", "ht"] { XCTAssertEqual(locs?[lang]?["stringUnit"]?["value"], t[lang], "\(id) \(lang)") }
            if b["slot"] as? String == "table", b["counts_toward_counter"] as? Bool == true { tableCounted += 1 }
        }
        XCTAssertEqual(tableCounted, 4)
        XCTAssertNotNil(strings[ConversationCounter.labelKey])
    }
}
