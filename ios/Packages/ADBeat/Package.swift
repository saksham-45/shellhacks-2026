// swift-tools-version: 6.0
import PackageDescription

// ADBeat: the demo Beat contract (contracts/beat/README.md). No UI, no dependencies:
// feature packages conform to `Beat`; ios/App owns the views and the demo screen.
let package = Package(
    name: "ADBeat",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADBeat", targets: ["ADBeat"])],
    targets: [
        .target(name: "ADBeat", resources: [.process("Resources")]),
        .testTarget(name: "ADBeatTests", dependencies: ["ADBeat"]),
    ],
    swiftLanguageModes: [.v6]
)
