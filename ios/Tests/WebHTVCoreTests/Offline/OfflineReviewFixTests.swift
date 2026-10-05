import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-52: the review of IOS-POC-47 found these; each test reproduces one finding (F1–F40 in
/// docs/IOS-POC-52-offline-review-fixes.md) and fails if the fix goes.
struct OfflineReviewFixTests {
    static let base = URL(string: "https://cdn.example.com/show/ep1/")!

    // MARK: F15 — a malformed number in a playlist

    // `Int(Double("inf"))` traps: a broken source must fail its download, not crash the app on
    // every launch.
    @Test func brokenNumbersFailThePlaylistInsteadOfTrapping() throws {
        for bad in ["#EXT-X-TARGETDURATION:inf", "#EXT-X-TARGETDURATION:nan", "#EXT-X-TARGETDURATION:1e20",
                    "#EXT-X-TARGETDURATION:6\n#EXTINF:inf,", "#EXT-X-TARGETDURATION:6\n#EXTINF:1e300,",
                    "#EXT-X-TARGETDURATION:6\n#EXT-X-BYTERANGE:1e30@0\n#EXTINF:6,"] {
            let text = (["#EXTM3U", bad, "#EXTINF:6,", "s0.ts", "#EXT-X-ENDLIST"]).joined(separator: "\n")
            #expect(throws: HLSPlaylist.ParseError.badNumber) { try HLSPlaylist.parse(text, base: Self.base) }
        }
    }

    // Optional attributes that are not usable numbers are left out, and nothing computed from them traps.
    @Test func unusableVariantNumbersAreIgnored() throws {
        let text = Fixture.masterText([
            "#EXT-X-STREAM-INF:BANDWIDTH=1e30,AVERAGE-BANDWIDTH=99999999999999999999999,RESOLUTION=99999999999x99999999999,FRAME-RATE=nan",
            "v.m3u8",
        ])
        guard case .master(let master) = try HLSPlaylist.parse(text, base: Self.base) else { Issue.record("not a master"); return }
        let variant = try #require(master.variants.first)
        #expect(variant.bandwidth == 0 && variant.averageBandwidth == nil)
        #expect(variant.width == nil && variant.height == nil && variant.frameRate == nil)
        #expect(OfflineMediaSelector.chooseVideo(from: master, mode: .smart) != nil)
        #expect(OfflineMediaSelector.estimate(variant, duration: 1e300) == .unknown)
    }

    // The crash loop: the chosen variant's playlist is broken; the download fails as unsupported
    // and is still failed, not preparing again, after a relaunch.
    @Test func aBrokenVariantPlaylistFailsTheDownloadAndStaysFailed() async throws {
        var network = Fixture.simpleNetwork()
        network.responses[Self.base.absoluteString + "1080/index.m3u8"] = .text(
            "#EXTM3U\n#EXT-X-TARGETDURATION:inf\n#EXTINF:6,\nseg0.ts\n#EXT-X-ENDLIST\n")
        let harness = OfflineHarness(network: network)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }

        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.state == .failed && failed.failure?.kind == .unsupported)
        let relaunched = harness.relaunched(network: network)
        await relaunched.manager.start()
        #expect(await relaunched.manager.asset(asset.id)?.state == .failed)
    }

    // MARK: F2 — a full disk refuses the record

    // The record cannot be written (as on a full disk): the download still fails, its transfers
    // are cancelled, and the record reaches the disk once it can.
    @Test func aRecordTheDiskRefusesStillChangesStateAndIsWrittenLater() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        try #require(requests.count == 4)
        let metadata = harness.layout.metadataFile(for: asset.id)
        try FileManager.default.removeItem(at: metadata)
        // A directory where the record goes: every write of it fails.
        let blocker = metadata.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.http(403)))

        #expect(await harness.waitFor(asset.id, .failed)?.state == .failed)
        let deadline = ContinuousClock.now + .seconds(5)
        while await !harness.transport.cancelled.contains(asset.id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await harness.transport.cancelled.contains(asset.id))

        // The disk has room again: the next pump writes the record that could not be written.
        try FileManager.default.removeItem(at: metadata)
        await harness.manager.pump()
        let written = try JSONDecoder.offline.decode(OfflineAsset.self, from: Data(contentsOf: metadata))
        #expect(written.state == .failed)
    }
}
