// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ProfileAnalyzer",
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "ProfileAnalyzer",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],
        ),
        .testTarget(
            name: "ProfileAnalyzerTests",
            dependencies: ["ProfileAnalyzer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
