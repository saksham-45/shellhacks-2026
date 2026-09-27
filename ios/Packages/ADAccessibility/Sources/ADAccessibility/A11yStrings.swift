import Foundation

/// Keys and bundle for strings that live in `ADAccessibility.xcstrings`.
/// App code: `Text(LocalizedStringKey(A11yStrings.playInKreyolHint), tableName: A11yStrings.table, bundle: A11yStrings.bundle)`.
///
/// The "Play in Kreyòl" custom action's LABEL is not here: its single key is ADVoice's
/// `VoiceKey.kreyolPlay` (`kreyol.play`, table "ADVoice"), agreed with myAD Language on 2026-09-25.
/// ADAccessibility's former `a11y.card.playInKreyol` is retired (docs/accessibility.md A11Y-LANG-03 part 3).
public enum A11yStrings {
    public static let table = "ADAccessibility"
    public static let bundle: Bundle = .module

    /// Hint on a focused Kreyòl card: Magic Tap plays its Creole audio there, and toggles the mic
    /// everywhere else (A11Y-VC-04). ADVoice has no equivalent key, so it stays in this catalog.
    public static let playInKreyolHint = "a11y.card.playInKreyol.hint"
}
