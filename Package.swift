// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoMaster",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VideoMaster", path: "Sources/VideoMaster")
    ]
)
