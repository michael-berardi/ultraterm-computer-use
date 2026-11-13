// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UltraTermComputerUse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "OCULockInstaller", targets: ["OCULockInstaller"]),
        .executable(name: "OCULockService", targets: ["OCULockService"]),
        .executable(name: "OCUGuardian", targets: ["OCUGuardian"]),
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
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
    ],
    targets: [
        .target(
            name: "UltraTermComputerUseVirtualDisplayShim",
            path: "packages/UltraTermComputerUseVirtualDisplayShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .target(
            name: "LockedUseNative",
            path: "packages/LockedUseNative",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .executableTarget(
            name: "OCULockInstaller",
            dependencies: ["UltraTermComputerUseKit", "LockedUseNative"],
            path: "experiments/LockedUse/Sources/Installer"
        ),
        .executableTarget(
            name: "OCULockService",
            dependencies: ["UltraTermComputerUseKit", "LockedUseNative"],
            path: "experiments/LockedUse/Sources/Broker"
        ),
        .executableTarget(
            name: "OCUGuardian",
            dependencies: ["UltraTermComputerUseKit"],
            path: "experiments/LockedUse/Sources/Guardian"
        ),
        .target(
            name: "UltraTermComputerUseKit",
            dependencies: ["UltraTermComputerUseVirtualDisplayShim", "LockedUseNative", .product(name: "libwebp", package: "libwebp-Xcode")],
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
        .testTarget(
            name: "GuardianInputTests",
            dependencies: ["OCUGuardian"],
            path: "experiments/LockedUse/Tests/GuardianInputTests"
        ),
        .testTarget(
            name: "PermissionOnboardingTests",
            dependencies: ["UltraTermComputerUse"],
            path: "apps/UltraTermComputerUse/Tests/PermissionOnboardingTests"
        ),
    ]
)
