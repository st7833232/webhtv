import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-61 S1 (W-119): the official spider pack's generations on disk, and the registry's three layers —
// a configuration's compatibility pack, then the official pack, then the bundled scripts — class by class.
// Unsigned by the user's 2026-10-15 decision: the store never asks for a signature.

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func script(_ marker: String) -> String {
    "var spider = { marker: '\(marker)', init: function () { return ''; } }; module.exports = spider;"
}

private struct Script {
    let name: String
    var body: String
    var aliases: [String] = []
    var minHostApi: Int?
}

/// A global manifest, its candidate and its files, as the S2 updater will hand them to the store.
private struct Built {
    let manifest: Data
    let candidate: RuntimePackCandidate
    var files: [String: Data]
}

private func built(_ sequence: UInt64, _ scripts: [Script], jsHostMinor: Int = 1,
                   packId: String = "webhtv.spiders") throws -> Built {
    var files = [String: Data]()
    let entries: [[String: Any]] = scripts.map { s in
        let data = Data(s.body.utf8)
        files["spiders/\(s.name).js"] = data
        var entry: [String: Any] = ["path": "spiders/\(s.name).js", "logicalType": "spider.js", "class": s.name,
                                    "bytes": data.count, "sha256": sha(data)]
        if !s.aliases.isEmpty { entry["aliases"] = s.aliases }
        if let minHostApi = s.minHostApi { entry["minHostApi"] = minHostApi }
        return entry
    }
    let object: [String: Any] = [
        "format": "webhtv.runtime-pack", "schema": 1, "packId": packId, "scope": ["kind": "global"],
        "sequence": sequence, "version": "s\(sequence)",
        "requires": ["abi": ["js.host": ["major": 1, "minMinor": jsHostMinor], "catvod.result": ["major": 1, "minMinor": 0]]],
        "files": entries,
    ]
    let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let decoded = try RuntimePackManifest.decode(manifest)
    let candidate = RuntimePackCandidate(manifest: decoded, scope: .global, manifestSHA256: sha(manifest),
                                         contentIdentity: decoded.contentIdentity, signer: nil)
    return Built(manifest: manifest, candidate: candidate, files: files)
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("runtime-pack-\(UUID().uuidString)", isDirectory: true)
}
private func scopeDirectory(_ root: URL) -> URL { root.appendingPathComponent(RuntimeScope.global.storageName, isDirectory: true) }
private func generations(_ root: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: scopeDirectory(root).appendingPathComponent("generations").path)) ?? [])
}
private func file(_ root: URL, _ generation: RuntimeGeneration, _ path: String) -> URL {
    scopeDirectory(root).appendingPathComponent("generations/\(generation.id)/files/\(path)")
}

private let host = RuntimeHost(appVersion: "0.1.76", appBuild: 77)
private func host(jsHost: RuntimeABI.Version) -> RuntimeHost {
    var abi = Dictionary(uniqueKeysWithValues: RuntimeABI.Surface.allCases.map { ($0, $0.version) })
    abi[.jsHost] = jsHost
    return RuntimeHost(appVersion: "0.1.76", appBuild: 77, abi: abi)
}

@Suite struct RuntimePackStoreTests {
    // G1, G4: an installed generation is laid out as planned and is what loads.
    @Test func anInstalledGenerationIsWhatLoads() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"), aliases: ["AppGetAlias"])])
        let installed = try #require(try await store.install(one.candidate, manifest: one.manifest, files: one.files))
        #expect(installed.scripts == ["AppGet": script("one")] && installed.aliases == ["AppGetAlias": "AppGet"])
        let generation = one.candidate.generation
        #expect(FileManager.default.fileExists(atPath: scopeDirectory(root).appendingPathComponent("state.json").path))
        #expect(FileManager.default.fileExists(atPath: file(root, generation, "spiders/AppGet.js").path))
        #expect(await store.load(host: host) == installed)
        #expect(await RuntimePackStore(root: root).state()?.active == generation)
    }

    // G2: state.json is the only switch. A generation directory that no state names never runs.
    @Test func onlyStateJSONSwitchesTheGeneration() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        let stray = scopeDirectory(root).appendingPathComponent("generations/gen-2-ffffffffffffffff/files/spiders")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data(script("two").utf8).write(to: stray.appendingPathComponent("AppGet.js"))
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("one"))
    }

    // G4, G5: an edited active generation is marked bad and the last known good runs; both broken is the bundle.
    @Test func anEditedGenerationFallsBackOneStepAndIsNeverRetried() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        let two = try built(2, [Script(name: "AppGet", body: script("two"))])
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        try await store.install(two.candidate, manifest: two.manifest, files: two.files)
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("two"))

        try Data("tampered".utf8).write(to: file(root, two.candidate.generation, "spiders/AppGet.js"))
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("one"))
        let state = try #require(await store.state())
        #expect(state.active == one.candidate.generation && state.bad.map(\.contentIdentity) == [two.candidate.contentIdentity])
        #expect(state.admission(of: two.candidate) == .reject(.knownBad(two.candidate.generation.id)))

        try Data("tampered".utf8).write(to: file(root, one.candidate.generation, "spiders/AppGet.js"))
        #expect(await store.load(host: host) == nil)
    }

    // Review F-1: generations/ is excluded from backups and state.json is not, so after a restore the generations
    // are simply gone. That marks nothing bad, and installing the same pack again brings it back.
    @Test func aRestoreWithoutGenerationsMarksNothingBadAndTheSamePackReinstalls() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        let two = try built(2, [Script(name: "AppGet", body: script("two"))])
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        try await store.install(two.candidate, manifest: two.manifest, files: two.files)
        try FileManager.default.removeItem(at: scopeDirectory(root).appendingPathComponent("generations"))
        #expect(await store.load(host: host) == nil)
        #expect(await store.state()?.bad.isEmpty == true)
        let back = try await store.install(two.candidate, manifest: two.manifest, files: two.files)
        #expect(back?.scripts["AppGet"] == script("two"))
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("two"))
    }

    // W-120 review N-3 (fixed in W-121): a generation directory without its manifest is not "already installed";
    // installing the same pack writes it again instead of leaving a generation `load` always skips.
    @Test func aGenerationDirectoryWithoutItsManifestIsWrittenAgain() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        try FileManager.default.removeItem(at: scopeDirectory(root).appendingPathComponent("generations/\(one.candidate.generation.id)/manifest.json"))
        #expect(await store.load(host: host) == nil)
        #expect(try await store.install(one.candidate, manifest: one.manifest, files: one.files) != nil)
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("one"))
    }

    // R5, G5: a generation this build cannot run is skipped, never marked bad, never deleted.
    @Test func aGenerationThisBuildCannotRunIsKeptForALaterBuild() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))], jsHostMinor: 5)
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        let before = await store.state()
        for older in [host(jsHost: RuntimeABI.Version(1, 4)), host(jsHost: RuntimeABI.Version(2, 0))] {
            #expect(await store.load(host: older) == nil)
        }
        #expect(await store.state() == before && before?.bad.isEmpty == true)
        #expect(generations(root) == [one.candidate.generation.id])
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("one"))
    }

    // G6: only the active generation and one last known good stay on disk.
    @Test func onlyTheActiveAndOneLastKnownGoodAreKept() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        var ids = [String]()
        for sequence in 1...3 as ClosedRange<UInt64> {
            let pack = try built(sequence, [Script(name: "AppGet", body: script("\(sequence)"))])
            try await store.install(pack.candidate, manifest: pack.manifest, files: pack.files)
            ids.append(pack.candidate.generation.id)
        }
        #expect(generations(root) == Set(ids.suffix(2)))
        let state = try #require(await store.state())
        #expect(state.active?.id == ids[2] && state.lastKnownGood?.id == ids[1])
    }

    // G7: the sequence floor holds; the same pack again is a no-op.
    @Test func anOlderOrReusedSequenceIsRefusedAndTheSamePackIsANoOp() async throws {
        let store = RuntimePackStore(root: temporaryRoot())
        let two = try built(2, [Script(name: "AppGet", body: script("two"))])
        try await store.install(two.candidate, manifest: two.manifest, files: two.files)
        let state = await store.state()
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        await #expect(throws: RuntimePackRejection.rollback(sequence: 1, floor: 2)) {
            try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        }
        let reused = try built(2, [Script(name: "AppGet", body: script("other"))])
        await #expect(throws: RuntimePackRejection.sequenceReused(2)) {
            try await store.install(reused.candidate, manifest: reused.manifest, files: reused.files)
        }
        #expect(try await store.install(two.candidate, manifest: two.manifest, files: two.files) == nil)
        #expect(await store.state() == state)
    }

    // A pack that does not verify or does not compile never reaches state.json.
    @Test func aPackThatDoesNotVerifyOrCompileIsNeverActivated() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        var wrong = try built(1, [Script(name: "AppGet", body: script("one"))])
        wrong.files["spiders/AppGet.js"] = Data(script("eno").utf8)
        await #expect(throws: RuntimePackRejection.digestMismatch("spiders/AppGet.js")) {
            try await store.install(wrong.candidate, manifest: wrong.manifest, files: wrong.files)
        }
        let broken = try built(1, [Script(name: "AppGet", body: "module.exports = {")])
        await #expect(throws: RuntimePackRejection.scriptDoesNotLoad("AppGet")) {
            try await store.install(broken.candidate, manifest: broken.manifest, files: broken.files)
        }
        // S2 (review N-2): the pack that does not compile is remembered as bad; nothing became active.
        #expect(await store.state()?.active == nil && generations(root).isEmpty)
        #expect(await store.state()?.bad.map(\.contentIdentity) == [broken.candidate.contentIdentity])
    }

    // G8: an unreadable state is the bundled scripts, not a crash, and deletes nothing.
    @Test func anUnreadableStateIsTheBundledScripts() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        try Data("not json".utf8).write(to: scopeDirectory(root).appendingPathComponent("state.json"))
        #expect(await store.load(host: host) == nil)
        #expect(generations(root) == [one.candidate.generation.id])
    }

    // S1 cleanup: only a download's leftover staging goes.
    @Test func removingStagingLeavesGenerationsAndState() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        let one = try built(1, [Script(name: "AppGet", body: script("one"))])
        try await store.install(one.candidate, manifest: one.manifest, files: one.files)
        let staging = scopeDirectory(root).appendingPathComponent("staging-left-over/files")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        await store.removeStaging()
        let left = try FileManager.default.contentsOfDirectory(atPath: scopeDirectory(root).path)
        #expect(Set(left) == ["generations", "state.json"])
        #expect(await store.load(host: host)?.scripts["AppGet"] == script("one"))
    }

    // R3 (store side): a script needing a newer js.host than this build is left out, with its aliases; the rest runs.
    @Test func aScriptNeedingANewerHostIsLeftOutAlone() async throws {
        let store = RuntimePackStore(root: temporaryRoot())
        let pack = try built(1, [Script(name: "AppGet", body: script("one")),
                                 Script(name: "Gulu", body: script("gulu"), aliases: ["GuluAlias"], minHostApi: 99)])
        try await store.install(pack.candidate, manifest: pack.manifest, files: pack.files)
        let loaded = try #require(await store.load(host: host))
        #expect(loaded.scripts == ["AppGet": script("one")] && loaded.aliases.isEmpty)
    }

    @Test func aFileMinHostApiMustBePositive() throws {
        #expect(throws: RuntimePackRejection.malformed("minHostApi")) {
            try built(1, [Script(name: "AppGet", body: script("one"), minHostApi: 0)])
        }
    }
}

// MARK: - The registry's three layers

private func official(_ scripts: [String: String], aliases: [String: String] = [:]) throws -> OfficialSpiderPack {
    let generation = RuntimeGeneration(sequence: 1, manifestSHA256: String(repeating: "a", count: 64),
                                       contentIdentity: String(repeating: "b", count: 64))
    return OfficialSpiderPack(generation: generation, version: "s1", scripts: scripts, aliases: aliases)
}

@Suite struct SpiderRegistryLayerTests {
    // U1: no official pack and no compatibility pack is exactly today's bundled registry.
    @Test func withoutPacksEveryClassIsTheBundledOne() {
        let layered = SpiderRegistry.bundled(official: nil, overlaying: nil)
        let bundled = SpiderRegistry.bundled()
        #expect(layered.entries.keys.sorted() == bundled.entries.keys.sorted())
        for name in SpiderRegistry.ported {
            #expect(layered.entries[name]?.script == bundled.entries[name]?.script)
            #expect(layered.entries[name]?.source == .bundled)
        }
    }

    // R1, R2: the compatibility pack beats the official one, the official one beats the bundle, and a class
    // neither pack brings stays bundled.
    @Test func eachClassComesFromTheHighestLayerThatHasIt() throws {
        let registry = SpiderRegistry.bundled(
            official: try official(["AppGet": script("official"), "Bili": script("official")]),
            overlaying: SpiderPack(version: "c1", scripts: ["AppGet": script("compat")]))
        #expect(registry.entry(for: "csp_AppGet")?.script == script("compat"))
        #expect(registry.entry(for: "csp_AppGet")?.source == .pack(version: "c1"))
        #expect(registry.entry(for: "csp_Bili")?.script == script("official"))
        #expect(registry.entry(for: "csp_Bili")?.source == .official(version: "s1"))
        #expect(registry.entry(for: "csp_XBPQ")?.source == .bundled)
    }

    // A2: an official alias follows the official target; without one the Swift alias keeps the bundled copy.
    @Test func anOfficialAliasOnlyRepointsToAnOfficialScript() throws {
        let declared = SpiderRegistry.bundled(official: try official(["Sports88": script("s88")], aliases: ["Kanqiu": "Sports88"]),
                                              overlaying: nil)
        #expect(declared.entry(for: "csp_Kanqiu")?.script == script("s88"))
        #expect(declared.entry(for: "csp_Kanqiu")?.source == .official(version: "s1"))
        let undeclared = SpiderRegistry.bundled(official: try official(["Sports88": script("s88")]), overlaying: nil)
        #expect(undeclared.entry(for: "csp_Kanqiu")?.source == .bundled)
        #expect(undeclared.entry(for: "csp_Kanqiu")?.script == SpiderRegistry.bundled().entry(for: "csp_Sports88")?.script)
        // A stale official alias whose target the official pack did not bring repoints nothing.
        let stale = SpiderRegistry.bundled(official: try official(["Bili": script("b")], aliases: ["Kanqiu": "AppGet"]),
                                           overlaying: nil)
        #expect(stale.entry(for: "csp_Kanqiu")?.script == SpiderRegistry.bundled().entry(for: "csp_Sports88")?.script)
    }

    // A3: each layer's aliases point only into that layer. The compatibility pack brings JianPian without the
    // alias, the official pack brings both: Jianpian stays on the official script.
    @Test func eachLayerOnlyRepointsItsOwnAliases() throws {
        let registry = SpiderRegistry.bundled(
            official: try official(["JianPian": script("official")], aliases: ["Jianpian": "JianPian"]),
            overlaying: SpiderPack(version: "c1", scripts: ["JianPian": script("compat")]))
        #expect(registry.entry(for: "csp_JianPian")?.script == script("compat"))
        #expect(registry.entry(for: "csp_Jianpian")?.script == script("official"))
        #expect(registry.entry(for: "csp_JPianAmns")?.source == .bundled)
    }

    // R6: mappings come from the compatibility pack alone, with or without an official pack.
    @Test func mappingsStillComeFromTheCompatibilityPack() throws {
        let mapping = SpiderPack.ClassMapping(config: "c", site: "s", className: "X", jar: "j",
                                              jarSha256: String(repeating: "0", count: 64), adapter: "AppGet",
                                              adapterSha256: String(repeating: "1", count: 64))
        let registry = SpiderRegistry.bundled(official: try official(["Bili": script("o")]),
                                              overlaying: SpiderPack(version: "c1", scripts: [:], mappings: [mapping]))
        #expect(registry.mappings == [mapping])
        #expect(SpiderRegistry.bundled(official: try official(["Bili": script("o")]), overlaying: nil).mappings.isEmpty)
    }
}
