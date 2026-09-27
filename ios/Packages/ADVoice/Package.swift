// swift-tools-version: 6.0
import PackageDescription

// ADVoice -> ADLocale -> ADCore. Never the reverse, and never ADRouter (it only hears and speaks).
// No third-party dependencies and no provider SDKs: cloud speech goes through our server's proxy
// (decision D7) behind `SpeechProxyTransport`, which the app supplies at runtime.
let package = Package(
    name: "ADVoice",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADVoice", targets: ["ADVoice"])],
    dependencies: [
        .package(path: "../ADLocale"),
        .package(path: "../ADCore"),
    ],
    targets: [
        .target(
            name: "ADVoice",
            dependencies: [
                .product(name: "ADLocale", package: "ADLocale"),
                .product(name: "ADCore", package: "ADCore"),
            ],
            resources: [
                // ADVoice.xcstrings (table "ADVoice"), LanguageID.json (text language scorer data),
                // PrerenderedAudio.json (clip manifest; empty until native review).
                .process("Resources"),
                // Scripts for `-myadVoiceStub -myadVoiceScript <name>` (format: VoiceScript.swift).
                .copy("VoiceScripts"),
            ]
        ),
        .testTarget(name: "ADVoiceTests", dependencies: ["ADVoice"]),
    ],
    swiftLanguageModes: [.v6]
)
