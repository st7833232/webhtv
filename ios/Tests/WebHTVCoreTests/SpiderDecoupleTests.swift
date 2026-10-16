import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-61 S5 (W-139): the App carries the spider SDK and no spider; the official pack is what drives them.

private let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let host = RuntimeHost(appVersion: "0.1.79", appBuild: 80)
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct SpiderDecoupleTests {
    // The IPA's Spiders folder is the SDK alone, and the S4 baseline is not in it (the repository keeps that file, frozen
    // at sequence 1, for the publishing workflow only).
    @Test func theAppBundleCarriesOnlyTheSDK() throws {
        let folder = try #require(Bundle.module.url(forResource: "Spiders", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(files) == ["host.js", "drpy-bridge.js", "js-spider.js"])
        #expect(Bundle.module.url(forResource: "SpiderBaseline", withExtension: nil) == nil)
    }

    // Without a pack nothing is driven, while the SDK every drpy and CatVod JS site runs on is still there.
    @Test func withoutAPackNoSpiderIsDriven() {
        let registry = SpiderRegistry.bundled(official: nil, overlaying: nil)
        for name in SpiderRegistry.ported { #expect(!registry.canDrive("csp_\(name)"), "\(name)") }
        #expect(!registry.prelude.isEmpty && !registry.drpyBridge.isEmpty && !registry.jsSpiderBridge.isEmpty)
    }

    // `ported` and `ios/Spiders` say the same thing (W-141 M-3): every name it counts for the banner has a script the
    // pack tool will ship, and every script the tool ships is a name it counts — so the banner never asks for a class
    // the 爬蟲工具 does not bring.
    @Test func everyPortedClassHasItsScriptInTheRepository() throws {
        let repo = SpiderRegistry.bundled(bundle: .repoSpiders)
        for name in SpiderRegistry.ported { #expect(repo.entries[name]?.source == .bundled, "\(name)") }
        let folder = try #require(Bundle.repoSpiders.url(forResource: "Spiders", withExtension: nil))
        let scripts = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".js") }
        #expect(Set(scripts.map { String($0.dropLast(3)) }) == Set(SpiderRegistry.ported.map { SpiderRegistry.aliases[$0] ?? $0 }))
    }

    // An N user's generation (the seed, or the published pack with the same scripts) keeps running after the
    // upgrade, with nothing bundled under it: install the published pack from the repository, then load it.
    @Test func thePublishedPackRunsWithNothingBundled() async throws {
        let official = ios.deletingLastPathComponent().appendingPathComponent("spider-pack/official")
        let manifest = try Data(contentsOf: official.appendingPathComponent("manifest.json"))
        let candidate = try RuntimePackValidator.validateOfficial(manifest: manifest,
                                                                  fetchedFrom: RuntimePackUpdater.manifestURL, host: host)
        var files = [String: Data]()
        for file in candidate.manifest.files {
            files[file.path] = try Data(contentsOf: official.appendingPathComponent("blobs/sha256/\(file.sha256)"))
            #expect(sha(try #require(files[file.path])) == file.sha256)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decouple-\(UUID().uuidString)", isDirectory: true)
        try await RuntimePackStore(root: root).install(candidate, manifest: manifest, files: files, host: host)
        // A relaunch: a new store reads what the last one wrote.
        let pack = try #require(await RuntimePackStore(root: root).load(host: host))
        let registry = SpiderRegistry.bundled(official: pack, overlaying: nil)
        let carried = Set(candidate.manifest.files.flatMap { [$0.className].compactMap { $0 } + ($0.aliases ?? []) })
        #expect(!carried.isEmpty)
        for name in SpiderRegistry.ported where carried.contains(name) {
            #expect(registry.entries[name]?.source == .official(version: candidate.manifest.version), "\(name)")
        }
        #expect(SpiderToolText.status(of: pack).hasPrefix("官方包 \(candidate.manifest.version)"))
    }
}
