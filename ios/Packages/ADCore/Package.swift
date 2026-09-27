// swift-tools-version: 6.0
import PackageDescription

// ADCore depends on nothing. It must never import ADLocale, ADVoice,
// ADCityPack, ADAgentsClient, or ADAccessibility (they import ADCore).
let package = Package(
    name: "ADCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ADCore", targets: ["ADCore"]),
        .library(name: "ADCoreSwiftData", targets: ["ADCoreSwiftData"]),
    ],
    targets: [
        // Pure Swift domain model. Foundation only. Builds and tests on Linux.
        // Resources/ADCore.xcstrings is the "ADCore" string table (Bundle.module).
        .target(name: "ADCore", resources: [.process("Resources")]),
        // SwiftData adapter behind HouseholdStore. The whole file is `#if canImport(SwiftData)`,
        // so on Linux this target compiles to an empty module.
        .target(name: "ADCoreSwiftData", dependencies: ["ADCore"]),
        .testTarget(name: "ADCoreTests", dependencies: ["ADCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
