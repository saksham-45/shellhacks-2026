#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// AVSpeechSynthesizer behind the app's `SpeechOutput`. Thin adapter until ADVoice's SystemSpeaker is
/// implemented (it throws notImplemented today; gap reported to myAD Voice). Picks a voice whose
/// language matches the text's language; when none exists (Creole on every iOS today) it returns
/// `.unavailable` and speaks nothing: it never falls back to a Spanish, English, or French voice.
@MainActor
final class SystemSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var voiceLanguages: Set<String> {
        Set(AVSpeechSynthesisVoice.speechVoices().map { String($0.language.prefix(2)).lowercased() })
    }

    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let wanted = language.lowercased()
        let base = String(wanted.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            let l = $0.language.lowercased()
            return l == base || l.hasPrefix(base + "-")
        }
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int) {
            let l = v.language.lowercased()
            let place = l == wanted ? 0 : (l == "\(base)-us" ? 1 : 2)
            return (place, -v.quality.rawValue)
        }
        return candidates.min { rank($0) < rank($1) }
    }

    func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void) -> SpeakResult {
        guard let voice = Self.voice(for: language) else { return .unavailable(language: language) }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        self.finished = finished
        synthesizer.speak(utterance)
        return .speaking(voice: voice.identifier)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        fire()
    }

    private func fire() {
        let done = finished
        finished = nil
        done?()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.fire() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.fire() }
    }
}
#endif
