#if canImport(UIKit)
import UIKit
import Speech

extension PlatformHooks {
    /// The real device: VoiceOver notifications (language-tagged), URL opening, and a no-prompt
    /// check for live speech input (denied/restricted mic or speech recognition → unavailable).
    @MainActor
    static var live: PlatformHooks {
        PlatformHooks(
            announce: { text, language, screenChanged in
                guard UIAccessibility.isVoiceOverRunning else { return }
                let tagged = NSAttributedString(string: text, attributes: [.accessibilitySpeechLanguage: language])
                UIAccessibility.post(notification: screenChanged ? .screenChanged : .announcement, argument: tagged)
            },
            open: { url in UIApplication.shared.open(url) },
            speechInputAvailable: {
                #if canImport(Speech)
                LiveSpeechSession.isUsable()
                #else
                false
                #endif
            }
        )
    }
}
#endif
