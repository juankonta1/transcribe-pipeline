// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallDrop",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CallDrop",
            path: "Sources/CallDrop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
