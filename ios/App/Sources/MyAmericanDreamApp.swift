import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct MyAmericanDreamApp: App {
    @State private var model: AppModel

    init() {
        let options = LaunchOptions.current
        let speech: any SpeechOutput
        #if canImport(AVFoundation)
        speech = options.usesVoiceStub ? StubSpeechOutput() : ElevenLabsSpeechOutput()
        #else
        speech = StubSpeechOutput()
        #endif
        let model = AppModel(options: options, speech: speech, platform: .live)
        _model = State(initialValue: model)
        AppModelHolder.shared = model
        #if canImport(UIKit)
        if options.deterministic { UIView.setAnimationsEnabled(false) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if model.options.probe == "creole" {
                CreoleProbeView()
            } else {
                RootView()
                    .environment(model)
                    .task {
                        if let screen = model.options.screen { ScreenshotRoute.apply(screen, to: model) }
                        await model.runVoiceScript()
                    }
            }
        }
    }
}

/// The one app model, for App Intents (they run in the app process and call the same router).
@MainActor
enum AppModelHolder {
    static var shared: AppModel?
}
