import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-13B. The updater against an in-memory "server": what it fetches, from where, and that
// every failure leaves the scope exactly as it was.

private let config = URL(string: "https://example.invalid/repo/raw/main/wang-movie.json")!
private let host = RuntimeHost(appVersion: "0.1.31", appBuild: 32)

/// A published directory: `manifest.json` (+ `.sig`) and `blobs/sha256/<hex>`, keyed by URL.
private final class Server: @unchecked Sendable {
    var files = [String: Data]()
    var requested = [String]()
    private let lock = NSLock()

    var fetch: RuntimePackUpdater.Fetch {
        { [self] url, limit in
            let body: Data? = lock.withLock {
                requested.append(url.absoluteString)
                return files[url.absoluteString]
            }
            guard let body else { throw RuntimePackUpdater.FetchError.notFound }
            guard body.count <= limit else { throw RuntimePackUpdater.FetchError.tooLarge(body.count) }
            return body
        }
    }

    func publish(_ scripts: [String: String], at manifestURL: URL, scope: String = "config", sequence: Int = 1,
                 signer: Curve25519.Signing.PrivateKey? = nil, edit: (inout [String: Any]) -> Void = { _ in }) throws {
        let entries = scripts.sorted { $0.key < $1.key }.map { name, script -> [String: Any] in
            let body = Data(script.utf8)
            let sha = DrpyEngine.digest(body)
            files[RuntimePackChannel.blobURL(sha, beside: manifestURL)!.absoluteString] = body
            return ["path": "spiders/\(name).js", "logicalType": "spider.js", "class": name,
                    "bytes": body.count, "sha256": sha]
        }
        var object: [String: Any] = [
            "format": "webhtv.runtime-pack", "schema": 1, "packId": "test.spiders", "scope": ["kind": scope],
            "sequence": sequence, "version": "v\(sequence)", "files": entries,
            "requires": ["abi": ["js.host": ["major": 1, "minMinor": 1], "catvod.result": ["major": 1, "minMinor": 0]]],
        ]
        if scope == "global" { object["expires"] = "2030-01-01T00:00:00Z" }
        edit(&object)
        let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        files[manifestURL.absoluteString] = manifest
        if let signer {
            let sig = try signer.signature(for: manifest).base64EncodedString()
            files[manifestURL.absoluteString + ".sig"] = try JSONEncoder().encode(
                RuntimePackSignature(keyId: RuntimeTrustRoot.keyId(for: signer.publicKey), sig: sig))
        }
    }
}

private let spider = "var spider = { homeContent: function () { return '{}'; } }; module.exports = spider;"
private let manifestURL = URL(string: "https://example.invalid/repo/raw/main/runtime/manifest.json")!

private func updater(_ server: Server) -> (RuntimePackUpdater, RuntimePackStore) {
    let store = RuntimePackStore(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("runtime-updater-\(UUID().uuidString)", isDirectory: true))
    return (RuntimePackUpdater(store: store, fetch: server.fetch), store)
}

@Test func theConfigurationsPackIsLookedForBesideTheConfiguration() {
    #expect(RuntimePackChannel.manifestURL(for: RuntimeScope(.remote(config))!, source: .remote(config)) == manifestURL)
    #expect(RuntimePackChannel.manifestURL(for: .global, source: .remote(config)) == RuntimePackChannel.globalManifestURL)
    #expect(RuntimePackChannel.blobURL(String(repeating: "a", count: 64), beside: manifestURL)?.absoluteString
            == "https://example.invalid/repo/raw/main/runtime/blobs/sha256/" + String(repeating: "a", count: 64))
}

@Test func aPublishedPackIsInstalledOnceAndThenUpToDate() async throws {
    let server = Server()
    try server.publish(["AppGet": spider], at: manifestURL)
    let (updater, store) = updater(server)
    let scope = try #require(RuntimeScope(.remote(config)))

    guard case .installed(let pack?) = await updater.check(scope, source: .remote(config), host: host) else {
        Issue.record("not installed"); return
    }
    #expect(pack.scripts.keys.sorted() == ["AppGet"])
    #expect(await store.load(scope, host: host) == pack)
    #expect(await updater.check(scope, source: .remote(config), host: host) == .upToDate)

    try server.publish(["AppGet": spider + " "], at: manifestURL, sequence: 2)
    guard case .installed(let next?) = await updater.check(scope, source: .remote(config), host: host) else {
        Issue.record("sequence 2 not installed"); return
    }
    #expect(next.generation.sequence == 2)
    #expect(await store.state(for: scope)?.lastKnownGood == pack.generation)
}

@Test func aConfigurationThatPublishesNothingHasNoPack() async throws {
    let (updater, store) = updater(Server())
    let scope = try #require(RuntimeScope(.remote(config)))
    #expect(await updater.check(scope, source: .remote(config), host: host) == .noPack)
    #expect(await updater.check(scope, source: .importedFile, host: host) == .noPack)
    #expect(await store.state(for: scope) == nil)
}

@Test func everyFailureLeavesTheWorkingGenerationWhereItWas() async throws {
    let server = Server()
    try server.publish(["AppGet": spider], at: manifestURL)
    let (updater, store) = updater(server)
    let scope = try #require(RuntimeScope(.remote(config)))
    guard case .installed(let working?) = await updater.check(scope, source: .remote(config), host: host) else {
        Issue.record("not installed"); return
    }

    // A blob that does not match what the manifest declares.
    try server.publish(["AppGet": "var spider = 2;"], at: manifestURL, sequence: 2)
    let blob = try #require(server.files.keys.first { $0.contains("/blobs/") && server.files[$0] == Data("var spider = 2;".utf8) })
    server.files[blob] = Data("var spider = 3;".utf8)
    #expect(await updater.check(scope, source: .remote(config), host: host) == .rejected(.digestMismatch("spiders/AppGet.js")))
    // A blob that is missing, or larger than declared.
    server.files[blob] = nil
    #expect(await updater.check(scope, source: .remote(config), host: host) == .rejected(.fileMissing("spiders/AppGet.js")))
    server.files[blob] = Data(repeating: 32, count: 100)
    #expect(await updater.check(scope, source: .remote(config), host: host) == .rejected(.fileTooLarge(path: "spiders/AppGet.js", bytes: 100)))
    // A pack that needs a newer App.
    try server.publish(["AppGet": spider], at: manifestURL, sequence: 3) { $0["requires"] = ["abi": ["js.host": ["major": 1, "minMinor": 9], "catvod.result": ["major": 1, "minMinor": 0]]] }
    let tooNew = await updater.check(scope, source: .remote(config), host: host)
    #expect(tooNew == .rejected(.abiTooNew(surface: "js.host", requiredMinor: 9, installed: 1)))
    // An older sequence.
    try server.publish(["AppGet": spider], at: manifestURL, sequence: 1) { $0["notes"] = "replayed" }
    #expect(await updater.check(scope, source: .remote(config), host: host) == .rejected(.sequenceReused(1)))

    #expect(await store.load(scope, host: host) == working)
}

@Test func aNetworkFailureIsReportedAsSuchAndChangesNothing() async throws {
    let store = RuntimePackStore(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("runtime-updater-\(UUID().uuidString)", isDirectory: true))
    let updater = RuntimePackUpdater(store: store) { _, _ in throw URLError(.notConnectedToInternet) }
    let scope = try #require(RuntimeScope(.remote(config)))
    guard case .failed = await updater.check(scope, source: .remote(config), host: host) else {
        Issue.record("expected a network failure"); return
    }
    let status = RuntimePackUpdater(store: store) { _, _ in throw RuntimePackUpdater.FetchError.status(503) }
    #expect(await status.check(scope, source: .remote(config), host: host) == .failed("HTTP 503"))
    #expect(await store.state(for: scope) == nil)
}

@Test func onlyTheManifestBesideThisConfigurationIsEverRead() async throws {
    let server = Server()
    let elsewhere = URL(string: "https://example.invalid/other/runtime/manifest.json")!
    try server.publish(["AppGet": spider], at: elsewhere)
    let (updater, _) = updater(server)
    #expect(await updater.check(RuntimeScope(.remote(config))!, source: .remote(config), host: host) == .noPack)
    #expect(server.requested == [manifestURL.absoluteString])
}

@Test func aGlobalPackNeedsASignatureByACompiledInKey() async throws {
    let server = Server()
    let key = Curve25519.Signing.PrivateKey()
    try server.publish(["AppGet": spider], at: RuntimePackChannel.globalManifestURL, scope: "global", signer: key)
    let (updater, store) = updater(server)
    // This build ships no key yet: refused.
    #expect(await updater.check(.global, source: .remote(config), host: host)
            == .rejected(.unknownKey(RuntimeTrustRoot.keyId(for: key.publicKey))))
    #expect(await store.state(for: .global) == nil)

    let trust = RuntimeTrustRoot([(key.publicKey, .active)])
    guard case .installed(let pack?) = await updater.check(.global, source: .remote(config), host: host, trust: trust) else {
        Issue.record("not installed"); return
    }
    #expect(pack.scope == .global)
    // Without its signature the same manifest is refused.
    server.files[RuntimePackChannel.globalManifestURL.absoluteString + ".sig"] = nil
    try server.publish(["AppGet": spider], at: RuntimePackChannel.globalManifestURL, scope: "global", sequence: 2)
    #expect(await updater.check(.global, source: .remote(config), host: host, trust: trust) == .rejected(.signatureRequired))
}
