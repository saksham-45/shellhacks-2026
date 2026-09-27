import ADCore

/// Shared accessibility contract. Owner: myAD Access (standards) with myAD Lead (app usage).
public enum ADAccessibility {
    /// Minimum hit target in points (spec hard rule 4).
    public static let minimumTapTarget: Double = 44

    /// Stable accessibility identifier for a card, used by UI tests under ios/Tests/Accessibility.
    public static func identifier(forCard id: Card.ID) -> String { A11yID.Cards.row(id.rawValue) }
}

/// Anything shown must also be speakable (speech for every card).
public protocol SpokenRepresentable {
    /// Text read aloud for this element, already in the surface language.
    var spokenText: String { get }
}

#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Enforces the 44pt minimum target. Body to be refined by myAD Access.
    public func adTapTarget() -> some View {
        frame(minWidth: ADAccessibility.minimumTapTarget, minHeight: ADAccessibility.minimumTapTarget)
    }
}
#endif
