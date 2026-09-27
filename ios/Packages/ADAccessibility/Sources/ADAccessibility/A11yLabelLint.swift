// Lint rules for accessibility labels (docs/accessibility.md A11Y-VO-02, A11Y-L10N-02).
// Shared by the SwiftPM tests (Linux) and the XCUITest target (ios/Tests/Accessibility).

import Foundation

public enum A11yLabelLint {
    public enum Problem: Sendable, Equatable, CustomStringConvertible {
        case empty
        case equalsIdentifier(String)
        case looksLikeRawKey(String)

        public var description: String {
            switch self {
            case .empty: return "label is empty"
            case .equalsIdentifier(let id): return "label equals accessibilityIdentifier '\(id)'"
            case .looksLikeRawKey(let l): return "label '\(l)' looks like an untranslated key (dotted or snake_case)"
            }
        }
    }

    /// Returns every problem with `label`; empty array means the label passes.
    public static func problems(label: String, identifier: String?) -> [Problem] {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [.empty] }
        var out: [Problem] = []
        if let identifier, !identifier.isEmpty, trimmed == identifier { out.append(.equalsIdentifier(identifier)) }
        if looksLikeRawKey(trimmed) { out.append(.looksLikeRawKey(trimmed)) }
        return out
    }

    /// Top-level domains that mark a dotted token as a web address (a source name like "miamidade.gov"
    /// or "www.uscis.gov" is a poor label but is not an untranslated key). Language codes that are also
    /// TLDs ("es", "ht") are left out on purpose: "settings.language.ht" is a leaked key.
    static let allowedTLDs: Set<String> = [
        "gov", "us", "org", "com", "net", "edu", "io", "info", "mil", "int", "app", "dev", "co",
    ]

    /// Heuristic for "a String Catalog key leaked to the screen":
    /// - no whitespace, and
    /// - snake_case (`card_detail_title`), or
    /// - starts with a known key namespace (`a11y.`), or
    /// - dotted segments of letters/digits (`household.add`, `household.row.add`), unless it reads as a
    ///   domain: last segment is a TLD and no segment has an underscore (`www.miamidade.gov`).
    /// Numbers, prices, times and abbreviations (`$0.66`, `4.5`, `U.S.`, `p.m.`) do not match.
    public static func looksLikeRawKey(_ label: String) -> Bool {
        let s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        if s.hasPrefix("a11y.") { return true }
        if matches(s, #"^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+$"#) { return true }
        // Dotted segments of 2+ chars each, starting with a letter (so "U.S." and "4.5" don't match).
        guard matches(s, #"^[A-Za-z][A-Za-z0-9_]+(\.[A-Za-z][A-Za-z0-9_]+)+$"#) else { return false }
        return !looksLikeDomain(s)
    }

    /// "miamidade.gov", "www.uscis.gov", "dos.myflorida.com": last segment is a TLD, no underscores.
    static func looksLikeDomain(_ s: String) -> Bool {
        guard !s.contains("_"), let last = s.split(separator: ".").last else { return false }
        return allowedTLDs.contains(last.lowercased())
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
