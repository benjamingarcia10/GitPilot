// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitPilot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gitpilot", targets: ["GitPilot"]),
    ],
    targets: [
        .executableTarget(
            name: "GitPilot",
            path: "Sources/GitPilot"
        ),
    ]
)
