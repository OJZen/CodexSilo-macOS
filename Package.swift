// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSilo",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSilo", targets: ["CodexSilo"])
    ],
    targets: [
        .executableTarget(
            name: "CodexSilo",
            path: "Sources/CodexSilo",
            exclude: [
                "CodexSilo.icon"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CodexSiloTests",
            dependencies: ["CodexSilo"],
            path: "Tests/CodexSiloTests",
            exclude: [
                "Fixtures"
            ]
        )
    ]
)
