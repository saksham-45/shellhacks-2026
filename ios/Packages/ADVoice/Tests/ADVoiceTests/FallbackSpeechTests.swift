import XCTest
import ADCore
import ADLocale
@testable import ADVoice

/// REVIEW-swap1 blocker: fallback English is never read automatically in an English voice.
final class FallbackSpeechTests: XCTestCase {
    func fallbackText() -> SpokenText { SpokenText("English only", language: lang("en"), containsFallback: true) }

    func testFallbackEnglishIsNotPlayedAndOffersListenInEnglish() async {
        let stub = StubSpeechSynthesizer()
        let output = VoiceSpeaker(synthesizers: [stub])
        let result = await output.speak(fallbackText(), privacy: VoicePrivacy(), language: .es)
        XCTAssertFalse(result.isFullySpoken)
        let u = try? XCTUnwrap(result.unavailable)
        XCTAssertEqual(u?.reason, .untranslatedFallback)
        XCTAssertEqual(u?.labeledAlternatives, [.en])
        XCTAssertTrue(u?.language.hasSameLanguageCode(as: lang("es")) ?? false)
        XCTAssertEqual(u?.notice, ADLocaleKey.fallbackEnglishHint)
        let spoken = await stub.spoken
        XCTAssertTrue(spoken.isEmpty, "no unlabeled English audio")
    }

    func testFallbackEnglishPlaysWhenListenerOptsIn() async {
        let stub = StubSpeechSynthesizer()
        let output = VoiceSpeaker(synthesizers: [stub])
        let result = await output.speak(fallbackText(), privacy: VoicePrivacy(), language: .ht, allowEnglishFallback: true)
        XCTAssertTrue(result.isFullySpoken, "\(result.segments)")
        let spoken = await stub.spoken
        XCTAssertEqual(spoken.map(\.text), ["English only"])
    }
}
