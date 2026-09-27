import Foundation

/// Keys come from the process environment, then the built Info.plist (xcodegen copies
/// `$(GEMINI_API_KEY)` / `$(ELEVENLABS_API_KEY)` at build time). Never committed.
enum SecretEnv {
    static var gemini: String? { value("GEMINI_API_KEY") }
    static var elevenLabs: String? { value("ELEVENLABS_API_KEY") }

    private static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        let info = (Bundle.main.object(forInfoDictionaryKey: name) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let info, !info.isEmpty, !info.hasPrefix("$(") { return info }
        return nil
    }
}
