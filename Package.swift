// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "worktape",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "worktape"),
        .testTarget(name: "worktapeTests", dependencies: ["worktape"]),
    ]
)
