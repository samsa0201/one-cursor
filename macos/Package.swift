// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OneCursor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OneCursorCore", targets: ["OneCursorCore"]),
        .executable(name: "onecursor", targets: ["onecursor"]),
        .executable(name: "OneCursorApp", targets: ["OneCursorApp"]),
    ],
    targets: [
        // Platform independent: protocol codec, screen layout and switching logic.
        .target(name: "OneCursorCore"),
        // macOS integration: event tap, event injection, networking, clipboard.
        .target(name: "OneCursorMac", dependencies: ["OneCursorCore"]),
        .executableTarget(name: "onecursor", dependencies: ["OneCursorCore", "OneCursorMac"]),
        .executableTarget(name: "OneCursorApp", dependencies: ["OneCursorCore", "OneCursorMac"]),
        .testTarget(name: "OneCursorCoreTests", dependencies: ["OneCursorCore"]),
    ]
)
