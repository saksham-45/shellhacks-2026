#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// ElevenLabs reads the card in the surface language, including Kreyòl. Apple TTS is the
/// fallback when the key is missing or the request fails, and still never fakes Creole.
@MainActor
final class ElevenLabsSpeechOutput: NSObject, SpeechOutput, AVAudioPlayerDelegate {
    /// Rachel, a stock multilingual voice. One voice across languages is the ElevenLabs demo.
    static let voiceID = "21m00Tcm4TlvDq8ikWAM"
    static let surfaceLanguages: Set<String> = ["es", "en", "ht", "pt", "fr", "ar", "zh", "ru", "tl", "vi"]

    private let apple = SystemSpeechOutput()
    private var player: AVAudioPlayer?
    private var finished: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?

    var voiceLanguages: Set<String> {
        if SecretEnv.elevenLabs != nil { return Self.surfaceLanguages.union(apple.voiceLanguages) }
        return apple.voiceLanguages
    }

    func speak(_ text: String, language: String, finished: @escaping @MainActor () -> Void) -> SpeakResult {
        let base = String(language.prefix(2)).lowercased()
        if let key = SecretEnv.elevenLabs, Self.surfaceLanguages.contains(base) {
            stop()
            self.finished = finished
            task = Task { [weak self] in
                let ok = await self?.playEleven(text: text, language: base, key: key) ?? false
                guard let self, !Task.isCancelled else { return }
                if ok { return }
                if base == "ht" {
                    self.fire()
                    return
                }
                self.finished = nil
                _ = self.apple.speak(text, language: language, finished: finished)
            }
            return .speaking(voice: "elevenlabs-\(base)")
        }
        return apple.speak(text, language: language, finished: finished)
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        apple.stop()
        fire()
    }

    private func fire() {
        let done = finished
        finished = nil
        done?()
    }

    private func playEleven(text: String, language: String, key: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(Self.voiceID)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "text": text,
            "model_id": "eleven_v3",
        ]
        body["language_code"] = language == "tl" ? "fil" : language
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            var (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), body["language_code"] != nil {
                body.removeValue(forKey: "language_code")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 100 else {
                return false
            }
            try Task.checkCancellation()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            self.player = player
            return player.play()
        } catch {
            return false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.fire() }
    }
}
#endif
