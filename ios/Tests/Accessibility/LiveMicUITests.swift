// XCODE-ONLY. Taps Speak on the live mic path (no voice stub) and checks the process stays up.
// The 2026-09-25 crash was Swift 6 trapping in LiveSpeechSession.requestSpeech on a root queue.

import ADAccessibility
import XCTest

@MainActor
final class LiveMicUITests: XCTestCase {
    func testSpeakDoesNotCrashTheApp() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-myadSeed", "demoHousehold",
            "-myadSurfaceLanguage", "en",
        ]
        app.launch()

        addUIInterruptionMonitor(withDescription: "mic-or-speech") { alert in
            for title in ["Allow", "OK", "Allow While Using App"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }

        let household = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", A11yID.Household.list)).firstMatch
        XCTAssertTrue(household.waitForExistence(timeout: 10), "household did not open")

        let mic = app.buttons.matching(identifier: A11yID.Voice.mic).firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "mic control missing")
        mic.tap()

        XCTAssertEqual(app.state, .runningForeground, "app died on the first Speak tap")
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 4),
            "app died after the speech/mic permission callback"
        )
        let voice = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", A11yID.Voice.panel)).firstMatch
        XCTAssertTrue(
            voice.waitForExistence(timeout: 5) || mic.exists,
            "UI disappeared after Speak"
        )
    }
}
