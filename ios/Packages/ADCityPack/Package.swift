// swift-tools-version: 6.0
import PackageDescription

// ADCityPack (owner: myAD Regions): RegionPack protocol, manifest types, pack resolution, mapping of the
// server's region results to ADCore's FactOutcome, and cached fixture answers for both demo pins.
// Adapters run on the server (server/regionpacks); this package never calls ArcGIS.
let package = Package(
    name: "ADCityPack",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ADCityPack", targets: ["ADCityPack"])],
    dependencies: [.package(path: "../ADCore")],
    targets: [
        .target(
            name: "ADCityPack",
            dependencies: [.product(name: "ADCore", package: "ADCore")],
            resources: [
                .process("Resources/ADCityPack.xcstrings"),
                // Byte copies written by server/regionpacks/scripts/export_fixtures.py (ci-hook checks sync).
                .copy("Resources/Fixtures"),
                .copy("Resources/Manifests"),
                // Fee Check / Listing Check offline data (export_fixtures.py): verified ledger slice and replays.
                .copy("Resources/Checks"),
            ]
        ),
        .testTarget(name: "ADCityPackTests", dependencies: ["ADCityPack"]),
        .executableTarget(name: "CheckProbe", dependencies: ["ADCityPack"], path: "Sources/CheckProbe"),
    ],
    swiftLanguageModes: [.v6]
)
