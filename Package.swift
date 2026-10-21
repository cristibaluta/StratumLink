// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StratumLink",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "StratumLink", targets: ["StratumLink"]),
        .executable(name: "StratumLinkDemo", targets: ["StratumLinkDemo"])
    ],
    targets: [
        .target(name: "StratumLink"),
        .executableTarget(name: "StratumLinkDemo", dependencies: ["StratumLink"]),
        .testTarget(name: "StratumLinkTests", dependencies: ["StratumLink"])
    ],
    swiftLanguageModes: [.v5]
)
