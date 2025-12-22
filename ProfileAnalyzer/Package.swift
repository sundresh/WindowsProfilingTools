// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if arch(arm64)
let macOSTargetFlag = ["-target", "arm64-apple-macosx10.15.4"]
#else
let macOSTargetFlag = ["-target", "x86_64-apple-macosx10.15.4"]
#endif

let package = Package(
    name: "ProfileAnalyzer",
    platforms: [
        .macOS(.v10_15),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", branch: "main"),
        .package(url: "https://github.com/CoreOffice/XMLCoder", from: "0.17.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "ProfileAnalyzer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "XMLCoder", package: "XMLCoder"),
            ],
            swiftSettings: [
                // macOS 10.15.4 is required for FileHandle read/write availability; Windows remains unaffected.
                .unsafeFlags(macOSTargetFlag, .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "ProfileAnalyzerTests",
            dependencies: ["ProfileAnalyzer"],
            swiftSettings: [
                .unsafeFlags(macOSTargetFlag, .when(platforms: [.macOS])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
