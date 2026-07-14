// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "capsled",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CapsLEDCore", targets: ["CapsLEDCore"]),
        .executable(name: "capsled", targets: ["capsled"]),
        .executable(name: "CapsLEDMenuBar", targets: ["CapsLEDMenuBar"])
    ],
    targets: [
        .target(name: "CapsLEDCore"),
        .executableTarget(
            name: "capsled",
            dependencies: ["CapsLEDCore"]
        ),
        .executableTarget(
            name: "CapsLEDMenuBar",
            dependencies: ["CapsLEDCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
