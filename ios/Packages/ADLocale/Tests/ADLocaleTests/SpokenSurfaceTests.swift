import XCTest
import ADCore
@testable import ADLocale

final class SpokenSurfaceTests: XCTestCase {
    func testTagMapsToASurfaceOrNil() {
        XCTAssertEqual(SpokenSurface.fromTag("es-US"), .es)
        XCTAssertEqual(SpokenSurface.fromTag("pt-BR"), .pt)
        XCTAssertEqual(SpokenSurface.fromTag("zh-Hans"), .zh)
        XCTAssertNil(SpokenSurface.fromTag("hi"))
        XCTAssertNil(SpokenSurface.fromTag(""))
    }

    func testScriptDetectsArabicHanCyrillic() {
        XCTAssertEqual(SpokenSurface.fromScript("هذا العنوان"), .ar)
        XCTAssertEqual(SpokenSurface.fromScript("这个地址在哪里"), .zh)
        XCTAssertEqual(SpokenSurface.fromScript("Где этот адрес"), .ru)
        XCTAssertNil(SpokenSurface.fromScript("Where is the pin?"))
        XCTAssertNil(SpokenSurface.fromScript("¿Dónde está el pin?"))
        XCTAssertNil(SpokenSurface.fromScript("A"))
    }

    func testResolveKeepsCurrentWhenTagIsUnknown() {
        XCTAssertEqual(SpokenSurface.resolve(text: "next step", tagged: "en", current: .es), .en)
        XCTAssertEqual(SpokenSurface.resolve(text: "next step", tagged: "hi", current: .es), .es)
        XCTAssertEqual(SpokenSurface.resolve(text: "هذا", tagged: "en", current: .en), .ar)
    }
}
