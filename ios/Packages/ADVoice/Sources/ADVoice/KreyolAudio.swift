import Foundation
import ADCore
import ADLocale
#if canImport(AVFoundation)
import AVFoundation
#endif

/// One piece of a card, in reading order, for "Play in Kreyòl".
public enum KreyolPart: Sendable, Equatable {
    /// A catalog string and the exact Creole text on screen (hashed against the clip).
    case string(key: StringKey, text: String)
    /// A live value (date, phone number, amount): never has a recording.
    case live(label: String)
}

/// Outcome of the "Play in Kreyòl" card action.
public enum KreyolPlayback: Sendable, Equatable {
    /// Every part's native-reviewed clip played to the end.
    case played
    /// Some parts played; `missing` lists every part that had no reviewed, hash-matched clip
    /// (including `.live` values), in order. Nothing was skipped silently.
    case partial(played: [StringKey], missing: [KreyolPart])
    /// No part played; show `notice`. No other voice was used, but the reviewed
    /// `kreyol.restOnScreen` clip may already have played in place of the missing parts
    /// (`playKreyol(parts:)` only).
    case noClip(notice: StringKey)
    /// `stop()` was called (next gesture or screen change); remaining parts were not played.
    case stopped
    /// A reviewed clip existed but the player threw (broken file), for at least one part.
    /// `missing` lists every part that did not play, throwing or not. Distinct from `.noClip`.
    case failed(played: [StringKey], missing: [KreyolPart])

    /// What to show and announce with this result (every non-played outcome has one, so a
    /// silent skip is never silent on screen): `.partial` -> `kreyol.restOnScreen`,
    /// `.noClip` -> its notice, `.failed` -> `kreyol.couldNotPlay`. nil for `.played`/`.stopped`.
    public var notice: StringKey? {
        switch self {
        case .played, .stopped: nil
        case .partial: VoiceKey.kreyolRestOnScreen
        case .noClip(let notice): notice
        case .failed: VoiceKey.kreyolCouldNotPlay
        }
    }
}

/// Plays one audio file. `AVClipPlayer` on Apple; a recorder in tests.
public protocol ClipPlayer: Sendable {
    func play(_ url: URL) async throws
    /// Contract: a stop that arrives while a clip is still loading (before it starts) must keep
    /// it from starting; the stop stays in force until the next `beginSession()`.
    func stop() async
    /// Called once before a sequence of clips (audio session on; clears an earlier stop).
    func beginSession() async
    /// Called once after the sequence (audio session off). Default: nothing.
    func endSession() async
}

extension ClipPlayer {
    public func beginSession() async {}
    public func endSession() async {}
}

/// "Play in Kreyòl" (accessibility decision): every Creole card offers the bundled recordings a
/// native speaker reviewed, and ONLY those. It never falls back to another voice: this type
/// holds no `SpeechSynthesizing` and no server transport, so it cannot synthesize anything.
///
/// Whole card: `playKreyol(parts:)` plays each part's clip in order. A part without a clip is
/// recorded as missing and, when a reviewed `kreyol.restOnScreen` clip exists, that clip plays
/// in its place (at most once in a row).
///
/// Card ids do not map cleanly to one key (a `Card` may override its `titleKey`), so there is
/// no `playKreyol(cardID:)`; use `playKreyol(parts:)`, the key-based call, or
/// `playKreyol(card:text:)`, which reads the card's own `titleKey`.
public actor KreyolAudio {
    let library: any PrerenderedAudioLibrary
    let player: any ClipPlayer
    /// The exact ht text of `kreyol.restOnScreen` (its clip is hash-matched against it).
    let restOnScreenText: String?
    let gate: any ScreenReaderGate
    private var generation = 0
    private var stoppedGeneration = -1
    /// Generation of the play in progress, if any.
    private var active: Int?
    /// The current screen-reader wait (F3), cancelled by stop or a superseding play.
    private var gateWait: Task<Void, Never>?
    var startListener: (any PlaybackStartListener)?

    /// `restOnScreenText` defaults to the ht string in ADVoice's own catalog (nil if it is only
    /// an English fallback, so no rest clip can match).
    /// `gate` waits for the screen reader to finish speaking before the first clip (Apple:
    /// `VoiceOverGate`); the default never waits.
    public init(library: any PrerenderedAudioLibrary, player: any ClipPlayer,
                restOnScreenText: String? = KreyolAudio.bundledRestOnScreenText(),
                gate: any ScreenReaderGate = NoScreenReaderGate()) {
        self.library = library
        self.player = player
        self.restOnScreenText = restOnScreenText
        self.gate = gate
    }

    public static func bundledRestOnScreenText() -> String? {
        let t = Localizer(registry: CatalogRegistry([ADVoiceResources.registration]), surface: .ht).text(VoiceKey.kreyolRestOnScreen)
        return t.isFallback || t.isMissing ? nil : t.plain
    }

    /// Plays the whole card, part by part, in order.
    public func playKreyol(parts: [KreyolPart]) async -> KreyolPlayback {
        await play(parts, restClip: true)
    }

    /// One string only (the card title, say). No rest-on-screen clip: with no reviewed,
    /// hash-matched clip the result is `.noClip` and nothing plays.
    public func playKreyol(cardKey: StringKey, text: String) async -> KreyolPlayback {
        await play([.string(key: cardKey, text: text)], restClip: false)
    }

    /// Uses the card's own title key (`Card.titleKey`, table "Cards" by default).
    public func playKreyol(card: Card, text: String) async -> KreyolPlayback {
        await playKreyol(cardKey: card.titleKey, text: text)
    }

    /// Stops playback, including the remaining parts; a play in progress returns `.stopped`.
    /// Call on the next gesture or screen change.
    public func stop() async {
        stoppedGeneration = generation
        gateWait?.cancel()
        gateWait = nil
        await gate.cancelWait()
        await player.stop()
    }

    /// Still the newest call, and not stopped.
    private func isCurrent(_ mine: Int) -> Bool {
        generation == mine && stoppedGeneration != mine && !Task.isCancelled
    }

    /// A new call supersedes any play in progress (that one returns `.stopped`), so two cards
    /// never talk over each other. After every await the call re-checks `isCurrent`.
    private func play(_ parts: [KreyolPart], restClip: Bool) async -> KreyolPlayback {
        let hadActive = active != nil
        stoppedGeneration = generation
        generation += 1
        let mine = generation
        active = mine
        if hadActive {
            // F3: end the earlier call's screen-reader wait (it returns `.stopped`).
            gateWait?.cancel()
            await gate.cancelWait()
            await player.stop()
        }
        guard isCurrent(mine) else { return .stopped }
        // Let VoiceOver finish (the action name, an announcement) before any clip starts. The
        // wait runs in its own task so a stop can cancel it even before the gate registers it.
        let gate = self.gate
        let wait = Task { await gate.waitUntilQuiet() }
        gateWait = wait
        await wait.value
        if gateWait == wait { gateWait = nil }
        guard isCurrent(mine) else {
            if generation == mine { active = nil }
            return .stopped
        }
        await player.beginSession()
        let result = isCurrent(mine) ? await sequence(parts, restClip: restClip, mine: mine) : .stopped
        // A superseding call owns the session now; only the newest call ends it.
        if generation == mine {
            active = nil
            await player.endSession()
        }
        return result
    }

    private func sequence(_ parts: [KreyolPart], restClip: Bool, mine: Int) async -> KreyolPlayback {
        var played: [StringKey] = []
        var missing: [KreyolPart] = []
        var lastWasRest = false
        var anyThrew = false
        let rest = restClip ? restOnScreenText.flatMap { reviewedClip(VoiceKey.kreyolRestOnScreen, $0) } : nil
        for part in parts {
            guard isCurrent(mine) else { return .stopped }
            if case let .string(key, text) = part, let clip = reviewedClip(key, text) {
                if played.isEmpty, !anyThrew, let startListener { await startListener.playbackStarted() }
                let ok = await playFile(clip.fileURL)
                guard isCurrent(mine) else { return .stopped }
                if ok { played.append(key); lastWasRest = false; continue }
                anyThrew = true
            }
            missing.append(part)
            if let rest, !lastWasRest {
                _ = await playFile(rest.fileURL)
                guard isCurrent(mine) else { return .stopped }
                lastWasRest = true
            }
        }
        if anyThrew { return .failed(played: played, missing: missing) }
        if played.isEmpty { return .noClip(notice: VoiceKey.kreyolNoRecording) }
        return missing.isEmpty ? .played : .partial(played: played, missing: missing)
    }

    /// Reviewed, ht, and hashed against the exact text, whatever the library claims.
    private func reviewedClip(_ key: StringKey, _ text: String) -> PrerenderedClip? {
        let ht = Locale.Language(identifier: "ht")
        return PrerenderedClip.verified(library.clip(for: key, language: ht, text: text), language: ht, text: text)
    }

    /// A file that fails to play counts as missing (and makes the result `.failed`), never as played.
    /// Task cancellation stops the player (and so the sequence).
    private func playFile(_ url: URL) async -> Bool {
        let player = self.player
        do {
            try await withTaskCancellationHandler {
                try await player.play(url)
            } onCancel: {
                Task { await player.stop() }
            }
            return true
        } catch {
            return false
        }
    }
}

#if canImport(AVFoundation)
/// AVAudioPlayer-backed `ClipPlayer`. `beginSession` sets the session to `.playback` /
/// `.spokenAudio`, ducking or pausing other spoken audio; `endSession` deactivates it once and
/// notifies others so their audio resumes.
/// TODO(main actor): AVAudioPlayer play/stop run on the caller's thread under `lock`. Moving
/// them to the MainActor needs the continuation set-up reworked; not done (cannot compile
/// AVFoundation on the Linux box).
public final class AVClipPlayer: NSObject, ClipPlayer, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, any Error>?
    /// Set by `stop()`; cleared only by `beginSession()`, so a stop during load (before the
    /// continuation exists) still prevents `player.play()`.
    private var stopRequested = false

    public override init() { super.init() }

    public func beginSession() async {
        lock.withLock { stopRequested = false }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        #endif
    }

    public func endSession() async {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func play(_ url: URL) async throws {
        // Ends the previous clip WITHOUT raising the stop flag; a stop() that arrives during load
        // keeps the flag set (cleared only by beginSession), so this clip never starts.
        stopCurrent()
        if lock.withLock({ stopRequested }) { return }
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        if lock.withLock({ stopRequested }) { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if stopRequested { lock.unlock(); c.resume(); return }
                current = player
                continuation = c
                lock.unlock()
                if !player.play() { finish(player, .failure(VoiceError.notConfigured("clip"))) }
            }
        } onCancel: {
            self.stopNow()
        }
    }

    public func stop() async { stopNow() }

    private func stopCurrent() {
        lock.lock()
        let p = current, c = continuation
        current = nil
        continuation = nil
        lock.unlock()
        p?.stop()
        c?.resume()
    }

    private func stopNow() {
        lock.lock()
        stopRequested = true
        let p = current, c = continuation
        current = nil
        continuation = nil
        lock.unlock()
        p?.stop()
        c?.resume()
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(player, flag ? .success(()) : .failure(VoiceError.notConfigured("clip")))
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(player, .failure(error ?? VoiceError.notConfigured("clip")))
    }

    /// Resumes only for the current player: a late callback from an earlier player is ignored.
    private func finish(_ player: AVAudioPlayer, _ result: Result<Void, any Error>) {
        lock.lock()
        guard player === current else { lock.unlock(); return }
        let c = continuation
        continuation = nil
        current = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
#endif

extension KreyolAudio {
    /// Told when the first clip of a play starts (e.g. a `PlaybackStopper`, for its grace window).
    public func setStartListener(_ listener: (any PlaybackStartListener)?) { startListener = listener }
}
