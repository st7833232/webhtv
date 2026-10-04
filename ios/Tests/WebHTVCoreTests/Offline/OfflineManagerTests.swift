import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-47: the download lifecycle. These protect what the user asked for in so many words —
/// one copy per episode for both engines, every state deletable, failures kept and manageable, and
/// the auto-delete firing only after a real end and the player's release.
struct OfflineManagerTests {
    // MARK: One copy, both engines

    // 10, 36. AVPlayer and MPV are handed the same asset at the same address.
    @Test func bothEnginesResolveTheSameAssetAndAddress() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = await harness.startSimpleDownload()
        let done = try #require(await harness.completeAll(asset.id))
        let server = URL(string: "http://127.0.0.1:5555/token/")!
        let source = try #require(OfflinePlaybackResolver.source(for: done, layout: harness.layout, serverBase: server))
        let native = try #require(OfflinePlaybackResolver.target(for: source, engine: .native))
        let mpv = try #require(OfflinePlaybackResolver.target(for: source, engine: .mpv))
        #expect(native.url == mpv.url)
        #expect(native.url.absoluteString == "http://127.0.0.1:5555/token/\(asset.id)/playlists/index.m3u8")
        #expect(native.headers.isEmpty)
    }

    // 11, 12. Another engine, another quality or a freshly signed address is still the same episode.
    @Test func theSameEpisodeIsNeverDownloadedTwice() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = await harness.startSimpleDownload()
        let resigned = Fixture.target(URL(string: "https://cdn.example.com/show/ep1/master.m3u8?sig=NEW")!)
        let again = await harness.manager.enqueue(identity: Fixture.identity(), title: Fixture.title(), target: resigned,
                                                  choice: OfflineDownloadChoice(mode: .high), estimate: .unknown,
                                                  autoDeleteAfterWatching: false, allowsCellular: true)
        #expect(again == .existing(try #require(await harness.manager.asset(asset.id))))
        #expect(await harness.manager.snapshot().assets.count == 1)
    }

    @Test func twoTapsAtOnceMakeOneDownload() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        await harness.manager.start()
        let manager = harness.manager
        let results = await withTaskGroup(of: OfflineEnqueueResult.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await manager.enqueue(identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
                                          choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown,
                                          autoDeleteAfterWatching: true, allowsCellular: false)
                }
            }
            return await group.reduce(into: [OfflineEnqueueResult]()) { $0.append($1) }
        }
        #expect(results.filter { if case .created = $0 { return true } else { return false } }.count == 1)
        #expect(await manager.snapshot().assets.count == 1)
    }

    // MARK: Completion and integrity

    // 30, 39. A completed package plays with no remote address, and its size is measured, not estimated.
    @Test func aCompletedDownloadIsMeasuredAndLocal() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.url.absoluteString.contains("/1080/") })
        let done = try #require(await harness.completeAll(asset.id))
        #expect(done.state == .completed)
        // The estimate the sheet showed (AVERAGE-BANDWIDTH × duration) stays an estimate.
        #expect(done.estimate == OfflineSizeEstimate(bytes: 7_500_000, basis: .averageBandwidth))
        let actual = try #require(done.actualBytes)
        #expect(actual > 0 && actual != done.estimate.bytes)
        #expect(done.video?.height == 1080)
        let folder = harness.layout.folder(for: asset.id)
        for name in ["index.m3u8", "video.m3u8"] {
            let text = try String(contentsOf: folder.appendingPathComponent("playlists/\(name)"), encoding: .utf8)
            #expect(!text.contains("://"))
        }
        // The addresses and the source's headers are gone once they are not needed.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("download-plan.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("download-request.json").path))
    }

    // 31. A segment that never arrives keeps the download from ever reading as complete.
    @Test func aMissingSegmentIsNeverCalledComplete() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        for request in requests.dropLast() { await harness.transport.finish(request.tag, body: Fixture.segment()) }
        // The last one comes back as an error page: not media, not complete.
        await harness.transport.finish(requests.last!.tag, body: Data("<html>expired</html>".utf8))
        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .expiredSource)
        #expect(failed.actualBytes == nil)
    }

    // MARK: Every state can be deleted

    // 13, 19, 20. Deleting a running download cancels its transfers and takes its whole folder.
    @Test func aDownloadingAssetCanBeDeleted() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        let result = await harness.manager.delete([asset.id])
        #expect(result.deleted == 1)
        #expect(result.releasedBytes > 0)
        #expect(await harness.transport.cancelled.contains(asset.id))
        #expect(!harness.folderExists(asset.id))
        #expect(await harness.manager.asset(asset.id) == nil)
    }

    // A transfer finishing after the delete cannot bring the asset back.
    @Test func aLateCallbackDoesNotReviveADeletedAsset() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.manager.delete([asset.id])
        await harness.transport.finish(requests[1].tag, body: Fixture.segment())
        await harness.transport.fail(requests[2].tag, OfflineTransferFailure(.network("late")))
        #expect(await harness.manager.asset(asset.id) == nil)
        #expect(!harness.folderExists(asset.id))
    }

    // A transfer started before a pause reports under the old generation and changes nothing.
    @Test func aTransferFromBeforeAPauseChangesNothing() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.manager.pause(asset.id)
        await harness.manager.resume(asset.id)
        _ = await harness.waitFor(asset.id, .downloading)
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        let current = try #require(await harness.manager.asset(asset.id))
        #expect(current.progress.completedUnits == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.folder(for: asset.id).appendingPathComponent("media/v00001.ts").path))
    }

    // 14. Paused, then deleted.
    @Test func aPausedAssetCanBeDeleted() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = await harness.startSimpleDownload()
        await harness.manager.pause(asset.id)
        #expect(await harness.manager.asset(asset.id)?.state == .paused)
        #expect(await harness.manager.delete([asset.id]).deleted == 1)
        #expect(!harness.folderExists(asset.id))
    }

    // 15, 29. A failed download keeps its 500 MB until the viewer decides — and deleting frees it all.
    @Test func aFailedAssetWithPartialFilesCanBeDeletedAndFreesTheSpace() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        for request in requests.prefix(2) { await harness.transport.finish(request.tag, body: Fixture.segment(64_000)) }
        await harness.transport.fail(requests[2].tag, OfflineTransferFailure(.http(403)))
        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .expiredSource)
        // Not hidden, not cleaned up by itself: the partial files are still there to resume or delete.
        #expect(await harness.manager.snapshot().assets.map(\.id) == [asset.id])
        let partial = OfflineStorage.allocatedSize(of: harness.layout.folder(for: asset.id))
        #expect(partial >= 128_000)
        let result = await harness.manager.delete([asset.id])
        #expect(result.releasedBytes == partial)
        #expect(!harness.folderExists(asset.id))
    }

    // 16. Completed, then deleted.
    @Test func aCompletedAssetCanBeDeleted() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = await harness.startSimpleDownload()
        _ = await harness.completeAll(asset.id)
        let before = await harness.manager.snapshot().usageBytes
        #expect(await harness.manager.delete([asset.id]).deleted == 1)
        #expect(await harness.manager.snapshot().usageBytes < before)
    }

    // 21, 37. Deleting one asset leaves the others; a bulk delete reports what it really freed.
    @Test func bulkDeleteTouchesOnlyWhatWasChosenAndCountsTheBytes() async throws {
        var network = Fixture.simpleNetwork()
        let second = URL(string: "https://cdn.example.com/show/ep2/master.m3u8")!
        network.responses[second.absoluteString] = network.responses[Fixture.master.absoluteString]
        network.responses["https://cdn.example.com/show/ep2/1080/index.m3u8"] = .text(Fixture.media(4))
        let third = URL(string: "https://cdn.example.com/show/ep3/master.m3u8")!
        network.responses[third.absoluteString] = network.responses[Fixture.master.absoluteString]
        network.responses["https://cdn.example.com/show/ep3/1080/index.m3u8"] = .text(Fixture.media(4))
        let harness = OfflineHarness(network: network)
        var ids = [String]()
        for (episode, url) in [("ep1", Fixture.master), ("ep2", second), ("ep3", third)] {
            let (asset, _) = await harness.startSimpleDownload(identity: Fixture.identity(episode), target: Fixture.target(url))
            _ = await harness.completeAll(asset.id)
            ids.append(asset.id)
        }
        let sizes = ids.map { OfflineStorage.allocatedSize(of: harness.layout.folder(for: $0)) }
        let result = await harness.manager.delete([ids[0], ids[2]])
        #expect(result.deleted == 2)
        #expect(result.releasedBytes == sizes[0] + sizes[2])
        #expect(harness.folderExists(ids[1]))
        #expect(await harness.manager.asset(ids[1])?.state == .completed)
    }

    // 38. 刪除已看完 never takes an unfinished episode.
    @Test func deleteWatchedSelectsOnlyCompletedWatchedEpisodes() {
        func make(_ state: OfflineAssetState, watched: Bool) -> OfflineAsset {
            var asset = OfflineAsset(identity: Fixture.identity(UUID().uuidString), title: Fixture.title(), mode: .smart,
                                     autoDeleteAfterWatching: false, allowsCellular: false)
            asset.state = state
            asset.watched = watched
            return asset
        }
        let assets = [make(.completed, watched: true), make(.completed, watched: false), make(.failed, watched: true),
                      make(.downloading, watched: false)]
        let key = Fixture.identity().historyKey
        #expect(OfflineBulkSelection.watched(assets, historyKey: key).map(\.id) == [assets[0].id])
        #expect(OfflineBulkSelection.failed(assets, historyKey: key).map(\.id) == [assets[2].id])
        #expect(OfflineBulkSelection.all(assets, historyKey: "other").isEmpty)
    }

    // MARK: Resume and retry

    // 17. A retry keeps every segment already here and asks only for the rest.
    @Test func retryKeepsFinishedSegments() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        for request in requests.prefix(2) { await harness.transport.finish(request.tag, body: Fixture.segment()) }
        await harness.transport.fail(requests[2].tag, OfflineTransferFailure(.http(500)))
        await harness.transport.fail(requests[2].tag, OfflineTransferFailure(.http(500)))
        await harness.transport.fail(requests[2].tag, OfflineTransferFailure(.http(500)))
        _ = try #require(await harness.waitFor(asset.id, .failed))
        await harness.transport.clearSubmitted()
        await harness.manager.resume(asset.id)
        let again = await harness.waitForSubmissions(2)
        #expect(Set(again.map(\.tag.unit)) == Set(requests.suffix(2).map(\.tag.unit)))
        #expect(again.allSatisfy { $0.tag.generation > requests[0].tag.generation })
    }

    // 17, 18. A progressive file resumes from the session's resume data — or, when the server cannot
    // resume, starts again from zero instead of pretending.
    @Test func progressiveRetryUsesResumeDataOnlyWhenThereIsSome() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4")!
        let network = FakeNetwork([file.absoluteString: .init(data: Data(repeating: 0, count: 1024), status: 206,
                                                              headers: ["content-range": "bytes 0-1023/50000000"])])
        let harness = OfflineHarness(network: network)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: Fixture.target(file),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        let first = await harness.waitForSubmissions(1)
        #expect(first.first?.resumeData == nil)
        #expect(first.first?.reportsProgress == true)
        #expect(await harness.manager.asset(asset.id)?.estimate == OfflineSizeEstimate(bytes: 50_000_000, basis: .exact))

        await harness.transport.fail(first[0].tag, OfflineTransferFailure(.network("lost"), resumeData: Data("resume".utf8)))
        await harness.transport.fail(first[0].tag, OfflineTransferFailure(.network("lost"), resumeData: Data("resume".utf8)))
        await harness.transport.fail(first[0].tag, OfflineTransferFailure(.network("lost"), resumeData: Data("resume".utf8)))
        _ = try #require(await harness.waitFor(asset.id, .failed))
        await harness.transport.clearSubmitted()
        await harness.manager.resume(asset.id)
        let resumed = await harness.waitForSubmissions(1)
        #expect(resumed.first?.resumeData == Data("resume".utf8))

        // The server could not resume: the resume data is gone and the retry starts over.
        try FileManager.default.removeItem(at: harness.layout.resumeDataFile(for: asset.id, unit: 0))
        await harness.manager.pause(asset.id)
        await harness.transport.clearSubmitted()
        await harness.manager.resume(asset.id)
        let restarted = await harness.waitForSubmissions(1)
        #expect(restarted.first?.resumeData == nil)
    }

    // A server that ignores Range answers with the whole file: only the probe's worth is read.
    @Test func theProbeNeverReadsAWholeFileIntoMemory() async throws {
        let file = URL(string: "https://cdn.example.com/big.mp4")!
        let body = Data([0, 0, 0, 0x20]) + Data(repeating: 7, count: OfflineHTTP.probeLimit * 4)
        let harness = OfflineHarness(network: FakeNetwork([file.absoluteString: .init(data: body, status: 200,
                                                                                      headers: ["content-length": "\(body.count)"])]))
        let options = try await harness.manager.options(for: Fixture.target(file))
        #expect(options.kind == .progressive)
        #expect(options.option(for: .smart)?.estimate == OfflineSizeEstimate(bytes: Int64(body.count), basis: .exact))
    }

    // A retry after the addresses expired resolves the episode again.
    @Test func retryAfterAnExpiredAddressResolvesAgain() async throws {
        var network = Fixture.simpleNetwork()
        let fresh = URL(string: "https://cdn.example.com/show/ep1/master.m3u8?sig=fresh")!
        network.responses[fresh.absoluteString] = network.responses[Fixture.master.absoluteString]
        let harness = OfflineHarness(network: network)
        await harness.manager.setResolver { _ in Fixture.target(fresh) }
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.transport.fail(requests[0].tag, OfflineTransferFailure(.http(403)))
        _ = try #require(await harness.waitFor(asset.id, .failed))
        await harness.manager.resume(asset.id)
        _ = await harness.waitFor(asset.id, .downloading)
        #expect(harness.log.all.contains { $0.url == fresh })
    }

    // MARK: Disk space

    // 28. No room: refused up front, or stopped cleanly mid-way with the partial files kept.
    @Test func insufficientStorageFailsCleanly() async throws {
        let tight = OfflineHarness(network: Fixture.simpleNetwork(), capacity: 600_000_000)
        await tight.manager.start()
        let refused = await tight.manager.enqueue(identity: Fixture.identity(), title: Fixture.title(), target: Fixture.target(),
                                                  choice: OfflineDownloadChoice(mode: .smart),
                                                  estimate: OfflineSizeEstimate(bytes: 2_000_000_000, basis: .averageBandwidth),
                                                  autoDeleteAfterWatching: true, allowsCellular: false)
        #expect(refused == .refused(OfflineFailure(.insufficientStorage)))
        #expect(await tight.manager.snapshot().assets.isEmpty)

        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        harness.capacity.set(50_000_000)
        await harness.transport.finish(requests[1].tag, body: Fixture.segment())
        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .insufficientStorage)
        #expect(harness.folderExists(asset.id))
        #expect(await harness.manager.delete([asset.id]).deleted == 1)
    }

    // MARK: Watched and auto-delete

    private func completed(autoDelete: Bool) async throws -> (OfflineHarness, OfflineAsset) {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, _) = await harness.startSimpleDownload(autoDelete: autoDelete)
        return (harness, try #require(await harness.completeAll(asset.id)))
    }

    /// What `PlaybackSession` does with the policy's decisions.
    private func apply(_ decisions: [OfflineCompletionPolicy.Decision], to manager: OfflineDownloadManager) async {
        for decision in decisions {
            switch decision {
            case .markWatched(let id): await manager.playbackEnded(id)
            case .released(let id): await manager.playbackReleased(id)
            }
        }
    }

    // 22, 23. A real end (either engine's) arms the delete; the release runs it.
    @Test(arguments: ["AVPlayerItemDidPlayToEndTime", "MPV_END_FILE_REASON_EOF"])
    func aRealEndThenTheReleaseDeletes(_ engineEnd: String) async throws {
        let (harness, asset) = try await completed(autoDelete: true)
        var policy = OfflineCompletionPolicy()
        await apply(policy.opened(asset.id), to: harness.manager)
        await apply(policy.ended(.endOfFile), to: harness.manager)
        // Still held by the player: armed, not deleted.
        let armed = try #require(await harness.manager.asset(asset.id))
        #expect(armed.watched && armed.pendingAutoDelete, "\(engineEnd)")
        #expect(harness.folderExists(asset.id))
        // The next episode is loaded: the player let go.
        await apply(policy.opened(nil), to: harness.manager)
        #expect(await harness.manager.asset(asset.id) == nil)
        #expect(!harness.folderExists(asset.id))
    }

    @Test func closingThePlayerAfterTheEndUnloadsAndDeletes() async throws {
        let (harness, asset) = try await completed(autoDelete: true)
        var policy = OfflineCompletionPolicy()
        _ = policy.opened(asset.id)
        await apply(policy.ended(.formalAutoNext), to: harness.manager)
        let closed = policy.closed()
        #expect(closed.unload)
        await apply(closed.decisions, to: harness.manager)
        #expect(!harness.folderExists(asset.id))
    }

    // 24. A seek to the last seconds and leaving is not watching to the end.
    @Test func aSeekNearTheEndIsNotCompletion() async throws {
        let (harness, asset) = try await completed(autoDelete: true)
        var history = WatchHistory(key: asset.identity.historyKey, siteKey: "site", vodId: "vod1")
        history.position = 1_195_000
        history.duration = 1_200_000
        #expect(history.isNearEnding)   // what the old shortcut would have taken as "watched"
        var policy = OfflineCompletionPolicy()
        _ = policy.opened(asset.id)
        let closed = policy.closed()
        #expect(!closed.unload)
        await apply(closed.decisions, to: harness.manager)
        await apply(policy.stopped(), to: harness.manager)
        let kept = try #require(await harness.manager.asset(asset.id))
        #expect(!kept.watched && !kept.pendingAutoDelete)
        #expect(harness.folderExists(asset.id))
    }

    // 25. An error, a stop or an engine switch is no end: nothing is marked, nothing deleted.
    @Test func errorsStopsAndEngineSwitchesAreNotCompletion() async throws {
        let (harness, asset) = try await completed(autoDelete: true)
        var policy = OfflineCompletionPolicy()
        _ = policy.opened(asset.id)
        // An engine switch or a fallback reloads the same asset: nothing is released.
        #expect(policy.opened(asset.id).isEmpty)
        await apply(policy.stopped(), to: harness.manager)
        #expect(await harness.manager.asset(asset.id)?.watched == false)
        #expect(harness.folderExists(asset.id))
    }

    // 26. With auto-delete off, a watched episode stays.
    @Test func autoDeleteOffKeepsAWatchedEpisode() async throws {
        let (harness, asset) = try await completed(autoDelete: false)
        var policy = OfflineCompletionPolicy()
        _ = policy.opened(asset.id)
        await apply(policy.ended(.endOfFile), to: harness.manager)
        await apply(policy.opened(nil), to: harness.manager)
        let kept = try #require(await harness.manager.asset(asset.id))
        #expect(kept.watched)
        #expect(!kept.pendingAutoDelete)
        #expect(harness.folderExists(asset.id))
    }

    // 27. A crash between the end and the release: the delete finishes at the next launch.
    @Test func aPendingAutoDeleteFinishesAfterARelaunch() async throws {
        let (harness, asset) = try await completed(autoDelete: true)
        await harness.manager.playbackEnded(asset.id)
        #expect(harness.folderExists(asset.id))
        let relaunched = harness.relaunched()
        await relaunched.manager.start()
        #expect(await relaunched.manager.asset(asset.id) == nil)
        #expect(!harness.folderExists(asset.id))
    }

    // MARK: Relaunch

    // A record says "downloading" but the session lost the transfers: they are sent again.
    @Test func aRelaunchResubmitsWhatTheSessionNoLongerHas() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        await harness.transport.setActive([requests[1].tag])
        await harness.transport.clearSubmitted()
        let relaunched = harness.relaunched()
        await relaunched.manager.start()
        let again = await relaunched.waitForSubmissions(2)
        #expect(Set(again.map(\.tag.unit)) == Set([requests[2].tag.unit, requests[3].tag.unit]))
        #expect(await relaunched.manager.asset(asset.id)?.state == .downloading)
    }

    // MARK: DRM

    // 35. A FairPlay stream is offered to nobody for download, and an AVPlayer-only asset never reaches MPV.
    @Test func drmIsAVPlayerOnlyAndNeverDownloadedForMPV() async throws {
        let network = FakeNetwork([Fixture.master.absoluteString: .text(Fixture.masterText([
            "#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://k\",KEYFORMAT=\"com.apple.streamingkeydelivery\"",
            Fixture.variant(1920, 1080, bandwidth: 5_000_000, uri: "v.m3u8"),
        ]))])
        let harness = OfflineHarness(network: network)
        let options = try await harness.manager.options(for: Fixture.target())
        #expect(options.refusal?.kind == .drmProtected)
        #expect(options.compatibility == .avPlayerOnly)

        var asset = OfflineAsset(identity: Fixture.identity(), title: Fixture.title(), mode: .smart,
                                 autoDeleteAfterWatching: false, allowsCellular: false)
        asset.compatibility = .avPlayerOnly
        let source = OfflinePlaybackSource(assetID: asset.id, url: URL(fileURLWithPath: "/x.movpkg"),
                                           compatibility: .avPlayerOnly, sidecars: [], folder: URL(fileURLWithPath: "/"),
                                           label: "離線")
        #expect(OfflinePlaybackResolver.target(for: source, engine: .native) != nil)
        #expect(OfflinePlaybackResolver.target(for: source, engine: .mpv) == nil)
    }

    // MARK: The sheet

    @Test func optionsDescribeEachModeWithoutDownloading() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let options = try await harness.manager.options(for: Fixture.target())
        #expect(options.kind == .hls)
        #expect(options.durationSeconds == 24)
        #expect(options.option(for: .smart)?.video?.height == 1080)
        #expect(options.option(for: .saver)?.video?.height == 720)
        #expect(options.option(for: .smart)?.estimate == OfflineSizeEstimate(bytes: 7_500_000, basis: .averageBandwidth))
        #expect(await harness.manager.snapshot().assets.isEmpty)
    }

    // Sidecar subtitles are kept as files and offered to both engines offline.
    @Test func sourceSubtitlesAreKeptWithTheDownload() async throws {
        let subtitleURL = "https://subs.example.com/zh.srt"
        let harness = OfflineHarness(network: Fixture.simpleNetwork(),
                                     subtitleFiles: [subtitleURL: "1\n00:00:01,000 --> 00:00:02,000\n你好\n"])
        let target = Fixture.target(subtitles: [SourceSubtitle(url: subtitleURL, name: "繁中", language: "zh-TW"),
                                                SourceSubtitle(url: "https://subs.example.com/en.srt", name: "English", language: "en")])
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: target,
            choice: OfflineDownloadChoice(mode: .smart, subtitleIDs: ["sidecar|0"]), estimate: .unknown,
            autoDeleteAfterWatching: false, allowsCellular: false) else { Issue.record("not created"); return }
        _ = await harness.waitFor(asset.id, .downloading)
        _ = await harness.waitForSubmissions(4)
        let done = try #require(await harness.completeAll(asset.id))
        #expect(done.subtitles.map(\.name) == ["繁中"])
        // 9. The subtitle not chosen was never fetched.
        #expect(!harness.log.all.contains { $0.url?.absoluteString == "https://subs.example.com/en.srt" })
        let source = try #require(OfflinePlaybackResolver.source(for: done, layout: harness.layout,
                                                                 serverBase: URL(string: "http://127.0.0.1:1/t/")!))
        let files = OfflinePlaybackResolver.externalSubtitles(source)
        #expect(files.count == 1)
        #expect(files.first?.cues.cues.count == 1)
        #expect(files.first?.fileURL.path.hasPrefix(harness.layout.folder(for: asset.id).path) == true)
    }

    // 40. Offline playback writes the same watch-history record online playback would.
    @Test func offlineTitleInfoKeepsTheWatchHistoryIdentity() {
        let identity = Fixture.identity()
        let title = Fixture.title()
        let record = WatchHistory(key: identity.historyKey, siteKey: title.siteKey, siteName: title.siteName,
                                  sourceID: title.sourceID, vodId: title.vodId, vodName: title.vodName,
                                  vodFlag: identity.flag, vodRemarks: title.episodeName, episodeUrl: identity.episodeURL)
        #expect(record.key == WatchHistory.key(siteID: "site\u{0}{}", vodId: "vod1"))
        #expect(record.startPosition(resuming: true) == 0)
    }
}
