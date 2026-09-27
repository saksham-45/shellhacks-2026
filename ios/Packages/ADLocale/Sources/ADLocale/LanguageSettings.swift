import Foundation
import Observation
import ADCore

/// Where the language choice is kept. Values are plain BCP-47 strings, never the nested
/// `Locale.Language` JSON (ARCHITECTURE.md §12). Closures so it stays `Sendable` without
/// holding a non-Sendable `UserDefaults`.
public struct LanguagePreferenceStore: Sendable {
    public struct Snapshot: Hashable, Sendable {
        public var surface: String?
        public var thinkIn: String?
        public init(surface: String? = nil, thinkIn: String? = nil) {
            self.surface = surface
            self.thinkIn = thinkIn
        }
    }

    let load: @Sendable () -> Snapshot
    let save: @Sendable (Snapshot) -> Void

    public init(load: @escaping @Sendable () -> Snapshot, save: @escaping @Sendable (Snapshot) -> Void) {
        self.load = load
        self.save = save
    }

    static let surfaceKey = "myad.language.surface"
    static let thinkInKey = "myad.language.thinkIn"

    /// Device-level (decision D4), in `UserDefaults.standard`.
    public static let userDefaults = LanguagePreferenceStore(
        load: {
            let d = UserDefaults.standard
            return Snapshot(surface: d.string(forKey: surfaceKey), thinkIn: d.string(forKey: thinkInKey))
        },
        save: { s in
            let d = UserDefaults.standard
            d.set(s.surface, forKey: surfaceKey)
            d.set(s.thinkIn, forKey: thinkInKey)
        })

    /// For tests and previews.
    public static func inMemory(_ initial: Snapshot = Snapshot()) -> LanguagePreferenceStore {
        let box = SnapshotBox(initial)
        return LanguagePreferenceStore(load: { box.value }, save: { box.value = $0 })
    }
}

/// Lock-protected holder for the in-memory store.
final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LanguagePreferenceStore.Snapshot
    init(_ value: LanguagePreferenceStore.Snapshot) { stored = value }
    var value: LanguagePreferenceStore.Snapshot {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Live language state. Buttons follow `surface`; spoken explanations follow `thinkIn`.
/// Changing `surface` re-renders every view that reads it (Observation): no restart,
/// no `AppleLanguages` write. The surface is per device (decision D4).
@MainActor @Observable
public final class LanguageSettings {
    /// Setting it (picker, chip, voice command) counts as a choice and is remembered.
    public var surface: SurfaceLanguage {
        didSet {
            hasChosenSurface = true
            persist()
        }
    }
    public var thinkIn: Locale.Language {
        didSet { persist() }
    }
    /// False until someone picks a surface; the first-launch picker shows until then.
    public private(set) var hasChosenSurface: Bool

    @ObservationIgnored private let store: LanguagePreferenceStore

    /// First launch (decision D4): the first system language that is es, en or ht, else es.
    public init(store: LanguagePreferenceStore, systemLanguages: [String] = Locale.preferredLanguages) {
        self.store = store
        let saved = store.load()
        let savedSurface = saved.surface.flatMap(SurfaceLanguage.init(rawValue:))
        let initial = savedSurface ?? LanguageSettings.firstLaunchSurface(systemLanguages: systemLanguages)
        surface = initial
        hasChosenSurface = savedSurface != nil
        let savedThinkIn = saved.thinkIn.flatMap { $0.isEmpty ? nil : Locale.Language(identifier: $0) }
        thinkIn = savedThinkIn ?? initial.language
    }

    /// Existing callers and previews: in-memory, already chosen.
    public convenience init(surface: SurfaceLanguage, thinkIn: Locale.Language? = nil) {
        self.init(store: .inMemory(.init(surface: surface.rawValue, thinkIn: (thinkIn ?? surface.language).minimalIdentifier)),
                  systemLanguages: [])
    }

    public nonisolated static func firstLaunchSurface(systemLanguages: [String]) -> SurfaceLanguage {
        for tag in systemLanguages {
            if let s = SurfaceLanguage(languageTag: tag) { return s }
        }
        return .es
    }

    /// The first-launch picker (or the chip) chose a surface.
    public func choose(_ surface: SurfaceLanguage) {
        self.surface = surface
    }

    /// Seeds `thinkIn` from the active person. Never touches the surface (it is per device).
    public func follow(_ person: Person) {
        thinkIn = person.thinkIn
    }

    /// Wire form of the surface (`surface_language`).
    public var surfaceTag: String { surface.rawValue }
    /// Wire form of the think-in language (`think_in`), e.g. "hi".
    public var thinkInTag: String { thinkIn.minimalIdentifier }
    /// Kept for existing callers.
    public var locale: Locale { surface.formattingLocale }

    private func persist() {
        guard hasChosenSurface else {
            // Before a choice only think-in is remembered, so first launch keeps asking.
            store.save(.init(surface: nil, thinkIn: thinkIn.minimalIdentifier))
            return
        }
        store.save(.init(surface: surface.rawValue, thinkIn: thinkIn.minimalIdentifier))
    }
}
