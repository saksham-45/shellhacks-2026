import Foundation

/// A bundled voice script (`-myadVoiceStub YES -myadVoiceScript <name>`). PLACEHOLDER format until
/// myAD Language posts theirs (docs/accessibility.md §9): each line is an utterance, its BCP-47
/// language, and the identifier that must appear afterwards.
/// File: UITestFixtures/voicescript.<name>.json (excluded from Release builds).
public struct VoiceScript: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public let text: String
        public let language: String
        public let expect: String
    }
    public let name: String
    public let lines: [Line]

    public static func load(named name: String, bundle: Bundle = .main) -> VoiceScript? {
        guard let url = bundle.url(forResource: "voicescript.\(name)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VoiceScript.self, from: data)
    }
}

extension AppModel {
    /// Replays the script through the router, as if spoken. Status values (a11y.voice.stub):
    /// loading, running <n>/<total>, passed, failed <n>: <reason>, scriptNotFound.
    public func runVoiceScript(bundle: Bundle = .main, pause: Duration = .seconds(1), timeout: Duration = .seconds(10)) async {
        guard voiceScriptRequested, let name = options.voiceScript else { return }
        guard let script = VoiceScript.load(named: name, bundle: bundle) else {
            voiceScriptStatus = "scriptNotFound"
            return
        }
        let clock = ContinuousClock()
        for (i, line) in script.lines.enumerated() {
            let n = i + 1
            voiceScriptStatus = "running \(n)/\(script.lines.count)"
            await hear(line.text, language: line.language, from: .voice)
            let deadline = clock.now.advanced(by: timeout)
            while !presentIdentifiers.contains(line.expect) {
                if clock.now >= deadline {
                    voiceScriptStatus = "failed \(n): expected \(line.expect)"
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: pause)  // so observers (and screen recordings) can see each result
        }
        voiceScriptStatus = "passed"
    }
}
