import Foundation

/// "Conversaciones que Sofi no tuvo que traducir". Counts each beat id once per demo run.
public struct ConversationCounter: Hashable, Sendable {
    public private(set) var beats: [BeatID] = []
    public var value: Int { beats.count }
    public init() {}
    /// Returns true when the value went up.
    @discardableResult
    public mutating func record(_ outcome: BeatOutcome, countsTowardCounter: Bool) -> Bool {
        guard countsTowardCounter, outcome.spareTheInterpreter, !beats.contains(outcome.beatID) else { return false }
        beats.append(outcome.beatID)
        return true
    }
    public mutating func reset() { beats.removeAll() }
    /// ADBeat catalog key for the counter label; the number is shown next to it, never inside it.
    public static let labelKey = "beat.counter.label"
}

public enum BeatRunError: Error, Equatable {
    case replayFailed(String)
}

/// Runs one beat: live unless demo mode is on, falling back to the cached replay on timeout or error.
/// Calls `onComplete` exactly once with the outcome the audience saw.
public struct BeatRunner: Sendable {
    public var demoMode: Bool
    public init(demoMode: Bool) { self.demoMode = demoMode }

    public func run(_ beat: any Beat, context: BeatContext,
                    onComplete: @Sendable (BeatOutcome) -> Void) async throws -> BeatOutcome {
        let outcome: BeatOutcome
        if demoMode {
            outcome = try await replay(beat, context, reason: .demoModeOn)
        } else {
            do {
                var live = try await Self.withTimeout(beat.liveTimeout) { try await beat.runLive(context) }
                live.beatID = beat.id
                live.mode = .live
                live.fallbackReason = nil
                outcome = live
            } catch is CancellationError {
                throw CancellationError()
            } catch TimeoutError.timedOut(let s) {
                outcome = try await replay(beat, context, reason: .liveTimedOut(seconds: s))
            } catch {
                outcome = try await replay(beat, context, reason: .liveFailed(String(describing: error)))
            }
        }
        try Task.checkCancellation()
        onComplete(outcome)
        return outcome
    }

    private func replay(_ beat: any Beat, _ context: BeatContext, reason: FallbackReason) async throws -> BeatOutcome {
        try Task.checkCancellation()
        var r: BeatOutcome
        do { r = try await beat.runCachedReplay(context) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BeatRunError.replayFailed(String(describing: error)) }
        r.beatID = beat.id
        r.mode = .cachedReplay
        r.fallbackReason = reason
        return r
    }

    enum TimeoutError: Error { case timedOut(Double) }

    /// Returns the live result or throws `TimeoutError` at the deadline, whichever comes first, **even when
    /// `op` ignores cancellation**. A task group would wait for a non-cancellable child after `cancelAll()`,
    /// so this uses unstructured tasks and one continuation instead (same pattern as
    /// `WarmHandoffEngine.race` in ADWarmHandoff). The loser is cancelled and never awaited; a late live
    /// result is dropped. Cancelling the caller cancels the live task and throws `CancellationError` at once.
    static func withTimeout<T: Sendable>(_ seconds: Double?, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let seconds else { return try await op() }
        let race = LiveRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                race.start(cont, seconds: seconds, op)
            }
        } onCancel: {
            race.cancel()
        }
    }
}

/// One live-vs-deadline race: the first of (live result, live error, deadline, caller cancelled) resumes
/// the continuation; everything after that is ignored. Lock-protected, so `@unchecked Sendable`.
final class LiveRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false
    private var cancelledBeforeStart = false
    private var tasks: [Task<Void, Never>] = []

    func start(_ cont: CheckedContinuation<T, Error>, seconds: Double,
               _ op: @escaping @Sendable () async throws -> T) {
        lock.lock()
        if cancelledBeforeStart {
            finished = true
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        continuation = cont
        lock.unlock()

        let worker = Task {
            do { self.finish(.success(try await op())) }
            catch { self.finish(.failure(error)) }
        }
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        let timer = Task {
            try? await Task.sleep(nanoseconds: nanos)
            if !Task.isCancelled { self.finish(.failure(BeatRunner.TimeoutError.timedOut(seconds))) }
        }

        lock.lock()
        if finished {
            // The race was already decided (very fast live run, or cancelled meanwhile).
            lock.unlock()
            worker.cancel(); timer.cancel()
            return
        }
        tasks = [worker, timer]
        lock.unlock()
    }

    /// Caller cancelled (Demo screen stop / next).
    func cancel() {
        lock.lock()
        if continuation == nil && !finished {
            cancelledBeforeStart = true
            lock.unlock()
            return
        }
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        let losers = tasks
        tasks = []
        lock.unlock()
        losers.forEach { $0.cancel() }   // cancel, never await
        cont.resume(with: result)
    }
}
