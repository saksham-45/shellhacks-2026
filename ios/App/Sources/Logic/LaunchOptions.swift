import Foundation
import ADLocale

/// Launch arguments (docs/accessibility.md §9; ARCHITECTURE.md "Test UI"). Read from the process
/// arguments so `-key value` pairs work the same as the UserDefaults argument domain.
///
///   -myadUITest YES                 deterministic: in-memory store, no network, no animations, no first-run
///                                   prompts; leave-app actions are recorded (a11y.router.handoff), not opened
///   -myadSeed demoHousehold|none    demo household (2 people, Kendall pin) or a fresh install (onboarding)
///   -myadSurfaceLanguage es|en|ht   surface language at launch
///   -myadVoiceStub YES              no mic or speech permission prompts; speech output is a stub
///   -myadVoiceScript <name>         replay a bundled voice script through the router at launch
///   -uiTestScreen <screen>          open one screen for screenshots (see `ScreenshotRoute`)
///   -myadProbe creole               Mac batch only: the Creole speech probe screen
/// Also honoured by the system: -AppleLanguages (xx), -AppleLocale xx_US, -UIPreferredContentSizeCategoryName.
public struct LaunchOptions: Equatable, Sendable {
    public enum Seed: String, Sendable { case demoHousehold, none }

    public var uiTest = false
    public var seed: Seed = .none
    public var surface: SurfaceLanguage?
    public var voiceStub = false
    public var voiceScript: String?
    public var screen: String?
    public var probe: String?

    public init() {}

    public static var current: LaunchOptions {
        parse(ProcessInfo.processInfo.arguments, preferredLanguages: Locale.preferredLanguages)
    }

    public static func parse(_ args: [String], preferredLanguages: [String] = []) -> LaunchOptions {
        var o = LaunchOptions()
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            let next = args.index(after: i)
            // A bare flag (no value, or followed by another flag) means YES.
            guard next < args.endIndex, !args[next].hasPrefix("-") else { return "YES" }
            return args[next]
        }
        func bool(_ flag: String) -> Bool {
            guard let v = value(flag)?.lowercased() else { return false }
            return ["yes", "true", "1"].contains(v)
        }
        o.uiTest = bool("-myadUITest")
        o.voiceStub = bool("-myadVoiceStub")
        o.voiceScript = value("-myadVoiceScript").flatMap { $0 == "YES" ? nil : $0 }
        o.screen = value("-uiTestScreen").flatMap { $0 == "YES" ? nil : $0 }
        o.probe = value("-myadProbe").flatMap { $0 == "YES" ? nil : $0 }
        let seedDefault: Seed = (o.uiTest || o.screen != nil) ? .demoHousehold : .none
        o.seed = value("-myadSeed").flatMap(Seed.init(rawValue:)) ?? seedDefault
        o.surface = value("-myadSurfaceLanguage").flatMap(SurfaceLanguage.init(rawValue:))
            ?? appleLanguage(args)
            ?? preferredLanguages.lazy.compactMap(SurfaceLanguage.init(languageTag:)).first
        return o
    }

    /// `-AppleLanguages (ht)` or `-AppleLanguages "(es-US, en)"`: the first es/en/ht entry.
    static func appleLanguage(_ args: [String]) -> SurfaceLanguage? {
        guard let i = args.firstIndex(of: "-AppleLanguages"), args.index(after: i) < args.endIndex else { return nil }
        let list = args[args.index(after: i)].trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        return list.split(separator: ",").lazy
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            .compactMap(SurfaceLanguage.init(languageTag:)).first
    }

    /// No animations and no first-run prompts in UI-test runs.
    public var deterministic: Bool { uiTest }
    /// The voice stub replaces mic, recognizer, and synthesizer (no permission prompts).
    public var usesVoiceStub: Bool { voiceStub || uiTest }
}
