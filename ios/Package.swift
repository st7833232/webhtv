// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WebHTVCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WebHTVCore", targets: ["WebHTVCore"])],
    targets: [
        .target(name: "WebHTVCore", resources: [.copy("Resources/Spiders")]),
        .testTarget(name: "WebHTVCoreTests", dependencies: ["WebHTVCore"]),
    ]
)
