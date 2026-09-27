// WCAG 2.2 contrast ratio. Definitions: https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio
// and https://www.w3.org/TR/WCAG22/#dfn-relative-luminance (sRGB threshold 0.04045).
// Pure Swift + Foundation (for pow); safe on Linux.

import Foundation

/// An opaque sRGB color with components in 0...1.
public struct SRGBColor: Sendable, Hashable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = SRGBColor.clamp(red)
        self.green = SRGBColor.clamp(green)
        self.blue = SRGBColor.clamp(blue)
    }

    /// 8-bit components, e.g. `SRGBColor(r8: 0x1C, g8: 0x1C, b8: 0x1E)`.
    public init(r8: UInt8, g8: UInt8, b8: UInt8) {
        self.init(red: Double(r8) / 255, green: Double(g8) / 255, blue: Double(b8) / 255)
    }

    /// Parses "#RRGGBB", "RRGGBB", "#RGB" or "RGB". Returns nil for anything else.
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        let chars = Array(s)
        let expanded: [Character]
        switch chars.count {
        case 3: expanded = chars.flatMap { [$0, $0] }
        case 6: expanded = chars
        default: return nil
        }
        guard let value = UInt32(String(expanded), radix: 16) else { return nil }
        self.init(r8: UInt8((value >> 16) & 0xFF), g8: UInt8((value >> 8) & 0xFF), b8: UInt8(value & 0xFF))
    }

    public var description: String {
        func h(_ c: Double) -> String {
            let v = Int((c * 255).rounded())
            let s = String(v, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + h(red) + h(green) + h(blue)
    }

    /// WCAG 2.2 relative luminance (0 = black, 1 = white).
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Composites `self` at `alpha` over an opaque `background` (simple sRGB source-over,
    /// the same approximation contrast checkers use for translucent text/material).
    public func composited(alpha: Double, over background: SRGBColor) -> SRGBColor {
        let a = SRGBColor.clamp(alpha)
        return SRGBColor(
            red: red * a + background.red * (1 - a),
            green: green * a + background.green * (1 - a),
            blue: blue * a + background.blue * (1 - a)
        )
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}

public enum WCAGContrast {
    /// (L1 + 0.05) / (L2 + 0.05), L1 = lighter. Range 1...21. Order of arguments does not matter.
    public static func ratio(_ a: SRGBColor, _ b: SRGBColor) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        let (hi, lo) = la >= lb ? (la, lb) : (lb, la)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Text size class per WCAG 2.2 "large scale": at least 18 pt regular or 14 pt bold, where WCAG's
    /// pt is the CSS point (1 pt = 4/3 CSS px). iOS points are treated as CSS px (the usual mapping), so
    /// large = >= 24 iOS pt regular, or >= 18.67 iOS pt (56/3) bold. "Bold" means bold or heavier
    /// (semibold is not bold). This is stricter than the HIG's contrast table (18 pt, or any bold):
    /// we follow WCAG, so e.g. 17 pt semibold Headline and 20 pt regular Title 3 are body text.
    public enum TextSize: Sendable, Equatable {
        case body, large

        /// Minimum iOS points for large-scale regular text (18 CSS pt).
        public static let largeRegularMinPoints: Double = 18 * 4 / 3
        /// Minimum iOS points for large-scale bold text (14 CSS pt).
        public static let largeBoldMinPoints: Double = 14 * 4 / 3

        /// Classifies text by its rendered size in iOS points and whether its weight is bold or heavier.
        public init(points: Double, isBold: Bool) {
            let minimum = isBold ? TextSize.largeBoldMinPoints : TextSize.largeRegularMinPoints
            self = points + 1e-9 >= minimum ? .large : .body
        }
    }

    /// Thresholds used by myMiami (docs/accessibility.md A11Y-CON-*).
    public enum Threshold {
        /// WCAG 1.4.3 AA body text.
        public static let aaBody = 4.5
        /// WCAG 1.4.3 AA large text.
        public static let aaLarge = 3.0
        /// WCAG 1.4.6 AAA body text (project SHOULD).
        public static let aaaBody = 7.0
        /// WCAG 1.4.6 AAA large text (project SHOULD).
        public static let aaaLarge = 4.5
        /// WCAG 1.4.11 non-text (icons, control boundaries, focus rings).
        public static let nonText = 3.0
    }

    public static func meetsAA(_ fg: SRGBColor, on bg: SRGBColor, size: TextSize = .body) -> Bool {
        meets(ratio(fg, bg), size == .body ? Threshold.aaBody : Threshold.aaLarge)
    }

    public static func meetsAAA(_ fg: SRGBColor, on bg: SRGBColor, size: TextSize = .body) -> Bool {
        meets(ratio(fg, bg), size == .body ? Threshold.aaaBody : Threshold.aaaLarge)
    }

    /// AA check for text of a given rendered size (iOS points) and weight.
    public static func meetsAA(_ fg: SRGBColor, on bg: SRGBColor, points: Double, isBold: Bool) -> Bool {
        meetsAA(fg, on: bg, size: TextSize(points: points, isBold: isBold))
    }

    /// AAA check (project SHOULD) for text of a given rendered size (iOS points) and weight.
    public static func meetsAAA(_ fg: SRGBColor, on bg: SRGBColor, points: Double, isBold: Bool) -> Bool {
        meetsAAA(fg, on: bg, size: TextSize(points: points, isBold: isBold))
    }

    public static func meetsNonText(_ fg: SRGBColor, on bg: SRGBColor) -> Bool {
        meets(ratio(fg, bg), Threshold.nonText)
    }

    /// WCAG says "at least"; no rounding up is allowed (4.499 fails 4.5). A tiny epsilon absorbs
    /// floating-point noise only.
    static func meets(_ value: Double, _ threshold: Double) -> Bool {
        value + 1e-9 >= threshold
    }
}
