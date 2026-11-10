import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// W-271: a remote configuration whose only sites are `csp_*` classes that nothing but its own compatibility pack
// (./spiders/manifest.json beside it) provides. Before the fix the first fetch refused it as noSupportedSites, so it
// was never written to disk and the App stayed on 尚未載入設定 even after the pack arrived.

private let configURL = URL(string: "https://cfg.invalid/a/w271.json")!
private let packURL = URL(string: "https://cfg.invalid/a/spiders/manifest.json")!
private let script = """
var spider = { init: function () { return ''; }, homeContent: function () { return host.result.home([]); } };
module.exports = spider;
"""
private let config = Data(#"{"sites":[{"key":"k","name":"只有爬蟲","type":3,"api":"csp_W271Only"}]}"#.utf8)

private func packStore(classes: [String]) -> SpiderPackStore {
    let hash = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    let entries = classes.map { #"{"class":"\#($0)","path":"\#($0).js","sha256":"\#(hash)"}"# }.joined(separator: ",")
    var served = [packURL.absoluteString: Data(#"{"schema":\#(SpiderPack.schema),"version":"w271","scripts":[\#(entries)]}"#.utf8)]
    for name in classes { served["https://cfg.invalid/a/spiders/\(name).js"] = Data(script.utf8) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w271-\(UUID().uuidString)")
    let replies = served
    return SpiderPackStore(directory: directory) { url in
        guard let data = replies[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
}

/// The installed pack is process-wide; every test puts back what it found.
private func keepingInstalledPack(_ body: () async throws -> Void) async rethrows {
    let before = InstalledSpiderPack.shared.current
    defer { InstalledSpiderPack.shared.current = before }
    try await body()
}

@Suite(.serialized) struct CspOnlyConfigLoadTests {
    @Test func aConfigDrivenOnlyByItsOwnPackLoadsAndInstallsThatPack() async throws {
        try await keepingInstalledPack {
            let store = packStore(classes: ["W271Only"])
            let loaded = try await ConfigLoader.validate(config, from: configURL, packs: store)
            #expect(loaded.sites.map(\.api) == ["csp_W271Only"])
            #expect(await store.installedPack()?.scripts.keys.sorted() == ["W271Only"])
            #expect(loaded.drivableSites(resolvedBy: CSPSourceResolver(source: .remote(configURL))).map(\.key) == ["k"])
        }
    }

    // A pack that does not bring the class changes nothing: still refused, and the installed pack is left alone.
    @Test func aPackWithoutTheClassIsRefusedAndNotInstalled() async throws {
        await keepingInstalledPack {
            let store = packStore(classes: ["SomethingElse"])
            await #expect(throws: ConfigLoaderError.noSupportedSites) {
                try await ConfigLoader.validate(config, from: configURL, packs: store)
            }
            #expect(await store.installedPack() == nil)
        }
    }
}
