import SwiftUI
import ADCore
import ADRouter

/// Text for a StringKey in the live surface language, tagged with that language for VoiceOver.
struct KeyText: View {
    @Environment(AppModel.self) private var model
    let key: StringKey
    init(_ key: StringKey) { self.key = key }
    var body: some View { Text(tagged(model.text(key), model.surface)) }
}

/// App string (table Localizable) in the live surface language.
struct AppText: View {
    @Environment(AppModel.self) private var model
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View { Text(tagged(model.app(key), model.surface)) }
}

/// Per-string language tagging (docs/accessibility.md: names and numbers stay as written).
func tagged(_ s: String, _ language: String?) -> AttributedString {
    var a = AttributedString(s)
    if let language { a.languageIdentifier = language }
    return a
}

/// A full-width button row: icon + words, at least 44 pt, one action per row, through the router.
struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let titleKey: String
    let systemImage: String
    let id: String?
    var role: ButtonRole?
    let action: AppAction

    var body: some View {
        Button(role: role) {
            model.router.perform(action, from: .touch)
        } label: {
            HStack {
                Label {
                    AppText(titleKey).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.tint).accessibilityHidden(true)
                }
                Spacer()
                if case .navigate = action {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .identifier(id)
        .accessibilityInputLabels([Text(verbatim: model.app(titleKey))])
    }
}

/// Palette from the board: Peach Glow, Mustard, Champagne Mist, Cherry Blossom, Crayola Blue.
enum CivicTheme {
    static let peach = Color(red: 1, green: 0.745, blue: 0.525)       // #FFBE86
    static let mustard = Color(red: 1, green: 0.882, blue: 0.337)     // #FFE156
    static let champagne = Color(red: 1, green: 0.914, blue: 0.808)   // #FFE9CE
    static let blossom = Color(red: 1, green: 0.710, blue: 0.761)     // #FFB5C2
    static let crayola = Color(red: 0.216, green: 0.467, blue: 1)     // #3777FF
    static let warmInk = Color(red: 0.173, green: 0.094, blue: 0.063)

    static let midnight = crayola
    static let sand = champagne
    static let cream = Color.white
    static let coral = mustard
    static let teal = crayola

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.14, blue: 0.28) : champagne
    }
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.16, green: 0.20, blue: 0.36) : Color.white
    }
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? champagne : warmInk
    }
}

enum CivicCopy {
    static func withoutDemoMark(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let marks = [" (demo)", " (egzanp)", " (démo)", " (Demo)", "（演示）", " (демо)"]
        for mark in marks where t.hasSuffix(mark) {
            t = String(t.dropLast(mark.count))
        }
        return t
    }
}

enum ServiceTint: String, CaseIterable {
    case blue, green, orange, red, indigo, teal, purple, pink, brown, cyan

    var fill: Color {
        switch self {
        case .orange, .brown: CivicTheme.peach
        case .green, .cyan: CivicTheme.mustard
        case .pink, .red, .purple: CivicTheme.blossom
        case .blue, .indigo, .teal: CivicTheme.peach
        }
    }
}

struct CivicPrimaryButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.body.weight(.semibold))
                .foregroundStyle(CivicTheme.warmInk)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(CivicTheme.mustard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
    }
}

struct ServiceTile: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let symbol: String
    let tint: ServiceTint
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.fill)
                        .frame(width: 56, height: 56)
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(CivicTheme.warmInk)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CivicTheme.ink(scheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(Text(verbatim: title))
    }
}

struct ServiceGrid<Item: Identifiable>: View {
    let items: [Item]
    var columns: Int = 4
    let tile: (Item) -> ServiceTile

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
        LazyVGrid(columns: cols, alignment: .center, spacing: 14) {
            ForEach(items) { item in tile(item) }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
        .listRowSeparator(.hidden)
    }
}

/// Every screen: title, the mic (a11y.voice.mic) in the toolbar, and Magic Tap to toggle listening.
struct ScreenChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    let titleKey: String
    var large: Bool = false
    var verbatimTitle: String? = nil
    var hideTitle: Bool = false

    func body(content: Content) -> some View {
        let title = hideTitle ? "" : (verbatimTitle ?? model.app(titleKey))
        content
            .navigationTitle(Text(tagged(title, model.surface)))
            .navigationBarTitleDisplayMode((large && !hideTitle) ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { MicButton() }
            }
            .accessibilityAction(.magicTap) { model.toggleListening() }
    }
}

extension View {
    func screen(_ titleKey: String, large: Bool = false, verbatim: String? = nil, hideTitle: Bool = false) -> some View {
        modifier(ScreenChrome(titleKey: titleKey, large: large, verbatimTitle: verbatim, hideTitle: hideTitle))
    }
}

struct MicButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let listening = model.listening
        let unavailable = model.notice?.isSpeechNotice == true && !listening
        let motion = !reduceMotion && !model.options.deterministic
        Button {
            model.toggleListening()
        } label: {
            Image(systemName: listening ? "mic.fill" : (unavailable ? "mic.slash" : "mic"))
                .font(.body.weight(.semibold))
                .foregroundStyle(listening ? CivicTheme.warmInk : CivicTheme.cream)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(listening ? CivicTheme.mustard : CivicTheme.crayola)
                )
                .scaleEffect(listening && pulse && motion ? 1.12 : 1)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Voice.mic)
        .accessibilityLabel(Text(verbatim: model.app(listening ? "app.mic.stop" : "app.mic.label")))
        .accessibilityHint(Text(verbatim: model.app("app.mic.hint")))
        .accessibilityInputLabels([Text(verbatim: model.app("app.mic.label")), Text(verbatim: model.app("app.mic.input_alt"))])
        .onAppear {
            guard motion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: listening) { _, on in
            guard motion else { return }
            pulse = false
            if on {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
        }
    }
}

/// Quiet demo status. Never in the card title.
struct DemoBadge: View {
    var body: some View {
        AppText("app.demo.footer")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// Sets an identifier only when there is one (no empty identifiers in the tree).
    @ViewBuilder func identifier(_ id: String?) -> some View {
        if let id { accessibilityIdentifier(id) } else { self }
    }
}
