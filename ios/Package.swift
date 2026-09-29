// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WebHTVCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WebHTVCore", targets: ["WebHTVCore"]),
        // IOS-POC-13: builds, signs and verifies runtime packs with the App's own validator. A
        // maintainer tool, never linked into the App.
        .executable(name: "webhtv-runtime-pack", targets: ["WebHTVRuntimePack"]),
    ],
    targets: [
        .target(name: "WebHTVCore", resources: [.copy("Resources/Spiders"), .copy("Resources/OpenCC")]),
        .executableTarget(name: "WebHTVRuntimePack", dependencies: ["WebHTVCore"], path: "Tools/WebHTVRuntimePack"),
        .testTarget(name: "WebHTVCoreTests", dependencies: ["WebHTVCore"]),
    ]
)
