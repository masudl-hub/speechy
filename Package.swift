// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speechy",
    platforms: [
        .macOS(.v14) // WhisperKit requires macOS 14+ (Sonoma). You're on 15 (Sequoia).
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", .upToNextMinor(from: "0.9.0"))
    ],
    targets: [
        .executableTarget(
            name: "Speechy",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Speechy",
            swiftSettings: [
                // AppKit + singletons: Swift 5 mode avoids strict-concurrency churn.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
