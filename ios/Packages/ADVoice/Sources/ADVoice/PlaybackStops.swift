import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: S4: wait for the screen reader before a clip

/// Waits until the screen reader has finished speaking (bounded), so a clip never starts on top
/// of VoiceOver. `cancelWait()` ends a wait early (stop).
public protocol ScreenReaderGate: Sendable {
    func waitUntilQuiet() async
    func cancelWait() async
}

/// Never waits (Linux, tests, VoiceOver off).
public struct NoScreenReaderGate: ScreenReaderGate {
    public init() {}
    public func waitUntilQuiet() async {}
    public func cancelWait() async {}
}

/// A bounded, cancellable wait used by screen-reader gates (platform-neutral, so its races are
/// tested on Linux). Each wait has its own id:
/// - a new wait resumes (supersedes) the one before it, so no continuation is ever lost;
/// - a wait started by a task that is already cancelled returns at once, and cancelling the task
///   while it waits ends it (a stop that lands before the wait registers is not lost);
/// - `resumeCurrent()` ends the current wait (announcement finished, `cancelWait()`).
public final class QuietWait: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: (id: Int, continuation: CheckedContinuation<Void, Never>)?
    private var nextID = 0
    public init() {}

    public var isWaiting: Bool { lock.withLock { waiting != nil } }

    public func wait(timeout: Duration) async {
        let id: Int = lock.withLock { nextID += 1; return nextID }
        resumeCurrent()   // supersede an earlier wait
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(id)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    if Task.isCancelled { return true }
                    waiting = (id, c)
                    return false
                }
                if now { c.resume() }
            }
        } onCancel: { [weak self] in
            self?.resume(id)
        }
    }

    public func resumeCurrent() { take(nil)?.resume() }

    private func resume(_ id: Int) { take(id)?.resume() }

    private func take(_ id: Int?) -> CheckedContinuation<Void, Never>? {
        lock.withLock {
            guard let w = waiting, id == nil || w.id == id else { return nil }
            waiting = nil
            return w.continuation
        }
    }
}

// MARK: S3 + F1: which events stop playback

/// Something that can be told to stop reading or playing.
public protocol StoppablePlayback: Sendable {
    func stop() async
}

extension KreyolAudio: StoppablePlayback {}
extension VoiceSpeaker: StoppablePlayback {}

/// Told when the first clip or segment of a play/read actually starts (for the focus grace window).
public protocol PlaybackStartListener: Sendable {
    func playbackStarted() async
}

/// The element that started playback, as an opaque identity the app passes in (a control id,
/// or `PlaybackOrigin(object:)` for a UIKit accessibility element).
public struct PlaybackOrigin: Hashable, @unchecked Sendable {
    let id: AnyHashable
    public init(_ id: AnyHashable) { self.id = id }
    public init(object: AnyObject) { self.id = ObjectIdentifier(object) }
}

/// Which assistive technology moved focus.
public enum FocusSource: Hashable, Sendable {
    case voiceOver
    /// Switch Control scanning moves the cursor on its own; it never stops playback.
    case switchControl
    case other
}

/// Events the app observes while something is being read or played.
public enum PlaybackEvent: Hashable, Sendable {
    /// Focus moved (`UIAccessibility.elementFocusedNotification`). Only VoiceOver focus that did
    /// not land on the originating element, outside the grace window, is the next gesture.
    case focusChanged(source: FocusSource, element: PlaybackOrigin?)
    /// The screen that started playback went away.
    case screenDisappeared
    /// The scene became inactive or went to the background.
    case sceneLeftForeground
    /// The scene became active again.
    case sceneBecameActive
    /// Magic Tap: the app decides (toggle play or the mic), so it never stops here.
    case magicTap
}

/// The platform-neutral rule: playback stops on the next gesture or screen change.
public enum PlaybackStopPolicy {
    /// The event kind alone (no timing, no origin): see `PlaybackStopper` for the full rule.
    public static func shouldStop(on event: PlaybackEvent) -> Bool {
        switch event {
        case .focusChanged(let source, _): source == .voiceOver
        case .screenDisappeared, .sceneLeftForeground: true
        case .sceneBecameActive, .magicTap: false
        }
    }
}

/// Stops every registered player when the rule says so. The Apple wiring
/// (`VoiceOverFocusStopObserver`, `.stopsPlaybackOnScreenChange(_:)`) only forwards events here.
///
/// Focus rule (F1): a VoiceOver focus event stops playback unless it lands on the element that
/// started it, or it comes between `playbackWillStart` and 0.5 s (`graceWindow`) after the first
/// clip or segment actually started (`playbackStarted`). Screen and scene events stop at once.
/// Without `playbackWillStart`, focus events act at once (as before).
public final class PlaybackStopper: PlaybackStartListener, @unchecked Sendable {
    let targets: [any StoppablePlayback]
    let now: @Sendable () -> TimeInterval
    public let graceWindow: TimeInterval
    private let lock = NSLock()
    private var origin: PlaybackOrigin?
    private var pending = false
    private var startedAt: TimeInterval?

    /// `now`: seconds on a monotonic clock (injected in tests).
    public init(_ targets: [any StoppablePlayback], graceWindow: TimeInterval = 0.5,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.targets = targets
        self.graceWindow = graceWindow
        self.now = now
    }

    /// Call when the person starts a play or read (before `playKreyol` / `beginRead`).
    public func playbackWillStart(origin: PlaybackOrigin?) {
        lock.withLock {
            self.origin = origin
            pending = true
            startedAt = nil
        }
    }

    /// The first clip or segment actually started (players call it as `PlaybackStartListener`).
    public func playbackStarted(at time: TimeInterval) {
        lock.withLock {
            guard pending || startedAt == nil else { return }
            pending = false
            startedAt = time
        }
    }

    public func playbackStarted() async { playbackStarted(at: now()) }

    /// Whether this event should stop playback now.
    public func shouldStop(on event: PlaybackEvent, at time: TimeInterval? = nil) -> Bool {
        guard PlaybackStopPolicy.shouldStop(on: event) else { return false }
        guard case .focusChanged(_, let element) = event else { return true }
        let t = time ?? now()
        return lock.withLock {
            if let element, element == origin { return false }
            if pending { return false }
            if let s = startedAt, t < s + graceWindow { return false }
            return true
        }
    }

    /// Returns whether it stopped.
    @discardableResult
    public func handle(_ event: PlaybackEvent, at time: TimeInterval? = nil) async -> Bool {
        guard shouldStop(on: event, at: time) else { return false }
        lock.withLock { pending = false; startedAt = nil; origin = nil }
        for t in targets { await t.stop() }
        return true
    }
}

#if canImport(UIKit)
/// Forwards focus changes to a `PlaybackStopper`. Keep it alive while the screen is. Only
/// VoiceOver focus counts: an event posted for Switch Control (or while Switch Control runs and
/// VoiceOver doesn't) is forwarded as `.switchControl` and never stops. The focused element is
/// passed as `PlaybackOrigin(object:)`, so pass the same identity to `playbackWillStart`.
public final class VoiceOverFocusStopObserver: @unchecked Sendable {
    private var token: NSObjectProtocol?
    public init(stopper: PlaybackStopper) {
        token = NotificationCenter.default.addObserver(forName: UIAccessibility.elementFocusedNotification,
                                                       object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let tech = info[UIAccessibility.assistiveTechnologyUserInfoKey]
            let techID = (tech as? UIAccessibility.AssistiveTechnologyIdentifier)?.rawValue ?? (tech as? String)
            let focused = info[UIAccessibility.focusedElementUserInfoKey].map { PlaybackOrigin(object: $0 as AnyObject) }
            let time = ProcessInfo.processInfo.systemUptime   // stamped now: events may be handled out of order
            Task { @MainActor in
                let voiceOverRunning = UIAccessibility.isVoiceOverRunning
                let source: FocusSource
                if techID == UIAccessibility.AssistiveTechnologyIdentifier.notificationSwitchControl.rawValue
                    || (UIAccessibility.isSwitchControlRunning && !voiceOverRunning) {
                    source = .switchControl
                } else if voiceOverRunning, techID == nil || techID == UIAccessibility.AssistiveTechnologyIdentifier.notificationVoiceOver.rawValue {
                    source = .voiceOver
                } else {
                    source = .other
                }
                await stopper.handle(.focusChanged(source: source, element: focused), at: time)
            }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// VoiceOver-aware `ScreenReaderGate`: when VoiceOver runs, waits for
/// `announcementDidFinishNotification` or `maxWait` (default 1.5 s), whichever comes first.
/// Note: that notification fires only for announcements the app posts; otherwise the bounded
/// delay applies.
public final class VoiceOverGate: ScreenReaderGate, @unchecked Sendable {
    private let quiet = QuietWait()
    private let maxWait: Duration
    public init(maxWait: Duration = .milliseconds(1500)) { self.maxWait = maxWait }

    /// A second wait supersedes the first (it returns at once); a cancelled caller returns at once.
    public func waitUntilQuiet() async {
        let running = await MainActor.run { UIAccessibility.isVoiceOverRunning }
        guard running else { return }
        let token = NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification,
                                                           object: nil, queue: nil) { [quiet] _ in quiet.resumeCurrent() }
        defer { NotificationCenter.default.removeObserver(token) }
        await quiet.wait(timeout: maxWait)
    }

    public func cancelWait() async { quiet.resumeCurrent() }
}
#endif

#if canImport(SwiftUI)
private struct StopsPlaybackOnScreenChange: ViewModifier {
    let stopper: PlaybackStopper
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .onDisappear { Task { await stopper.handle(.screenDisappeared) } }
            .onChange(of: scenePhase) { _, phase in
                Task { await stopper.handle(phase == .active ? .sceneBecameActive : .sceneLeftForeground) }
            }
    }
}

extension View {
    /// Stops playback when this screen disappears or the scene leaves the foreground. Put it on
    /// the SCREEN ROOT only: `onDisappear` does not fire for a `.sheet` over the screen, and it
    /// does fire for a row of a lazy List/LazyVStack scrolling off screen.
    public func stopsPlaybackOnScreenChange(_ stopper: PlaybackStopper) -> some View {
        modifier(StopsPlaybackOnScreenChange(stopper: stopper))
    }
}
#endif
