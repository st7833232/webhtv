import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-13A. Generations on disk, what runs at launch, and how the registry lays packs over the
// bundled scripts. Every test gets its own directory; nothing touches the network.

// MARK: - helpers

private let config = URL(string: "https://example.invalid/repo/raw/main/wang-movie.json")!
private let other = URL(string: "https://example.invalid/other/wang-movie.json")!
private let host = RuntimeHost(appVersion: "0.1.31", appBuild: 32)

private func store() -> RuntimePackStore {
    RuntimePackStore(root: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("runtime-pack-\(UUID().uuidString)", isDirectory: true))
}

/// A spider that answers `homeContent` with a category naming where it came from.
private func spider(marking name: String) -> String {
    """
    var spider = {
      init: function () { return ''; },
      homeContent: function () { return host.result.home([{ type_id: '1', type_name: '\(name)' }], []); }
    };
    module.exports = spider;
    """
}

private struct Pack {
    let manifest: Data
    let files: [String: Data]
    let signature: Data?
    let candidate: RuntimePackCandidate
}

private func pack(_ scripts: [String: String], scope: RuntimeScope = RuntimeScope(.remote(config))!,
                  sequence: Int = 1, aliases: [String: [String]] = [:], minAppBuild: Int? = nil,
                  directive: String? = nil, signer: Curve25519.Signing.PrivateKey? = nil,
                  trust: RuntimeTrustRoot = .bundled) throws -> Pack {
    var files = [String: Data]()
    let entries = scripts.sorted { $0.key < $1.key }.map { name, script -> [String: Any] in
        let body = Data(script.utf8)
        files["spiders/\(name).js"] = body
        return ["path": "spiders/\(name).js", "logicalType": "spider.js", "class": name,
                "aliases": aliases[name] ?? [], "bytes": body.count, "sha256": DrpyEngine.digest(body)]
    }
    var requires: [String: Any] = ["abi": ["js.host": ["major": 1, "minMinor": 1],
                                           "catvod.result": ["major": 1, "minMinor": 0]]]
    if let minAppBuild { requires["minAppBuild"] = minAppBuild }
    var object: [String: Any] = [
        "format": "webhtv.runtime-pack", "schema": 1, "packId": "test.spiders",
        "scope": ["kind": scope.kind.rawValue], "sequence": sequence, "version": "v\(sequence)",
        "requires": requires, "files": directive == nil ? entries : [],
    ]
    if let directive { object["directive"] = directive }
    if scope == .global { object["expires"] = "2030-01-01T00:00:00Z" }
    let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var signature: Data?
    if let signer {
        let sig = try signer.signature(for: manifest).base64EncodedString()
        signature = try JSONEncoder().encode(RuntimePackSignature(keyId: RuntimeTrustRoot.keyId(for: signer.publicKey), sig: sig))
    }
    let candidate = try RuntimePackValidator.revalidate(manifest: manifest, signature: signature, scope: scope,
                                                        host: RuntimeHost(appVersion: "9.9.9", appBuild: 999), trust: trust)
    return Pack(manifest: manifest, files: directive == nil ? files : [:], signature: signature, candidate: candidate)
}

@discardableResult
private func install(_ pack: Pack, in store: RuntimePackStore) async throws -> RuntimeSpiderPack? {
    try await store.install(pack.candidate, manifest: pack.manifest, signature: pack.signature, files: pack.files)
}

private func homeCategory(_ registry: SpiderRegistry, _ api: String) async throws -> String? {
    let runtime = try registry.makeRuntime(for: api, siteKey: "runtime-pack-test-\(UUID().uuidString)")
    try await runtime.initialize(extend: "")
    let home = try JSONSerialization.jsonObject(with: Data(try await runtime.homeContent(filter: false).utf8)) as? [String: Any]
    return ((home?["class"] as? [[String: Any]])?.first)?["type_name"] as? String
}

// MARK: - install and registry

@Test func anInstalledGenerationIsWhatTheRegistryRunsForItsConfiguration() async throws {
    let store = store()
    let scope = try #require(RuntimeScope(.remote(config)))
    let installed = try #require(try await install(pack(["AppGet": spider(marking: "from-pack")]), in: store))
    #expect(installed.scripts.keys.sorted() == ["AppGet"])

    let loaded = try #require(await store.load(scope, host: host))
    #expect(loaded == installed)
    let registry = SpiderRegistry.bundled(overlaying: [loaded])
    #expect(registry.entry(for: "csp_AppGet")?.source == .pack(.configuration, version: "v1"))
    #expect(try await homeCategory(registry, "csp_AppGet") == "from-pack")
    // A class the pack did not bring is still the bundled one.
    #expect(registry.entry(for: "csp_Bili")?.source == .bundled)
    // With no pack at all, the registry is byte for byte the bundled one.
    #expect(SpiderRegistry.bundled(overlaying: []).portedClasses == SpiderRegistry.bundled().portedClasses)
}

@Test func aPackAliasOnlyResolvesToAScriptThatSamePackBrought() async throws {
    let store = store()
    let scope = try #require(RuntimeScope(.remote(config)))
    try await install(pack(["NewSite": spider(marking: "new")], aliases: ["NewSite": ["Shim", "AppGet"]]), in: store)
    let registry = SpiderRegistry.bundled(overlaying: [try #require(await store.load(scope, host: host))])
    #expect(registry.canDrive("csp_NewSite"))
    #expect(try await homeCategory(registry, "csp_Shim") == "new")
    // An alias may repoint a bundled class name, but only to the pack's own script.
    #expect(registry.entry(for: "csp_AppGet")?.source == .pack(.configuration, version: "v1"))
}

@Test func theConfigurationsPackWinsOverTheGlobalOneWhichWinsOverTheBundle() throws {
    let scope = try #require(RuntimeScope(.remote(config)))
    let global = RuntimeSpiderPack(scope: .global, generation: .init(sequence: 1, manifestSHA256: "", contentIdentity: "g"),
                                   version: "g1", notes: nil,
                                   scripts: ["AppGet": spider(marking: "global"), "Bili": spider(marking: "global")], aliases: [:])
    let own = RuntimeSpiderPack(scope: scope, generation: .init(sequence: 1, manifestSHA256: "", contentIdentity: "c"),
                                version: "c1", notes: nil, scripts: ["AppGet": spider(marking: "config")], aliases: [:])
    let registry = SpiderRegistry.bundled(overlaying: [global, own])
    #expect(registry.entry(for: "csp_AppGet")?.source == .pack(.configuration, version: "c1"))
    #expect(registry.entry(for: "csp_Bili")?.source == .pack(.global, version: "g1"))
    #expect(registry.entry(for: "csp_XBPQ")?.source == .bundled)
}

@Test func switchingConfigurationsAToBToAUsesEachOnesOwnPack() throws {
    let packs = ActiveRuntimePacks.shared
    let scopeA = try #require(RuntimeScope(.remote(config)))
    let own = RuntimeSpiderPack(scope: scopeA, generation: .init(sequence: 1, manifestSHA256: "", contentIdentity: "a"),
                                version: "a1", notes: nil, scripts: ["OnlyInA": spider(marking: "a")], aliases: [:])
    packs.set(own, for: scopeA)
    defer { packs.set(nil, for: scopeA) }
    #expect(SpiderRegistry.active(for: .remote(config)).canDrive("csp_OnlyInA"))
    #expect(!SpiderRegistry.active(for: .remote(other)).canDrive("csp_OnlyInA"))
    #expect(!SpiderRegistry.active(for: .importedFile).canDrive("csp_OnlyInA"))
    #expect(CSPSourceResolver(source: .remote(config)).registry.canDrive("csp_OnlyInA"))
    #expect(!CSPSourceResolver(source: .remote(other)).registry.canDrive("csp_OnlyInA"))
}

@Test func aPackScriptThatWillNotLoadFallsBackToTheBundledOne() async throws {
    let scope = try #require(RuntimeScope(.remote(config)))
    let broken = RuntimeSpiderPack(scope: scope, generation: .init(sequence: 1, manifestSHA256: "", contentIdentity: "x"),
                                   version: "x1", notes: nil, scripts: ["AppGet": "this is not javascript ((("], aliases: [:])
    let registry = SpiderRegistry.bundled(overlaying: [broken])
    #expect(registry.entry(for: "csp_AppGet")?.fallback == SpiderRegistry.bundled().entry(for: "csp_AppGet")?.script)
    _ = try registry.makeRuntime(for: "csp_AppGet", siteKey: "fallback-test")
    // A class the bundle never had has nothing to fall back to.
    let added = SpiderRegistry.bundled(overlaying: [RuntimeSpiderPack(
        scope: scope, generation: broken.generation, version: "x1", notes: nil,
        scripts: ["Nowhere": "((("], aliases: [:])])
    #expect(throws: SpiderError.self) { _ = try added.makeRuntime(for: "csp_Nowhere", siteKey: "fallback-test") }
}

// MARK: - failure leaves the working generation alone

@Test func aScriptThatDoesNotLoadIsRefusedBeforeAnythingIsActivated() async throws {
    let store = store()
    let scope = try #require(RuntimeScope(.remote(config)))
    let working = try #require(try await install(pack(["AppGet": spider(marking: "good")]), in: store))
    await #expect(throws: RuntimePackRejection.scriptDoesNotLoad("AppGet")) {
        try await install(pack(["AppGet": "var nothing = 1;"], sequence: 2), in: store)
    }
    #expect(await store.load(scope, host: host) == working)
    #expect(await store.state(for: scope)?.floor == 1)
}

@Test func aFailedInstallLeavesTheWorkingGenerationExactlyWhereItWas() async throws {
    let store = store()
    let scope = try #require(RuntimeScope(.remote(config)))
    let working = try #require(try await install(pack(["AppGet": spider(marking: "good")]), in: store))
    let next = try pack(["AppGet": spider(marking: "next")], sequence: 2)

    await #expect(throws: RuntimePackRejection.fileMissing("spiders/AppGet.js")) {
        try await store.install(next.candidate, manifest: next.manifest, signature: nil, files: [:])
    }
    await #expect(throws: RuntimePackRejection.digestMismatch("spiders/AppGet.js")) {
        try await store.install(next.candidate, manifest: next.manifest, signature: nil,
                                files: ["spiders/AppGet.js": Data(spider(marking: "nexT").utf8)])
    }
    await #expect(throws: RuntimePackRejection.digestMismatch("manifest.json")) {
        try await store.install(next.candidate, manifest: next.manifest + Data(" ".utf8), signature: nil, files: next.files)
    }
    // An older sequence is a rollback, whatever it carries.
    await #expect(throws: RuntimePackRejection.self) {
        try await install(pack(["AppGet": spider(marking: "old")], sequence: 1), in: store)
    }
    #expect(await store.load(scope, host: host) == working)
}

@Test func aGenerationEditedOnDiskIsNotRunAndTheLastKnownGoodIs() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runtime-pack-\(UUID().uuidString)")
    let store = RuntimePackStore(root: root)
    let scope = try #require(RuntimeScope(.remote(config)))
    let first = try #require(try await install(pack(["AppGet": spider(marking: "one")]), in: store))
    let second = try #require(try await install(pack(["AppGet": spider(marking: "two")], sequence: 2), in: store))
    #expect(await store.state(for: scope)?.lastKnownGood == first.generation)

    let file = root.appendingPathComponent(scope.storageName).appendingPathComponent("generations")
        .appendingPathComponent(second.generation.id).appendingPathComponent("files/spiders/AppGet.js")
    try Data(spider(marking: "tampered").utf8).write(to: file)

    #expect(await store.load(scope, host: host) == first)
    let state = try #require(await store.state(for: scope))
    #expect(state.active == first.generation)
    #expect(state.bad.map(\.contentIdentity) == [second.generation.contentIdentity])
    // Never retried, and the floor did not move back.
    #expect(state.admission(of: try pack(["AppGet": spider(marking: "two")], sequence: 2).candidate)
            == .reject(.knownBad(second.generation.id)))
}

@Test func aGenerationThisBuildCannotRunIsSkippedButKept() async throws {
    let store = store()
    let scope = try #require(RuntimeScope(.remote(config)))
    let old = try #require(try await install(pack(["AppGet": spider(marking: "old")]), in: store))
    let newer = try #require(try await install(pack(["AppGet": spider(marking: "newer")], sequence: 2, minAppBuild: 40), in: store))
    // An older IPA reinstalled over the container: the newer generation is not run, not destroyed.
    #expect(await store.load(scope, host: host) == old)
    #expect(await store.state(for: scope)?.active == newer.generation)
    #expect(await store.state(for: scope)?.bad.isEmpty == true)
    // Updating the App again brings it back.
    #expect(await store.load(scope, host: RuntimeHost(appVersion: "0.1.40", appBuild: 40)) == newer)
}

@Test func onlyTheActiveGenerationAndOneLastKnownGoodAreKept() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runtime-pack-\(UUID().uuidString)")
    let store = RuntimePackStore(root: root)
    let scope = try #require(RuntimeScope(.remote(config)))
    for sequence in 1...4 {
        try await install(pack(["AppGet": spider(marking: "v\(sequence)")], sequence: sequence), in: store)
    }
    let generations = root.appendingPathComponent(scope.storageName).appendingPathComponent("generations")
    let kept = try FileManager.default.contentsOfDirectory(atPath: generations.path)
    let state = try #require(await store.state(for: scope))
    #expect(Set(kept) == Set([state.active?.id, state.lastKnownGood?.id].compactMap { $0 }))
    #expect(state.floor == 4)
    #expect((try? generations.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true)

    let staging = root.appendingPathComponent(scope.storageName).appendingPathComponent("staging-leftover")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    await store.removeStaging()
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}

@Test func withdrawingAPackAndForgettingASourceBothGoBackToTheBundle() async throws {
    let store = store()
    let scope = try #require(RuntimeScope(.remote(config)))
    try await install(pack(["AppGet": spider(marking: "one")]), in: store)
    #expect(try await install(pack([:], sequence: 2, directive: "rollbackToBundled"), in: store) == nil)
    #expect(await store.load(scope, host: host) == nil)
    #expect(await store.state(for: scope)?.floor == 2)

    try await install(pack(["AppGet": spider(marking: "three")], sequence: 3), in: store)
    await store.forget(scope)
    #expect(await store.state(for: scope) == nil)
    #expect(await store.load(scope, host: host) == nil)
}

@Test func aGlobalGenerationOnlyRunsOnABuildThatHoldsItsKey() async throws {
    let store = store()
    let active = Curve25519.Signing.PrivateKey()
    let backup = Curve25519.Signing.PrivateKey()
    let trust = RuntimeTrustRoot([(active.publicKey, .active), (backup.publicKey, .backup)])
    let installed = try #require(try await install(
        pack(["AppGet": spider(marking: "global")], scope: .global, signer: active, trust: trust), in: store))
    #expect(await store.load(.global, host: host, trust: trust) == installed)
    // The same generation under a build without that key is skipped, not destroyed.
    #expect(await store.load(.global, host: host, trust: .bundled) == nil)
    #expect(await store.state(for: .global)?.active == installed.generation)
}
