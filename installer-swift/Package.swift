// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EnshittifierInstaller",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle 2 — in-app updates. EdDSA signature on every DMG; public
        // key embedded as SUPublicEDKey in Info.plist; feed URL is the
        // gh-pages-hosted appcast.xml.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "EnshittifierInstaller",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/EnshittifierInstaller"
        ),
    ]
)
