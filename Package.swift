// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UltraTermComputerUse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "UltraTermComputerUseKit",
            targets: ["UltraTermComputerUseKit"]
        ),
        .executable(
            name: "UltraTermComputerUse",
            targets: ["UltraTermComputerUse"]
        ),
        .executable(
            name: "UltraTermComputerUseFixture",
            targets: ["UltraTermComputerUseFixture"]
        ),
        .executable(
            name: "UltraTermComputerUseSmokeSuite",
            targets: ["UltraTermComputerUseSmokeSuite"]
        ),
    ],
    targets: [
        .target(
            name: "UltraTermComputerUseKit",
            path: "packages/UltraTermComputerUseKit/Sources/UltraTermComputerUseKit"
        ),
        .executableTarget(
            name: "UltraTermComputerUse",
            dependencies: ["UltraTermComputerUseKit"],
            path: "apps/UltraTermComputerUse/Sources/UltraTermComputerUse"
        ),
        .executableTarget(
            name: "UltraTermComputerUseFixture",
            dependencies: ["UltraTermComputerUseKit"],
            path: "apps/UltraTermComputerUseFixture/Sources/UltraTermComputerUseFixture"
        ),
        .executableTarget(
            name: "UltraTermComputerUseSmokeSuite",
            dependencies: ["UltraTermComputerUseKit"],
            path: "apps/UltraTermComputerUseSmokeSuite/Sources/UltraTermComputerUseSmokeSuite"
        ),
        .testTarget(
            name: "UltraTermComputerUseKitTests",
            dependencies: ["UltraTermComputerUseKit"],
            path: "packages/UltraTermComputerUseKit/Tests/UltraTermComputerUseKitTests"
        ),
    ]
)
