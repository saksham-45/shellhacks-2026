import Foundation
import ADCore

/// Where a beat's answer came from. The screen labels every non-live answer; a replay is never shown as live.
public enum CheckOrigin: Hashable, Sendable {
    case live
    /// The bundled replay. `because` says why the live path was not used.
    case cachedReplay(because: FallbackReason)

    public enum FallbackReason: String, Hashable, Sendable, Error {
        /// No live answer within the deadline (4 s on stage).
        case timedOut = "timed-out"
        /// The live path threw (no network, speech failed, county layer error).
        case failed
        /// The live path answered but could not be used (nothing recognizable was heard).
        case unusable
        /// The presenter chose the replay chip.
        case chosen
    }
}

public enum CheckRace {
    /// Runs `live` against a deadline. Returns its value if it finishes in time with a usable result; otherwise
    /// returns the reason so the caller shows the labeled replay.
    ///
    /// The live task is cancelled when the timer wins, but the function does not wait for it. A county call
    /// that ignores cancellation used to hold a task group open until the call itself returned.
    public static func live<T: Sendable>(
        deadline: Duration,
        _ live: @escaping @Sendable () async throws -> T?
    ) async -> Result<T, CheckOrigin.FallbackReason> {
        let parts = deadline.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let race = CheckLiveRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<T, CheckOrigin.FallbackReason>, Never>) in
                race.start(cont, seconds: seconds, live)
            }
        } onCancel: {
            race.cancel()
        }
    }
}

/// First of (live result, live error, deadline, caller cancelled) wins. The loser is cancelled and never awaited.
final class CheckLiveRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<T, CheckOrigin.FallbackReason>, Never>?
    private var finished = false
    private var cancelledBeforeStart = false
    private var tasks: [Task<Void, Never>] = []

    func start(
        _ cont: CheckedContinuation<Result<T, CheckOrigin.FallbackReason>, Never>,
        seconds: Double,
        _ live: @escaping @Sendable () async throws -> T?
    ) {
        lock.lock()
        if cancelledBeforeStart {
            finished = true
            lock.unlock()
            cont.resume(returning: .failure(.failed))
            return
        }
        continuation = cont
        lock.unlock()

        let worker = Task {
            do {
                guard let value = try await live() else {
                    self.finish(.failure(.unusable))
                    return
                }
                self.finish(.success(value))
            } catch {
                self.finish(.failure(.failed))
            }
        }
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        let timer = Task {
            try? await Task.sleep(nanoseconds: nanos)
            if !Task.isCancelled { self.finish(.failure(.timedOut)) }
        }

        lock.lock()
        if finished {
            lock.unlock()
            worker.cancel()
            timer.cancel()
            return
        }
        tasks = [worker, timer]
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        if continuation == nil && !finished {
            cancelledBeforeStart = true
            lock.unlock()
            return
        }
        lock.unlock()
        finish(.failure(.failed))
    }

    private func finish(_ result: Result<T, CheckOrigin.FallbackReason>) {
        lock.lock()
        guard !finished, let cont = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        let losers = tasks
        tasks = []
        lock.unlock()
        losers.forEach { $0.cancel() }
        cont.resume(returning: result)
    }
}

// MARK: - Fee Check run

/// The bundled replay for the Fee Check beat: the scripted gestor line, not a recording. Its answer is recomputed
/// from the same local ledger, so the numbers on screen are the verified ones either way.
public struct FeeReplay: Hashable, Sendable, Decodable {
    public let transcript: String
    public let language: String
    /// Always "demo-script": the label says it is a scripted replay.
    public let kind: String

    public static func bundled() throws -> FeeReplay {
        guard let url = Bundle.module.url(forResource: "fee-replay", withExtension: "json", subdirectory: "Checks") else {
            throw BundledRegionData.LoadError.missing("Checks/fee-replay.json")
        }
        return try JSONDecoder().decode(FeeReplay.self, from: Data(contentsOf: url))
    }
}

public struct FeeCheckResult: Sendable {
    public let heard: String
    public let ask: FeeAsk
    public let answer: FeeAnswer
    public let origin: CheckOrigin
}

public enum FeeCheckRun {
    public static let stageDeadline: Duration = .seconds(4)

    /// `hear` is the push-to-talk turn: speech to text (and optionally a model extraction folded back into text).
    /// The ledger answer itself is local and instant, so only hearing is raced against the deadline.
    public static func run(
        deadline: Duration = stageDeadline,
        ledger: CheckLedger,
        replay: FeeReplay,
        hear: @escaping @Sendable () async throws -> String
    ) async -> FeeCheckResult? {
        let live = await CheckRace.live(deadline: deadline) { () async throws -> (String, FeeAsk)? in
            let heard = try await hear()
            let ask = FeeAskParser.parse(heard)
            return ask.topic == nil ? nil : (heard, ask)
        }
        switch live {
        case let .success((heard, ask)):
            return FeeCheck.answer(ask, ledger: ledger).map { FeeCheckResult(heard: heard, ask: ask, answer: $0, origin: .live) }
        case let .failure(reason):
            return self.replay(replay, ledger: ledger, because: reason)
        }
    }

    public static func replay(_ replay: FeeReplay, ledger: CheckLedger, because reason: CheckOrigin.FallbackReason) -> FeeCheckResult? {
        let ask = FeeAskParser.parse(replay.transcript)
        return FeeCheck.answer(ask, ledger: ledger).map {
            FeeCheckResult(heard: replay.transcript, ask: ask, answer: $0, origin: .cachedReplay(because: reason))
        }
    }
}
