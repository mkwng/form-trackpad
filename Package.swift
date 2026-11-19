// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FormTrackpad",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CHIDEvent"),
        .target(name: "TouchCore"),
        .executableTarget(name: "FormTrackpad", dependencies: ["TouchCore", "CHIDEvent"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore"]),
    ]
)
