// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OralBKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OralBKit", targets: ["OralBKit"])],
    targets: [
        .target(name: "OralBKit"),
        .testTarget(name: "OralBKitTests", dependencies: ["OralBKit"]),
    ]
)
