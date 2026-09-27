// swift-tools-version: 6.0
import PackageDescription

// ADLocale -> ADCore. Never imports ADVoice or any package it resolves strings for:
// other packages' catalogs arrive through `CatalogRegistry` (table name -> bundle).
let package = Package(
    name: "ADLocale",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADLocale", targets: ["ADLocale"])],
    dependencies: [.package(path: "../ADCore")],
    targets: [
        .target(
            name: "ADLocale",
            dependencies: [.product(name: "ADCore", package: "ADCore")],
            resources: [
                // Resources/ADLocale.xcstrings is the "ADLocale" string table (ARCHITECTURE.md §12).
                .process("Resources"),
                // Commands/{es,en,ht}.json: the voice command lexicon (ARCHITECTURE.md §13.3).
                // Copied as a folder so the three files keep their names on every platform.
                .copy("Commands"),
            ]
        ),
        .testTarget(name: "ADLocaleTests", dependencies: ["ADLocale"]),
    ],
    swiftLanguageModes: [.v6]
)
