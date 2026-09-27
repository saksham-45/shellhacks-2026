import XCTest
@testable import ADAccessibility

final class ADAccessibilityTests: XCTestCase {
    func testIdentifiersAndTapTarget() {
        XCTAssertEqual(ADAccessibility.identifier(forCard: "tolls"), "a11y.cards.row.tolls")
        XCTAssertGreaterThanOrEqual(ADAccessibility.minimumTapTarget, 44)
    }
}
