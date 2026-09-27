import Foundation

/// Hands a beat run's output (the sheet, the note, the answer) to the feature's view. `BeatOutcome` carries
/// only run metadata, so a conforming beat publishes its payload here and the view reads `latest` after
/// `BeatRunner.run` returns. Same shape as the copies ADWarmHandoff and ADFamilyVoiceNote shipped
/// (they delete theirs and import this one).
///
/// Rule for `runLive`: publish with `publishUnlessCancelled(_:)`. At the deadline the runner cancels the
/// live task *before* it starts the cached replay and never waits for it, so a live run that ignores
/// cancellation and finishes late is dropped here instead of overwriting the replay the audience sees.
/// `runCachedReplay` publishes with `publish(_:)`.
public actor BeatOutputSink<Output: Sendable> {
    public private(set) var latest: Output?

    public init() {}

    /// Replaces `latest`.
    public func publish(_ output: Output) { latest = output }

    /// Replaces `latest` only if the calling task is not cancelled; returns whether it did. The check and
    /// the write happen together on this actor, so a late live result can never land after the replay.
    @discardableResult
    public func publishUnlessCancelled(_ output: Output) -> Bool {
        guard !Task.isCancelled else { return false }
        latest = output
        return true
    }

    /// Clears `latest` (the view's reset / start over).
    public func clear() { latest = nil }
}
