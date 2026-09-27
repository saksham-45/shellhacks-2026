// swift-tools-version: 6.0
import PackageDescription

// ADRouter: the one router and the intent contract (ARCHITECTURE.md §13). Owner: myAD Lead.
// Pure Swift: builds and tests on Linux. Depends on ADCore and ADLocale only.
let package = Package(
    name: "ADRouter",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADRouter", targets: ["ADRouter"])],
    dependencies: [.package(path: "../ADCore"), .package(path: "../ADLocale")],
    targets: [
        .target(
            name: "ADRouter",
            dependencies: [
                .product(name: "ADCore", package: "ADCore"),
                .product(name: "ADLocale", package: "ADLocale"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ADRouterTests", dependencies: ["ADRouter"]),
    ],
    swiftLanguageModes: [.v6]
)
