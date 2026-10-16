// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WebHTVCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WebHTVCore", targets: ["WebHTVCore"])],
    targets: [
        // IOS-POC-61 S5: the IPA carries no spider and no baseline. SpiderBaseline/manifest.json stays in the repository,
        // frozen at sequence 1, only for .github/workflows/ios-spider-pack.yml's "above the App's baseline" check.
        .target(name: "WebHTVCore", exclude: ["Resources/SpiderBaseline"],
                resources: [.copy("Resources/Spiders"), .copy("Resources/OpenCC"), .copy("Resources/SubtitleFont")]),
        .testTarget(name: "WebHTVCoreTests", dependencies: ["WebHTVCore"]),
    ]
)
