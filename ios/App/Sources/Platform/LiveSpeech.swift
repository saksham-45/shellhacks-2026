#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Foundation
import Speech

/// Speech and mic permission handlers are delivered on a root queue. Waiting here
/// (not on `@MainActor`) is what keeps Swift 6 from trapping on Speak.
enum LiveSpeechAuth {
    nonisolated static func wait(_ start: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            start { value in
                continuation.resume(returning: value)
            }
        }
    }
}

/// The mic tap runs on Core Audio's realtime thread. A `@MainActor` block traps there.
enum LiveSpeechTap {
    nonisolated static func append(_ request: SFSpeechAudioBufferRecognitionRequest) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let box = UncheckedBox(request)
        return { buffer, _ in
            box.value.append(buffer)
        }
    }
}

/// Speech's request type is usable from the tap callback and is not Sendable in this SDK.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private struct WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// On-device dictation for the Speak button. One locale at a time (the current UI language);
/// `SpokenSurface` then decides whether the transcript should flip the screen.
@MainActor
final class LiveSpeechSession: NSObject, SFSpeechRecognizerDelegate {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onFail: (() -> Void)?
    private var finishing = false
    private var tapInstalled = false
    private var sessionActive = false

    var isRunning: Bool { engine.isRunning }

    static func isUsable() -> Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .denied || speech == .restricted { return false }
        return true
    }

    func start(locale: Locale, onPartial: @escaping (String) -> Void, onFinal: @escaping (String) -> Void,
               onFail: @escaping () -> Void) {
        stop()
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onFail = onFail
        finishing = false
        Task { await self.begin(locale: locale) }
    }

    func stop() {
        finishing = true
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
        recognizer = nil
        onPartial = nil
        onFinal = nil
        onFail = nil
    }

    private func begin(locale: Locale) async {
        let speechOK = await LiveSpeechAuth.wait { finish in
            SFSpeechRecognizer.requestAuthorization { status in
                finish(status == .authorized)
            }
        }
        let micOK = await LiveSpeechAuth.wait { finish in
            AVAudioApplication.requestRecordPermission { granted in
                finish(granted)
            }
        }
        guard speechOK, micOK, !finishing else {
            onFail?()
            return
        }
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            onFail?()
            return
        }
        self.recognizer = recognizer
        recognizer.delegate = self

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        #if targetEnvironment(simulator)
        request.requiresOnDeviceRecognition = false
        #else
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        #endif
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActive = true
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                onFail?()
                stopEngine()
                return
            }
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: LiveSpeechTap.append(request))
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            onFail?()
            stopEngine()
            return
        }

        let box = WeakBox(self)
        task = Self.observe(recognizer, request: request) { text, isFinal, failed in
            Task { @MainActor in
                box.value?.handleRecognition(text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    /// Speech delivers this handler off the main actor; forming it here keeps Swift 6 from trapping.
    nonisolated private static func observe(
        _ recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        event: @escaping @Sendable (String, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            event(
                result?.bestTranscription.formattedString ?? "",
                result?.isFinal == true,
                error != nil && result?.isFinal != true
            )
        }
    }

    private func handleRecognition(text: String, isFinal: Bool, failed: Bool) {
        if !text.isEmpty {
            if isFinal {
                let done = onFinal
                stop()
                done?(text)
                return
            }
            onPartial?(text)
        }
        if failed, !finishing {
            let fail = onFail
            stop()
            fail?()
        }
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}
#endif
