// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ADAgentsClient",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADAgentsClient", targets: ["ADAgentsClient"])],
    dependencies: [
        .package(path: "../ADCore"),
        .package(path: "../ADLocale"),
        .package(path: "../ADRouter"),
    ],
    targets: [
        .target(
            name: "ADAgentsClient",
            dependencies: [
                .product(name: "ADCore", package: "ADCore"),
                .product(name: "ADLocale", package: "ADLocale"),
                .product(name: "ADRouter", package: "ADRouter"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ADAgentsClientTests",
            dependencies: ["ADAgentsClient", "ADRouter", "ADCore", "ADLocale"],
            resources: [.copy("server_message_keys.json")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
