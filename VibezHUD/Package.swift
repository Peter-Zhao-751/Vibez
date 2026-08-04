// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibezHUD",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "VibezSessionKit"),
        .executableTarget(name: "vibez-hud-probe", dependencies: ["VibezSessionKit"]),
        .executableTarget(name: "VibezHUDApp", dependencies: ["VibezSessionKit"]),
        .testTarget(name: "VibezSessionKitTests", dependencies: ["VibezSessionKit"]),
    ]
)
