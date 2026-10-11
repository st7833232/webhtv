import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-57: the 下載 tab groups downloads by title, and each group is paused, resumed or deleted
/// at once. What a group holds decides what those actions touch.
struct OfflineTitleGroupTests {
    private func asset(_ key: String, _ name: String, flag: String = "線路①", index: Int,
                       _ state: OfflineAssetState) -> OfflineAsset {
        var asset = OfflineAsset(identity: OfflineIdentity(historyKey: key, flag: flag, episodeURL: "https://source.example.com/\(key)/\(flag)/\(index)"),
                                 title: OfflineTitleInfo(siteKey: "site", siteName: "站", sourceID: nil, vodId: key, vodName: name,
                                                         vodPic: "", episodeName: "第\(index)集", episodeIndex: index),
                                 mode: .smart, autoDeleteAfterWatching: true, allowsCellular: false)
        asset.state = state
        return asset
    }

    // One group per title, every line in it, in episode order; a delete under way is not shown.
    // Titles with work under way first, then the ones waiting on the viewer, then finished ones.
    @Test func downloadsAreGroupedByTitleWithWorkUnderWayFirst() {
        // The names sort the other way round (丙 < 乙 < 甲), so only the state can order them.
        let groups = OfflineTitleGroup.groups([
            asset("a", "丙", index: 2, .completed),
            asset("b", "乙", index: 1, .paused),
            asset("a", "丙", flag: "線路②", index: 1, .completed),
            asset("c", "甲", index: 3, .downloading),
            asset("a", "丙", index: 1, .completed),
            asset("c", "甲", index: 4, .deleting),
            asset("d", "丁", index: 1, .deleting),
        ])

        #expect(groups.map(\.historyKey) == ["c", "b", "a"])
        let a = groups[2]
        #expect(a.title == "丙")
        #expect(a.assets.map { "\($0.identity.flag)\($0.title.episodeIndex)" } == ["線路①1", "線路①2", "線路②1"])
        #expect(groups[0].assets.count == 1)
    }

    // 全部暫停 takes the queued ones before the running ones: pausing a running episode first
    // would let a queued sibling start in its place, only to be paused straight after.
    @Test func pauseAllTakesTheQueuedFirstAndResumeAllThePausedAndFailed() {
        let group = OfflineTitleGroup.groups([
            asset("a", "甲", index: 1, .downloading),
            asset("a", "甲", index: 2, .preparing),
            asset("a", "甲", index: 3, .queued),
            asset("a", "甲", index: 4, .paused),
            asset("a", "甲", index: 5, .failed),
            asset("a", "甲", index: 6, .completed),
        ])[0]

        #expect(group.pausable.map(\.title.episodeIndex) == [3, 1, 2])
        #expect(group.resumable.map(\.title.episodeIndex) == [4, 5])
        #expect(group.completed.map(\.title.episodeIndex) == [6])
    }

    // With three running and a fourth queued, 全部暫停 stops all four and the fourth never starts:
    // no transfer is ever sent for it.
    @Test func pausingATitleNeverStartsOneOfItsQueuedEpisodes() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        var running = [OfflineAsset]()
        for episode in ["ep1", "ep2", "ep3"] {
            running.append(try await harness.startSimpleDownload(identity: Fixture.identity(episode)).0)
        }
        let result = await harness.manager.enqueue(identity: Fixture.identity("ep4"), title: Fixture.title("ep4"),
                                                   target: Fixture.target(), choice: OfflineDownloadChoice(mode: .smart),
                                                   estimate: OfflineSizeEstimate(bytes: 1_000_000, basis: .averageBandwidth),
                                                   autoDeleteAfterWatching: true, allowsCellular: false)
        guard case .created(let fourth) = result else {
            Issue.record("not queued: \(result)")
            return
        }
        #expect(await harness.manager.asset(fourth.id)?.state == .queued)

        let group = try #require(OfflineTitleGroup.groups(await harness.manager.snapshot().assets).first)
        #expect(group.pausable.count == 4)
        for member in group.pausable { await harness.manager.pause(member.id) }

        let states = await harness.manager.snapshot().assets.map(\.state)
        #expect(states.count == 4 && states.allSatisfy { $0 == .paused })
        #expect(await harness.transport.submitted.filter { $0.tag.assetID == fourth.id }.isEmpty)
    }
}
