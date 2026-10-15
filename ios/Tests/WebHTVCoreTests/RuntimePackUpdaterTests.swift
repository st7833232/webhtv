import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-61 S2 (W-120): the manual updater against an in-process fake server — nothing here reaches the network.
// Every refusal must leave state.json and the installed generations exactly as they were.

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func script(_ marker: String) -> String {
    "var spider = { marker: '\(marker)', init: function () { return ''; } }; module.exports = spider;"
}

private let manifestURL = URL(string: "https://pack.invalid/official/manifest.json")!
private func blobURL(_ data: Data) -> URL { URL(string: "https://pack.invalid/official/blobs/sha256/\(sha(data))")! }

/// A published pack: the manifest and its content-addressed blobs.
private struct Published {
    var manifest: Data
    var blobs: [URL: Data]
}

private func published(_ sequence: UInt64, _ scripts: [(name: String, body: String, minHostApi: Int?)],
                       jsHostMinor: Int = 2, edit: (inout [String: Any]) -> Void = { _ in }) throws -> Published {
    var blobs = [URL: Data]()
    let files: [[String: Any]] = scripts.map { s in
        let data = Data(s.body.utf8)
        blobs[blobURL(data)] = data
        var file: [String: Any] = ["path": "spiders/\(s.name).js", "logicalType": "spider.js", "class": s.name,
                                   "bytes": data.count, "sha256": sha(data)]
        if let minHostApi = s.minHostApi { file["minHostApi"] = minHostApi }
        return file
    }
    var object: [String: Any] = [
        "format": "webhtv.runtime-pack", "schema": 1, "packId": "webhtv.spiders", "scope": ["kind": "global"],
        "sequence": sequence, "version": "v\(sequence)",
        "requires": ["abi": ["js.host": ["major": 1, "minMinor": jsHostMinor], "catvod.result": ["major": 1, "minMinor": 0]]],
        "files": files,
    ]
    edit(&object)
    return Published(manifest: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), blobs: blobs)
}

/// Serves one published pack; records what was asked and with which cap; can fail one URL.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var pack: Published?
    private var failing: [URL: Error] = [:]
    private var asked: [(URL, Int)] = []

    func publish(_ pack: Published, failing: [URL: Error] = [:]) {
        lock.withLock { self.pack = pack; self.failing = failing; asked = [] }
    }
    var requests: [(url: URL, limit: Int)] { lock.withLock { asked } }

    func fetch(_ url: URL, _ limit: Int) throws -> Data {
        let (pack, failure) = lock.withLock { () -> (Published?, Error?) in
            asked.append((url, limit))
            return (self.pack, failing[url])
        }
        if let failure { throw failure }
        guard let data = url == manifestURL ? pack?.manifest : pack?.blobs[url] else {
            throw RuntimePackUpdater.FetchError.status(404)
        }
        guard data.count <= limit else { throw RuntimePackUpdater.FetchError.tooLarge(data.count) }
        return data
    }
}

private let host = RuntimeHost(appVersion: "0.1.77", appBuild: 78)

private struct Rig {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)", isDirectory: true)
    let server = FakeServer()
    let store: RuntimePackStore
    let updater: RuntimePackUpdater

    init(manifestURL url: URL = manifestURL) {
        store = RuntimePackStore(root: root)
        let server = server
        updater = RuntimePackUpdater(store: store, manifestURL: url, fetch: { try server.fetch($0, $1) })
    }

    var scope: URL { root.appendingPathComponent(RuntimeScope.global.storageName, isDirectory: true) }
    /// state.json's bytes and the directory listing: what "left exactly as it was" compares.
    func disk() -> (state: Data?, entries: Set<String>, generations: Set<String>) {
        let files = FileManager.default
        return (try? Data(contentsOf: scope.appendingPathComponent("state.json")),
                Set((try? files.contentsOfDirectory(atPath: scope.path)) ?? []),
                Set((try? files.contentsOfDirectory(atPath: scope.appendingPathComponent("generations").path)) ?? []))
    }

    func check() async -> RuntimePackUpdater.Outcome { await updater.check(host: host) }
}

@Suite struct RuntimePackUpdaterTests {
    // Already the installed sequence: only the manifest is fetched, nothing changes.
    @Test func theSameSequenceIsUpToDateAndFetchesNoBlob() async throws {
        let rig = Rig()
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]))
        #expect(await rig.check() == .installed(version: "v1", needsNewerApp: []))
        #expect(rig.server.requests.map(\.limit) == [RuntimePackLimits.manifestBytes, script("one").utf8.count])
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]))
        #expect(await rig.check() == .upToDate)
        #expect(rig.server.requests.map(\.url) == [manifestURL])
    }

    // The next sequence becomes active with the previous one kept as last known good, and the registry sees it.
    @Test func theNextSequenceBecomesActiveAndTheRegistrySeesIt() async throws {
        let rig = Rig()
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]))
        _ = await rig.check()
        rig.server.publish(try published(2, [("AppGet", script("two"), nil)]))
        #expect(await rig.check() == .installed(version: "v2", needsNewerApp: []))
        let state = try #require(await rig.store.state())
        #expect(state.active?.sequence == 2 && state.lastKnownGood?.sequence == 1)
        let registry = SpiderRegistry.bundled(official: await rig.store.load(host: host), overlaying: nil)
        #expect(registry.entry(for: "csp_AppGet")?.script == script("two"))
        #expect(registry.entry(for: "csp_AppGet")?.source == .official(version: "v2"))
    }

    // Refusals that leave everything as it was: a bad blob, an older or reused sequence, oversized bodies,
    // an HTTP error, a failure halfway through the blobs, a pack for a newer App.
    @Test func everyRefusalLeavesTheInstalledPackUntouched() async throws {
        let rig = Rig()
        rig.server.publish(try published(5, [("AppGet", script("five"), nil), ("Bili", script("bili"), nil)]))
        _ = await rig.check()
        let before = rig.disk()

        var wrong = try published(6, [("AppGet", script("six"), nil), ("Bili", script("bili6"), nil)])
        wrong.blobs[blobURL(Data(script("six").utf8))] = Data(script("xis").utf8)
        rig.server.publish(wrong)
        #expect(await rig.check() == .rejected(.digestMismatch("spiders/AppGet.js")))

        rig.server.publish(try published(4, [("AppGet", script("four"), nil)]))
        #expect(await rig.check() == .rejected(.rollback(sequence: 4, floor: 5)))
        #expect(rig.server.requests.map(\.url) == [manifestURL])
        rig.server.publish(try published(5, [("AppGet", script("other"), nil)]))
        #expect(await rig.check() == .rejected(.sequenceReused(5)))

        var huge = try published(6, [("AppGet", script("six"), nil)])
        huge.manifest = Data(count: RuntimePackLimits.manifestBytes + 1)
        rig.server.publish(huge)
        #expect(await rig.check() == .rejected(.manifestTooLarge(RuntimePackLimits.manifestBytes + 1)))

        var long = try published(6, [("AppGet", script("six"), nil)])
        long.blobs[blobURL(Data(script("six").utf8))] = Data(script("six").utf8) + Data([0x20])
        rig.server.publish(long)
        #expect(await rig.check() == .rejected(.fileTooLarge(path: "spiders/AppGet.js", bytes: script("six").utf8.count + 1)))

        rig.server.publish(try published(6, [("AppGet", script("six"), nil)]), failing: [manifestURL: RuntimePackUpdater.FetchError.status(503)])
        #expect(await rig.check() == .failed("HTTP 503"))

        let halfway = try published(6, [("AppGet", script("six"), nil), ("Bili", script("bili6"), nil)])
        rig.server.publish(halfway, failing: [blobURL(Data(script("bili6").utf8)): URLError(.networkConnectionLost)])
        guard case .failed = await rig.check() else { Issue.record("a lost connection is a failure, not a refusal"); return }

        rig.server.publish(try published(6, [("AppGet", script("six"), nil)], jsHostMinor: 99))
        let newer = await rig.check()
        #expect(newer == .rejected(.abiTooNew(surface: "js.host", requiredMinor: 99, installed: RuntimeABI.Surface.jsHost.version.minor)))
        if case .rejected(let rejection) = newer { #expect(rejection.requiresNewerApp) }

        let after = rig.disk()
        #expect(after.state == before.state && after.entries == before.entries && after.generations == before.generations)
        #expect(await rig.store.load(host: host)?.scripts["AppGet"] == script("five"))
    }

    // P1–P3: a class this App is too old for keeps the copy that ran before, also after a relaunch; once no
    // installed generation has a copy it can run, it is bundled.
    @Test func aClassThisAppIsTooOldForKeepsTheCopyThatRanBefore() async throws {
        let rig = Rig()
        rig.server.publish(try published(1, [("AppGet", script("a1"), nil), ("Gulu", script("g1"), nil)]))
        _ = await rig.check()
        rig.server.publish(try published(2, [("AppGet", script("a2"), nil), ("Gulu", script("g2"), 99)]))
        #expect(await rig.check() == .installed(version: "v2", needsNewerApp: ["Gulu"]))
        let relaunched = try #require(await RuntimePackStore(root: rig.root).load(host: host))
        #expect(relaunched.scripts["AppGet"] == script("a2") && relaunched.scripts["Gulu"] == script("g1"))
        #expect(await rig.store.state()?.bad.isEmpty == true)

        rig.server.publish(try published(3, [("AppGet", script("a3"), nil), ("Gulu", script("g3"), 99)]))
        _ = await rig.check()
        let later = try #require(await rig.store.load(host: host))
        #expect(later.scripts["AppGet"] == script("a3") && later.scripts["Gulu"] == nil)
        #expect(SpiderRegistry.bundled(official: later, overlaying: nil).entry(for: "csp_Gulu")?.source == .bundled)
    }

    // A pack that does not compile is remembered as bad: the next check refuses it without downloading again.
    @Test func aPackThatDoesNotCompileIsNotFetchedAgain() async throws {
        let rig = Rig()
        rig.server.publish(try published(1, [("AppGet", "module.exports = {", nil)]))
        #expect(await rig.check() == .rejected(.scriptDoesNotLoad("AppGet")))
        rig.server.publish(try published(1, [("AppGet", "module.exports = {", nil)]))
        #expect(await rig.check() == .rejected(.knownBad("gen-1-\(try #require(await rig.store.state()?.bad.first?.contentIdentity.prefix(16)))")))
        #expect(rig.server.requests.map(\.url) == [manifestURL])
        #expect(await rig.store.load(host: host) == nil)
    }

    // Unsigned policy: revoking keys is refused, an expired manifest is refused, an absent `expires` is fine,
    // and the address must be HTTPS.
    @Test func theUnsignedPolicyRefusesRevocationExpiryAndPlainHTTP() async throws {
        let rig = Rig()
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]) { $0["revokeKeyIds"] = ["0123456789abcdef"] })
        #expect(await rig.check() == .rejected(.revocationNotPermitted))
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]) { $0["expires"] = "2001-01-01T00:00:00Z" })
        #expect(await rig.check() == .rejected(.expired))
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]) { $0["expires"] = "2999-01-01T00:00:00Z" })
        #expect(await rig.check() == .installed(version: "v1", needsNewerApp: []))

        let plain = Rig(manifestURL: URL(string: "http://pack.invalid/official/manifest.json")!)
        plain.server.publish(try published(1, [("AppGet", script("one"), nil)]))
        #expect(await plain.check() == .rejected(.insecureOrigin("http://pack.invalid/official/manifest.json")))
        #expect(plain.server.requests.isEmpty)
    }

    // W-121: a server never reached reads "無法連線"; one that dropped the transfer reads "下載沒有完成".
    @Test func aServerNeverReachedIsUnreachableNotAnUnfinishedDownload() async throws {
        let rig = Rig()
        for code in [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut] {
            rig.server.publish(try published(1, [("AppGet", script("one"), nil)]), failing: [manifestURL: URLError(code)])
            guard case .unreachable = await rig.check() else { Issue.record("\(code.rawValue) is not unreachable"); continue }
        }
        rig.server.publish(try published(1, [("AppGet", script("one"), nil)]),
                           failing: [blobURL(Data(script("one").utf8)): URLError(.timedOut)])
        guard case .failed = await rig.check() else { Issue.record("a transfer that stopped is not unreachable"); return }
    }

    // W-121 C5: the settings page, the banner and the all-spider screen can all start a check; two at once share
    // one, so one manifest is fetched and two installs never race for the scope.
    @Test func twoChecksAtOnceAreOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
        let server = FakeServer()
        server.publish(try published(1, [("AppGet", script("one"), nil)]))
        let updater = RuntimePackUpdater(store: RuntimePackStore(root: root), manifestURL: manifestURL, fetch: {
            try await Task.sleep(for: .milliseconds(50))
            return try server.fetch($0, $1)
        })
        async let first = updater.check(host: host)
        async let second = updater.check(host: host)
        let outcomes = await [first, second]
        #expect(outcomes == [.installed(version: "v1", needsNewerApp: []), .installed(version: "v1", needsNewerApp: [])])
        #expect(server.requests.filter { $0.url == manifestURL }.count == 1)
    }

    // W-121 C11: 重設 forgets the pack, floor included, so checking again really installs the same sequence rather
    // than calling it up to date while the bundled scripts run.
    @Test func afterAResetTheSameSequenceInstallsAgain() async throws {
        let rig = Rig()
        rig.server.publish(try published(12, [("AppGet", script("twelve"), nil)]))
        _ = await rig.check()
        try await rig.store.reset()
        #expect(await rig.store.state() == nil)
        #expect(await rig.store.load(host: host) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.scope.path))
        rig.server.publish(try published(12, [("AppGet", script("twelve"), nil)]))
        #expect(await rig.check() == .installed(version: "v12", needsNewerApp: []))
        #expect(await rig.store.load(host: host)?.scripts["AppGet"] == script("twelve"))
    }

    // The compiled-in address is HTTPS, under spider-pack/official/ beside — never over — the compatibility pack.
    @Test func theOfficialAddressIsFixedHTTPSBesideTheCompatibilityPack() {
        #expect(RuntimePackUpdater.manifestURL.scheme == "https")
        #expect(RuntimePackUpdater.manifestURL.path.hasSuffix("/spider-pack/official/manifest.json"))
    }

    /// Opt-in end-to-end: `RUNTIME_PACK_DIR` names a directory `scripts/runtime_pack.py build` wrote. Its pack
    /// goes through the updater, the store and the registry exactly as a published one would.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNTIME_PACK_DIR"] != nil))
    func aPackTheBuildToolWroteInstallsAndRuns() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["RUNTIME_PACK_DIR"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-e2e-\(UUID().uuidString)")
        let store = RuntimePackStore(root: root)
        let updater = RuntimePackUpdater(store: store, manifestURL: manifestURL, fetch: { url, limit in
            let relative = String(url.path.dropFirst("/official/".count))
            let data = try Data(contentsOf: directory.appendingPathComponent(relative))
            guard data.count <= limit else { throw RuntimePackUpdater.FetchError.tooLarge(data.count) }
            return data
        })
        guard case .installed(_, let tooNew) = await updater.check(host: RuntimeHost(appVersion: "0.1.77", appBuild: 78)) else {
            Issue.record("the built pack did not install"); return
        }
        #expect(tooNew.isEmpty)
        let registry = SpiderRegistry.bundled(official: await store.load(host: host), overlaying: nil)
        for name in SpiderRegistry.ported {
            guard case .official = registry.entries[name]?.source else { Issue.record("\(name) is not official"); continue }
            #expect(registry.entries[name]?.script == SpiderRegistry.bundled().entries[name]?.script)
        }
    }
}
