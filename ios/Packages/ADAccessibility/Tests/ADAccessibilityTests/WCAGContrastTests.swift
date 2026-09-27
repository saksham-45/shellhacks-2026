import Testing
@testable import ADAccessibility

@Suite("WCAG contrast")
struct WCAGContrastTests {
    @Test func blackOnWhiteIs21() {
        let r = WCAGContrast.ratio(.init(hex: "#000000")!, .init(hex: "#FFFFFF")!)
        #expect(abs(r - 21.0) < 1e-9)
    }

    @Test func sameColorIs1() {
        #expect(WCAGContrast.ratio(.init(hex: "777")!, .init(hex: "777777")!) == 1.0)
    }

    @Test func orderDoesNotMatter() {
        let a = SRGBColor(hex: "#0B5FFF")!, b = SRGBColor(hex: "#F2F2F7")!
        #expect(WCAGContrast.ratio(a, b) == WCAGContrast.ratio(b, a))
    }

    // Known reference values (WebAIM contrast checker values, rounded to 2 dp).
    @Test(arguments: [
        ("#767676", "#FFFFFF", 4.54),   // classic "lightest AA gray on white"
        ("#777777", "#FFFFFF", 4.48),   // fails AA by a hair
        ("#595959", "#FFFFFF", 7.00),   // AAA gray on white
        ("#FF0000", "#FFFFFF", 4.00),
        ("#0000FF", "#FFFFFF", 8.59),
    ])
    func referenceRatios(fg: String, bg: String, expected: Double) {
        let r = WCAGContrast.ratio(SRGBColor(hex: fg)!, SRGBColor(hex: bg)!)
        #expect(abs(r - expected) < 0.01, "\(fg) on \(bg) = \(r)")
    }

    @Test func thresholdsAreNotRounded() {
        let white = SRGBColor(hex: "#FFFFFF")!
        #expect(WCAGContrast.meetsAA(SRGBColor(hex: "#767676")!, on: white))
        #expect(!WCAGContrast.meetsAA(SRGBColor(hex: "#777777")!, on: white))   // 4.48 < 4.5
        #expect(WCAGContrast.meetsAA(SRGBColor(hex: "#777777")!, on: white, size: .large))
        #expect(!WCAGContrast.meetsAAA(SRGBColor(hex: "#767676")!, on: white))
        #expect(WCAGContrast.meetsAAA(SRGBColor(hex: "#595959")!, on: white))
        #expect(WCAGContrast.meetsNonText(SRGBColor(hex: "#949494")!, on: white))
    }

    /// WCAG large scale = 18 CSS pt regular / 14 CSS pt bold = 24 / 18.67 iOS pt. Not the HIG's looser rule.
    @Test func largeTextFollowsWCAGNotHIG() {
        typealias T = WCAGContrast.TextSize
        #expect(T.largeRegularMinPoints == 24)
        #expect(abs(T.largeBoldMinPoints - 56.0 / 3) < 1e-12)
        #expect(T(points: 17, isBold: false) == .body)      // Body
        #expect(T(points: 18, isBold: false) == .body)      // HIG would call this large; WCAG does not
        #expect(T(points: 20, isBold: false) == .body)      // Title 3 regular
        #expect(T(points: 23.9, isBold: false) == .body)
        #expect(T(points: 24, isBold: false) == .large)
        #expect(T(points: 28, isBold: false) == .large)     // Title 1
        #expect(T(points: 17, isBold: true) == .body)       // bold Body: HIG large, WCAG body
        #expect(T(points: 18.6, isBold: true) == .body)
        #expect(T(points: 18.67, isBold: true) == .large)
        #expect(T(points: 20, isBold: true) == .large)
    }

    /// AAA targets stay 7:1 body / 4.5:1 large; AA 4.5:1 / 3:1.
    @Test func sizeAwareChecks() {
        let white = SRGBColor(hex: "#FFFFFF")!
        let gray = SRGBColor(hex: "#767676")!     // 4.54:1
        #expect(WCAGContrast.Threshold.aaaBody == 7 && WCAGContrast.Threshold.aaaLarge == 4.5)
        #expect(!WCAGContrast.meetsAAA(gray, on: white, points: 20, isBold: false))   // body -> needs 7:1
        #expect(WCAGContrast.meetsAAA(gray, on: white, points: 24, isBold: false))    // large -> 4.5:1
        #expect(WCAGContrast.meetsAAA(gray, on: white, points: 19, isBold: true))
        let red = SRGBColor(hex: "#FF0000")!      // 4.00:1
        #expect(!WCAGContrast.meetsAA(red, on: white, points: 18, isBold: false))     // body -> needs 4.5:1
        #expect(WCAGContrast.meetsAA(red, on: white, points: 24, isBold: false))      // large -> 3:1
    }

    @Test func hexParsing() {
        #expect(SRGBColor(hex: "#abc") == SRGBColor(hex: "AABBCC"))
        #expect(SRGBColor(hex: "12345") == nil)
        #expect(SRGBColor(hex: "zzzzzz") == nil)
        #expect(SRGBColor(hex: "#1C1C1E")!.description == "#1C1C1E")
    }

    @Test func translucentTextIsCompositedBeforeMeasuring() {
        // 60% white text over near-black: must be measured after compositing.
        let bg = SRGBColor(hex: "#111111")!
        let fg = SRGBColor(hex: "#FFFFFF")!.composited(alpha: 0.6, over: bg)
        let r = WCAGContrast.ratio(fg, bg)
        #expect(r < WCAGContrast.ratio(SRGBColor(hex: "#FFFFFF")!, bg))
        #expect(r > 4.5)
    }
}
