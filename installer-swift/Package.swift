// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EnshittifierInstaller",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EnshittifierInstaller",
            path: "Sources/EnshittifierInstaller"
        ),
    ]
)
