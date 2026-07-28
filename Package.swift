// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Windshield",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "Windshield",
            targets: ["Windshield"]
        ),
    ],
    targets: [
        .target(
            name: "Windshield"
        ),
        .testTarget(
            name: "WindshieldTests",
            dependencies: ["Windshield"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
