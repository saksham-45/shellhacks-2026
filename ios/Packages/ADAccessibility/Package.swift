// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADAccessibility",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADAccessibility", targets: ["ADAccessibility"])],
    dependencies: [.package(path: "../ADCore")],
    targets: [
        .target(
            name: "ADAccessibility",
            dependencies: [.product(name: "ADCore", package: "ADCore")],
            resources: [.process("Resources")]
        ),
        // Reference String Catalog checker (A11Y-L10N-01/03). Not a product; run it with
        // `swift run --package-path ios/Packages/ADAccessibility xcstrings-parity --languages es,en,ht <file>...`.
        .executableTarget(name: "xcstrings-parity", dependencies: ["ADAccessibility"]),
        .testTarget(name: "ADAccessibilityTests", dependencies: ["ADAccessibility"]),
    ],
    swiftLanguageModes: [.v6]
)
