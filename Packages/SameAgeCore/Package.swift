// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SameAgeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SameAgeCore", targets: ["SameAgeCore"])
    ],
    targets: [
        .target(
            name: "SameAgeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SameAgeCoreTests",
            dependencies: ["SameAgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
