#if canImport(SwiftUI)
import SwiftUI

private struct LocalizerKey: EnvironmentKey {
    /// Default: no catalogs, so every lookup shows ⟦table:key⟧ and a missing wiring is visible.
    static let defaultValue = Localizer(registry: CatalogRegistry([]), surface: .es)
}

extension EnvironmentValues {
    public var localizer: Localizer {
        get { self[LocalizerKey.self] }
        set { self[LocalizerKey.self] = newValue }
    }
}

extension View {
    /// Derives the Localizer from `settings.surface` (the single source of truth) and sets
    /// `\.locale` for system controls. Reading `settings.surface` here makes the whole subtree
    /// re-render when the chip flips the language: no restart.
    public func languageEnvironment(_ settings: LanguageSettings, catalogs: CatalogRegistry) -> some View {
        modifier(LanguageEnvironmentModifier(settings: settings, catalogs: catalogs))
    }

    /// Kept for existing callers: sets `\.locale` only. Prefer `languageEnvironment`.
    public func surfaceLanguage(_ settings: LanguageSettings) -> some View {
        environment(\.locale, settings.surface.formattingLocale)
    }

    /// Tags a subtree's spoken language for VoiceOver. The one place that hides the mechanism
    /// (device check 4 decides whether `languageIdentifier` on the text is enough).
    public func speechLanguage(_ language: Locale.Language) -> some View {
        environment(\.locale, Locale(identifier: language.minimalIdentifier))
    }
}

private struct LanguageEnvironmentModifier: ViewModifier {
    let settings: LanguageSettings
    let catalogs: CatalogRegistry
    func body(content: Content) -> some View {
        let surface = settings.surface
        content
            .environment(\.localizer, Localizer(registry: catalogs, surface: surface))
            .environment(\.locale, surface.formattingLocale)
    }
}

/// Text with its language tags applied (per run) for VoiceOver. Fallback English (a missing
/// es/ht string) gets a visible "(en inglés)" badge in the surface language and a VoiceOver hint.
public struct LocalizedTextView: View {
    let text: ResolvedText
    @Environment(\.localizer) private var localizer
    public init(_ text: ResolvedText) { self.text = text }
    public var body: some View {
        if text.isFallback {
            let badge = localizer.text(ADLocaleKey.fallbackEnglishBadge)
            let hint = localizer.text(ADLocaleKey.fallbackEnglishHint)
            (Text(text.attributed) + Text(" ") + Text(badge.attributed).foregroundStyle(.secondary))
                .accessibilityHint(Text(hint.attributed))
        } else {
            Text(text.attributed)
        }
    }
}

/// The stacked hero: two accessibility elements in reading order, primary then companion,
/// never combined (combining may drop the per-line language; device check 5).
public struct StackedLineView: View {
    let line: StackedLine
    public init(_ line: StackedLine) { self.line = line }
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Each line carries its own speech language (LANG-01: run tags AND the per-line
            // environment until device check M2 proves the tags alone switch the voice).
            LocalizedTextView(line.primary)
                .font(.largeTitle.bold())
                .speechLanguage(line.primary.language)
                .accessibilityAddTraits(.isHeader)
            if let companion = line.companion {
                LocalizedTextView(companion)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .speechLanguage(companion.language)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
