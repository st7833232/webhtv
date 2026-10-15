import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-61 S4 (W-122): the bundled scripts seeded as a generation of the official pack, without the network.

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private let host = RuntimeHost(appVersion: "0.1.77", appBuild: 78)
private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString)", isDirectory: true)
}
private func stateURL(_ root: URL) -> URL {
    root.appendingPathComponent(RuntimeScope.global.storageName, isDirectory: true).appendingPathComponent("state.json")
}

/// Every baseline sequence ever shipped, with its content. A sequence is published once: changing a bundled
/// spider without a new sequence would be refused as `.sequenceReused` on every device that has the old one,
/// and the IPA's fix would never run. Add a line here with a higher sequence whenever the baseline changes.
private let shipped: [UInt64: String] = [
    1: "49b0a7f79c36152a4f361d846a61fd93b810c84da8c283ddebe3f1fe59e034d5",
]

/// Bundled scripts `scripts/runtime_pack.py build` leaves out of the official pack, so out of the baseline too: they
/// stay in the bundled layer, which still serves any class the seeded generation lacks. Mirror that tool's set
/// (Manager #2249: Ikanbot and Djuu wait for the second official pack; add them here when they are bundled).
private let notInBaseline: Set<String> = ["Ikanbot.js"]

/// What a manifest runs — each script's path, hash, needed host API and aliases — without its sequence or version,
/// which `contentIdentity` includes.
private func scripts(of manifest: RuntimePackManifest) -> [String] {
    manifest.files.map { "\($0.path) \($0.sha256) \($0.minHostApi ?? 0) \(($0.aliases ?? []).sorted())" }.sorted()
}

/// A published official pack with other scripts than this build's baseline must be below it.
private func baselineKeepsUpWith(_ official: RuntimePackManifest, baseline: RuntimePackManifest) -> Bool {
    official.sequence < baseline.sequence || scripts(of: official) == scripts(of: baseline)
}

/// The baseline as `scripts/runtime_pack.py` would publish it, at another sequence and optionally one file edited.
private func variant(of baseline: SpiderBaseline, sequence: UInt64,
                     editing path: String? = nil) throws -> (candidate: RuntimePackCandidate, manifest: Data, files: [String: Data]) {
    var object = try #require(JSONSerialization.jsonObject(with: baseline.manifest) as? [String: Any])
    object["sequence"] = sequence
    var files = try baseline.files()
    if let path, let data = files[path] {
        let edited = data + Data("\n".utf8)
        files[path] = edited
        object["files"] = (object["files"] as? [[String: Any]] ?? []).map { file in
            guard file["path"] as? String == path else { return file }
            var file = file
            file["bytes"] = edited.count
            file["sha256"] = sha(edited)
            return file
        }
    }
    let manifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let candidate = try RuntimePackValidator.validateOfficial(manifest: manifest, fetchedFrom: RuntimePackUpdater.manifestURL, host: host)
    return (candidate, manifest, files)
}

@Suite struct SpiderBaselineTests {
    // B4, B7: the baseline is exactly the bundled scripts — every packable file, its bytes and hash — under the
    // official pack's id and scope. Editing a bundled spider without rebuilding the baseline turns this red.
    @Test func theBaselineIsTheBundledScripts() throws {
        let baseline = try #require(try SpiderBaseline(host: host))
        let manifest = baseline.candidate.manifest
        #expect(manifest.packId == "webhtv.spiders")
        #expect(baseline.candidate.scope == .global)
        let folder = try #require(Bundle.module.url(forResource: "Spiders", withExtension: nil))
        let bundled = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".js") && !RuntimeABI.nativeScripts.contains($0) && !notInBaseline.contains($0) }
        #expect(Set(manifest.files.map { ($0.path as NSString).lastPathComponent }) == Set(bundled))
        for file in manifest.files {
            let data = try Data(contentsOf: folder.appendingPathComponent((file.path as NSString).lastPathComponent))
            #expect(file.sha256 == sha(data), "\(file.path) changed: rebuild the baseline with a new sequence")
            #expect(file.bytes == data.count)
        }
    }

    @Test func eachShippedSequenceKeepsItsContent() throws {
        let baseline = try #require(try SpiderBaseline(host: host))
        #expect(shipped[baseline.candidate.manifest.sequence] == baseline.candidate.contentIdentity,
                "a new baseline needs a new, higher sequence (and a line in `shipped`)")
        #expect(baseline.candidate.manifest.sequence == shipped.keys.max())
    }

    // A published official pack must not sit at or above the baseline with other content: a device with the
    // newer IPA would refuse it, or keep it over the IPA's fixes.
    @Test func theBaselineIsAboveAnyPublishedOfficialPack() throws {
        let published = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../spider-pack/official/manifest.json").standardizedFileURL
        guard let data = try? Data(contentsOf: published) else { return }
        let baseline = try #require(try SpiderBaseline(host: host))
        #expect(baselineKeepsUpWith(try RuntimePackManifest.decode(data), baseline: baseline.candidate.manifest))
    }

    // W-122 review F-1: the published pack is built from the same scripts, one sequence up; that is fine. Only other
    // scripts at or above the baseline would let a download hide the IPA's fixes.
    @Test func thePublishedRuleComparesScriptsNotTheWholeManifest() throws {
        let baseline = try #require(try SpiderBaseline(host: host))
        let seq = baseline.candidate.manifest.sequence
        let same = try variant(of: baseline, sequence: seq + 1)
        #expect(baselineKeepsUpWith(same.candidate.manifest, baseline: baseline.candidate.manifest))
        let other = try variant(of: baseline, sequence: seq + 1, editing: "spiders/AppGet.js")
        #expect(!baselineKeepsUpWith(other.candidate.manifest, baseline: baseline.candidate.manifest))
    }

    // B1, B6: an empty scope gets the baseline; what then runs is byte for byte what the bundle ran.
    @Test func anEmptyScopeIsSeededAndRunsTheSameScripts() async throws {
        let store = RuntimePackStore(root: temporaryRoot())
        let seeded = try #require(try await store.seedBaseline(host: host))
        let baseline = try #require(try SpiderBaseline(host: host))
        let state = try #require(await store.state())
        #expect(state.latest == baseline.candidate.generation && state.active == baseline.candidate.generation)
        #expect(state.packId == "webhtv.spiders")
        let loaded = try #require(await store.load(host: host))
        #expect(loaded == seeded)
        let official = SpiderRegistry.bundled(official: loaded, overlaying: nil)
        let bundled = SpiderRegistry.bundled()
        for name in SpiderRegistry.ported {
            #expect(official.entries[name]?.script == bundled.entries[name]?.script)
            // A class left out of the baseline is still served, by the bundled layer (#2254).
            if notInBaseline.contains(name + ".js") { #expect(official.entries[name]?.source == .bundled); continue }
            guard case .official = official.entries[name]?.source else { Issue.record("\(name) is not seeded"); continue }
        }
    }

    // B2: a second launch writes nothing.
    @Test func aSecondLaunchWritesNothing() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        try await store.seedBaseline(host: host)
        let before = try Data(contentsOf: stateURL(root))
        let modified = try FileManager.default.attributesOfItem(atPath: stateURL(root).path)[.modificationDate] as? Date
        #expect(try await store.seedBaseline(host: host) == nil)
        #expect(try Data(contentsOf: stateURL(root)) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: stateURL(root).path)[.modificationDate] as? Date == modified)
    }

    // B1 (3), B9: a generation renamed in before the process died, with no state.json, does not block the seed.
    @Test func anOrphanGenerationDoesNotBlockTheSeed() async throws {
        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        try await store.seedBaseline(host: host)
        try FileManager.default.removeItem(at: stateURL(root))
        #expect(try await store.seedBaseline(host: host) != nil)
        #expect(await store.load(host: host) != nil)
    }

    // B3, B8, Manager #2112 ①②: a newer download stays; once seeded, a newer official pack replaces the seed and
    // keeps it as last known good, the same sequence with other content is refused, and the floor never goes back.
    @Test func theSeedFollowsTheSequenceFloor() async throws {
        let baseline = try #require(try SpiderBaseline(host: host))
        let seq = baseline.candidate.manifest.sequence

        let downloaded = RuntimePackStore(root: temporaryRoot())
        let newer = try variant(of: baseline, sequence: seq + 5, editing: "spiders/AppGet.js")
        try await downloaded.install(newer.candidate, manifest: newer.manifest, files: newer.files, host: host)
        let state = await downloaded.state()
        await #expect(throws: RuntimePackRejection.rollback(sequence: seq, floor: seq + 5)) {
            try await downloaded.seedBaseline(host: host)
        }
        #expect(await downloaded.state() == state)

        let seeded = RuntimePackStore(root: temporaryRoot())
        try await seeded.seedBaseline(host: host)
        let next = try variant(of: baseline, sequence: seq + 1, editing: "spiders/AppGet.js")
        #expect(try await seeded.install(next.candidate, manifest: next.manifest, files: next.files, host: host) != nil)
        #expect(await seeded.state()?.active == next.candidate.generation)
        #expect(await seeded.state()?.lastKnownGood == baseline.candidate.generation)
        await #expect(throws: RuntimePackRejection.rollback(sequence: seq, floor: seq + 1)) { try await seeded.seedBaseline(host: host) }

        let reused = RuntimePackStore(root: temporaryRoot())
        try await reused.seedBaseline(host: host)
        let other = try variant(of: baseline, sequence: seq, editing: "spiders/AppGet.js")
        await #expect(throws: RuntimePackRejection.sequenceReused(seq)) {
            try await reused.install(other.candidate, manifest: other.manifest, files: other.files, host: host)
        }
    }

    // Manager #2112 ①: a new IPA whose baseline is above what was downloaded replaces it, so the IPA's fixes run.
    @Test func aNewerBaselineReplacesAnOlderDownload() async throws {
        let baseline = try #require(try SpiderBaseline(host: host))
        let store = RuntimePackStore(root: temporaryRoot())
        // The baseline is at 1 today, so model "downloaded 1, the next IPA ships baseline 2" with the same install.
        let download = try variant(of: baseline, sequence: 1, editing: "spiders/AppGet.js")
        let ipa = try variant(of: baseline, sequence: 2)
        try await store.install(download.candidate, manifest: download.manifest, files: download.files, host: host)
        try await store.install(ipa.candidate, manifest: ipa.manifest, files: ipa.files, host: host)
        #expect(await store.load(host: host)?.scripts["AppGet"] == String(decoding: try #require(baseline.files()["spiders/AppGet.js"]), as: UTF8.self))
    }
}

extension SpiderBaselineTests {
    // The settings page's 內建基準 test reads the manifest alone; it must name the same content the seed installs.
    @Test func theStatusIdentityIsTheSeededContent() throws {
        #expect(SpiderBaseline.identity == (try SpiderBaseline(host: host))?.candidate.contentIdentity)
    }
}

extension SpiderBaselineTests {
    // W-122 review F-2: once seeded, a launch reads the baseline manifest only — a bundle with no scripts at all
    // still answers "nothing to do". Only a seed that will write reads the 33 scripts.
    @Test func aRepeatLaunchReadsNoScript() async throws {
        let manifestOnly = temporaryRoot()
        try FileManager.default.createDirectory(at: manifestOnly.appendingPathComponent("SpiderBaseline"), withIntermediateDirectories: true)
        let real = try #require(try SpiderBaseline(host: host))
        try real.manifest.write(to: manifestOnly.appendingPathComponent("SpiderBaseline/manifest.json"))
        let bundle = try #require(Bundle(url: manifestOnly))

        let root = temporaryRoot()
        let store = RuntimePackStore(root: root)
        try await store.seedBaseline(host: host)
        let before = try Data(contentsOf: stateURL(root))
        let start = Date()
        #expect(try await store.seedBaseline(bundle: bundle, host: host) == nil)
        print("repeat-launch seed check: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        #expect(try Data(contentsOf: stateURL(root)) == before)

        // The same bundle on an empty scope has to read the scripts, and has none.
        await #expect(throws: RuntimePackRejection.self) {
            try await RuntimePackStore(root: temporaryRoot()).seedBaseline(bundle: bundle, host: host)
        }
    }
}
