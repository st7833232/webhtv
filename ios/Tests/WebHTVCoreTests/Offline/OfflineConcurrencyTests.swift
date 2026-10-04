import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-50: 多工下載 — up to three episodes at once, the oldest first, and never more than the
/// free space holds for all of them together.
struct OfflineConcurrencyTests {
    private func queue(_ harness: OfflineHarness, _ episode: String) async -> OfflineAsset? {
        let result = await harness.manager.enqueue(
            identity: Fixture.identity(episode), title: Fixture.title(episode), target: Fixture.target(),
            choice: OfflineDownloadChoice(mode: .smart), estimate: OfflineSizeEstimate(bytes: 1_000_000, basis: .averageBandwidth),
            autoDeleteAfterWatching: false, allowsCellular: false)
        guard case .created(let asset) = result else { return nil }
        return asset
    }

    private func running(_ harness: OfflineHarness) async -> Int {
        await harness.manager.snapshot().assets.filter { $0.state == .preparing || $0.state == .downloading }.count
    }

    @Test func threeDownloadsRunAtOnceAndTheNextWaitsItsTurn() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        await harness.manager.start()
        var assets = [OfflineAsset]()
        for episode in ["ep1", "ep2", "ep3", "ep4", "ep5"] { assets.append(try #require(await queue(harness, episode))) }

        for asset in assets.prefix(3) {
            #expect(await harness.waitFor(asset.id, .downloading)?.state == .downloading)
            #expect(await harness.waitForSubmissions(4, assetID: asset.id).count == 4)
        }
        #expect(await harness.manager.asset(assets[3].id)?.state == .queued)
        #expect(await harness.manager.asset(assets[4].id)?.state == .queued)
        #expect(await running(harness) == OfflineDownloadManager.concurrentDownloads)

        // One finishing frees one place, for the oldest waiting: ep4, not ep5.
        #expect(await harness.completeAll(assets[1].id)?.state == .completed)
        #expect(await harness.waitFor(assets[3].id, .downloading)?.state == .downloading)
        #expect(await harness.manager.asset(assets[4].id)?.state == .queued)
        #expect(await running(harness) == OfflineDownloadManager.concurrentDownloads)
    }

    // Room for one but not two: the second may not count the space the first is about to fill.
    @Test func runningDownloadsKeepTheSpaceTheyStillNeed() async throws {
        // Each needs about 7.5 MB (2.5 Mb/s for 24 s) plus the 500 MB margin: 507.5 MB alone,
        // 515 MB together.
        let harness = OfflineHarness(network: Fixture.simpleNetwork(), capacity: 510_000_000)
        await harness.manager.start()
        let first = try #require(await queue(harness, "ep1"))
        #expect(await harness.waitFor(first.id, .downloading)?.state == .downloading)

        let second = try #require(await queue(harness, "ep2"))
        let failed = try #require(await harness.waitFor(second.id, .failed))
        #expect(failed.failure?.kind == .insufficientStorage)
        #expect(await harness.manager.asset(first.id)?.state == .downloading)
    }
}
