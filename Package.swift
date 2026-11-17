// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/aptabase/aptabase-swift.git", exact: "0.4.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeBar",
            dependencies: [.product(name: "Aptabase", package: "aptabase-swift")],
            path: "Sources/ClaudeBar"
        )
    ]
)
