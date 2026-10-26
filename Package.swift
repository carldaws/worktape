// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "worktape",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.1"),
    ],
    targets: [
        .executableTarget(
            name: "worktape",
            dependencies: ["SwiftTerm"],
            linkerSettings: [
                // Puts the font inside the binary, so worktape ships as a single file.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__symbols_font",
                    "-Xlinker", Context.packageDirectory + "/Fonts/SymbolsNerdFont-Regular.ttf",
                ]),
            ]
        ),
        .testTarget(name: "worktapeTests", dependencies: ["worktape"]),
    ]
)
