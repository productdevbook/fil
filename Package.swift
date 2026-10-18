// swift-tools-version: 6.0
import PackageDescription

// Targets current macOS on Apple Silicon only; no older OS versions or Intel.
let package = Package(
    name: "Fil",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .executable(name: "fil", targets: ["fil"]),
        .library(name: "CleanCore", targets: ["CleanCore"]),
        .library(name: "MapCore", targets: ["MapCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
    ],
    targets: [
        .target(name: "ScanCore"),
        .target(name: "CleanCore", dependencies: [
            "ScanCore",
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        .executableTarget(name: "fil", dependencies: ["CleanCore", "ScanCore"]),
        // Disk Map geometry: squarified treemap and the two-level layout. No UI.
        .target(name: "MapCore", dependencies: ["CleanCore"]),
        // Fixture helpers shared by the test targets: temporary trees, never the home folder or the real Trash.
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore", "TestSupport"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore", "ScanCore", "TestSupport"]),
        .testTarget(name: "FilTests", dependencies: ["fil"]),
        .testTarget(name: "MapCoreTests", dependencies: ["MapCore", "CleanCore"]),
    ]
)
