// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitPilot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gitpilot", targets: ["GitPilot"]),
    ],
    dependencies: [
        // Auto-update framework. Bound to the same minor as scripts/sparkle-tools.sh
        // pins the CLI tools — so the embedded framework and the `sign_update`
        // binary are guaranteed to be format-compatible. Bump both together.
        .package(url: "https://github.com/sparkle-project/Sparkle", "2.9.0"..<"2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "GitPilot",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/GitPilot",
            linkerSettings: [
                // Required so the linked-against Sparkle.framework can be loaded
                // at runtime from GitPilot.app/Contents/Frameworks/. scripts/build-app.sh
                // copies the framework into that location during bundle assembly.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ]
)
