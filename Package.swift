// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Avadhana",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Avadhana",
            path: "Sources/Avadhana",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AvadhanaTests",
            dependencies: ["Avadhana"],
            path: "Tests/AvadhanaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
