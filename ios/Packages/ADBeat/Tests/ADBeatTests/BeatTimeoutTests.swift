import XCTest
@testable import ADBeat

/// Sleeps without looking at cancellation, like a speech or network engine that only returns when done.
private func sleepIgnoringCancellation(_ seconds: Double) async {
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { k.resume() }
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcomes: [BeatOutcome] = []
    private var _liveFinished = 0
    var outcomes: [BeatOutcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }
    var liveFinished: Int { lock.lock(); defer { lock.unlock() }; return _liveFinished }
    func complete(_ o: BeatOutcome) { lock.lock(); _outcomes.append(o); lock.unlock() }
    func finishedLive() { lock.lock(); _liveFinished += 1; lock.unlock() }
}

/// A beat whose live run ignores cancellation and publishes its payload to the shared sink.
private struct StubbornBeat: Beat {
    let id: BeatID = .feeCheck
    var title: BeatTitle { BeatTitle(key: "beat.fee_check.title", es: "es", en: "en", ht: "ht") }
    var liveTimeout: Double?
    let liveSeconds: Double
    let sink: BeatOutputSink<String>
    let log: Log
    func runLive(_ c: BeatContext) async throws -> BeatOutcome {
        await sleepIgnoringCancellation(liveSeconds)
        log.finishedLive()
        await sink.publishUnlessCancelled("live")
        return BeatOutcome(beatID: id, mode: .live, spareTheInterpreter: true)
    }
    func runCachedReplay(_ c: BeatContext) async throws -> BeatOutcome {
        await sink.publish("replay")
        return BeatOutcome(beatID: id, mode: .cachedReplay, spareTheInterpreter: true)
    }
}

final class BeatTimeoutTests: XCTestCase {
    let ctx = BeatContext(language: "es", thinkIn: "es")

    /// The deadline holds even when runLive ignores cancellation (2 s live, 0.1 s deadline).
    func testDeadlineHoldsWhenLiveIgnoresCancellation() async throws {
        let log = Log(), sink = BeatOutputSink<String>()
        let beat = StubbornBeat(liveTimeout: 0.1, liveSeconds: 2, sink: sink, log: log)
        let start = Date()
        let o = try await BeatRunner(demoMode: false).run(beat, context: ctx) { log.complete($0) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.5, "runner waited \(elapsed) s for a live run that ignores cancellation")
        XCTAssertTrue(o.isReplay)
        XCTAssertEqual(o.fallbackReason, .liveTimedOut(seconds: 0.1))
        XCTAssertEqual(log.outcomes, [o])
        let shown = await sink.latest
        XCTAssertEqual(shown, "replay")
    }

    /// A live result that arrives after the deadline is ignored: onComplete stays at one call with the replay,
    /// and the late payload does not overwrite the replay in the sink.
    func testLateLiveResultIsIgnored() async throws {
        let log = Log(), sink = BeatOutputSink<String>()
        let beat = StubbornBeat(liveTimeout: 0.1, liveSeconds: 0.3, sink: sink, log: log)
        let o = try await BeatRunner(demoMode: false).run(beat, context: ctx) { log.complete($0) }
        XCTAssertTrue(o.isReplay)
        try await Task.sleep(nanoseconds: 600_000_000)   // let the late live run finish
        XCTAssertEqual(log.liveFinished, 1)
        XCTAssertEqual(log.outcomes.count, 1)
        XCTAssertEqual(log.outcomes.first?.mode, .cachedReplay)
        let shown = await sink.latest
        XCTAssertEqual(shown, "replay")
    }

    /// A live run inside the deadline still wins and is labeled live.
    func testFastLiveWinsInsideDeadline() async throws {
        let log = Log(), sink = BeatOutputSink<String>()
        let beat = StubbornBeat(liveTimeout: 1, liveSeconds: 0.05, sink: sink, log: log)
        let o = try await BeatRunner(demoMode: false).run(beat, context: ctx) { log.complete($0) }
        XCTAssertEqual(o.mode, .live); XCTAssertNil(o.fallbackReason)
        XCTAssertEqual(log.outcomes, [o])
        let shown = await sink.latest
        XCTAssertEqual(shown, "live")
    }

    /// Stopping the Demo screen during a timed live run returns at once and never completes,
    /// even when runLive ignores cancellation.
    func testCallerCancelReturnsPromptlyWithoutCompleting() async throws {
        let log = Log(), sink = BeatOutputSink<String>()
        let beat = StubbornBeat(liveTimeout: 5, liveSeconds: 2, sink: sink, log: log)
        let c = ctx
        let start = Date()
        let t = Task { try await BeatRunner(demoMode: false).run(beat, context: c) { log.complete($0) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        t.cancel()
        let r = await t.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        if case .success = r { XCTFail("a cancelled run must not succeed") }
        XCTAssertTrue(log.outcomes.isEmpty)
        let shown = await sink.latest
        XCTAssertNil(shown)
    }

    /// Cancelled before the race even starts.
    func testAlreadyCancelledCallerThrows() async {
        let t = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BeatRunner.withTimeout(1) { await sleepIgnoringCancellation(0.3); return 1 }
        }
        let r = await t.result
        if case .success = r { XCTFail("expected CancellationError") }
    }

    func testSinkPublishClearAndCancelledPublish() async {
        let sink = BeatOutputSink<Int>()
        await sink.publish(1)
        var v = await sink.latest; XCTAssertEqual(v, 1)
        let t = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await sink.publishUnlessCancelled(2)
        }
        let published = await t.value
        XCTAssertFalse(published)
        v = await sink.latest; XCTAssertEqual(v, 1)
        let ok = await sink.publishUnlessCancelled(3)
        XCTAssertTrue(ok)
        v = await sink.latest; XCTAssertEqual(v, 3)
        await sink.clear()
        v = await sink.latest; XCTAssertNil(v)
    }
}
