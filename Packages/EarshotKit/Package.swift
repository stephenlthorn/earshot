// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EarshotKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EarshotKit", targets: ["EarshotKit"]),
        .executable(name: "earshot", targets: ["earshot"]),
    ],
    targets: [
        .target(name: "EarshotKit"),
        .executableTarget(name: "earshot", dependencies: ["EarshotKit"]),
        .testTarget(name: "EarshotKitTests", dependencies: ["EarshotKit"]),
    ]
)
