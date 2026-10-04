import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-49: what the viewer reported on a phone — a download queued before 允許使用行動網路下載
/// was turned on sat at 0% on 5G for good — and the 全部下載 they asked for: from where they left
/// off, each episode resolved only when its turn comes, packaged as the sheet would have.
struct OfflineCellularAndBulkTests {
    // MARK: 允許使用行動網路下載 reaches downloads already queued

    // The reported case: the setting changes while a download runs. Its unfinished pieces are sent
    // again under the new rule; the finished one is not fetched twice.
    @Test func turningCellularOnReachesADownloadAlreadyRunning() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        #expect(requests.count == 4 && requests.allSatisfy { !$0.allowsCellular })
        await harness.transport.finish(requests[0].tag, body: Fixture.segment())
        await harness.transport.clearSubmitted()

        await harness.manager.setAllowsCellular(true)

        let again = await harness.waitForSubmissions(3, assetID: asset.id)
        #expect(again.count == 3)
        #expect(again.allSatisfy { $0.allowsCellular && $0.tag.generation > requests[0].tag.generation })
        #expect(Set(again.map(\.tag.unit)) == Set(requests.dropFirst().map(\.tag.unit)))
        #expect(await harness.manager.asset(asset.id)?.allowsCellular == true)
        #expect(await harness.completeAll(asset.id)?.state == .completed)
    }

    // The app applies the setting at every launch: when nothing changed, nothing restarts.
    @Test func applyingTheSameCellularSettingRestartsNothing() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = await harness.startSimpleDownload()
        await harness.transport.clearSubmitted()

        await harness.manager.setAllowsCellular(false)

        #expect(await harness.transport.cancelled.isEmpty)
        #expect(await harness.transport.submitted.isEmpty)
        #expect(await harness.manager.asset(asset.id)?.generation == requests[0].tag.generation)
    }

    // Resume data carries the request it was made from, cellular rule included: a paused single file
    // starts over under the new rule rather than resume under the old one.
    @Test func aCellularChangeDropsResumeDataMadeUnderTheOldRule() async throws {
        let file = URL(string: "https://cdn.example.com/movie.mp4")!
        let network = FakeNetwork([file.absoluteString: .init(data: Data(repeating: 0, count: 1024), status: 206,
                                                              headers: ["content-range": "bytes 0-1023/50000000"])])
        let harness = OfflineHarness(network: network)
        await harness.manager.start()
        guard case .created(let asset) = await harness.manager.enqueue(
            identity: Fixture.identity("movie"), title: Fixture.title(), target: Fixture.target(file),
            choice: OfflineDownloadChoice(mode: .smart), estimate: .unknown, autoDeleteAfterWatching: false,
            allowsCellular: false) else { Issue.record("not created"); return }
        _ = await harness.waitForSubmissions(1)
        await harness.transport.setResumeData(Data("resume".utf8), for: asset.id)
        await harness.manager.pause(asset.id)
        #expect(FileManager.default.fileExists(atPath: harness.layout.resumeDataFile(for: asset.id, unit: 0).path))

        await harness.manager.setAllowsCellular(true)
        await harness.transport.clearSubmitted()
        await harness.manager.resume(asset.id)

        let resumed = await harness.waitForSubmissions(1)
        #expect(resumed.first?.resumeData == nil)
        #expect(resumed.first?.allowsCellular == true)
    }

    // MARK: 全部下載

    private func queueAutomatic(_ harness: OfflineHarness, _ episode: String, mode: OfflineQualityMode = .smart,
                                language: String? = nil) async -> OfflineAsset? {
        let result = await harness.manager.enqueueAutomatic(
            identity: Fixture.identity(episode), title: Fixture.title(episode), mode: mode, allowHighFrameRate: false,
            preferredSubtitleLanguage: language, autoDeleteAfterWatching: true, allowsCellular: false)
        guard case .created(let asset) = result else { return nil }
        return asset
    }

    // Signed addresses expire: an episode waiting behind others is resolved when its turn comes,
    // not when 全部下載 is pressed — and nothing is ever fetched from the placeholder.
    @Test func downloadAllResolvesEachEpisodeOnlyWhenItsTurnComes() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let resolved = Resolutions()
        await harness.manager.setResolver { asset in
            resolved.append(asset.identity.episodeURL)
            return Fixture.target()
        }
        await harness.manager.start()
        let first = try #require(await queueAutomatic(harness, "ep1"))
        let second = try #require(await queueAutomatic(harness, "ep2"))

        _ = await harness.waitFor(first.id, .downloading)
        _ = await harness.waitForSubmissions(4, assetID: first.id)
        #expect(resolved.all == [Fixture.identity("ep1").episodeURL])
        #expect(await harness.manager.asset(second.id)?.state == .queued)

        #expect(await harness.completeAll(first.id)?.state == .completed)
        #expect(await harness.waitFor(second.id, .downloading)?.state == .downloading)
        #expect(resolved.all == [Fixture.identity("ep1").episodeURL, Fixture.identity("ep2").episodeURL])
        #expect(!harness.log.all.contains { $0.url?.scheme == "about" })
    }

    // The same package a 下載 with the sheet untouched makes: its quality and its preselected subtitle.
    @Test func downloadAllPicksWhatTheSheetPreselects() async throws {
        let subtitleURL = "https://subs.example.com/zh.srt"
        let harness = OfflineHarness(network: Fixture.simpleNetwork(),
                                     subtitleFiles: [subtitleURL: "1\n00:00:01,000 --> 00:00:02,000\n你好\n"])
        let target = Fixture.target(subtitles: [SourceSubtitle(url: "https://subs.example.com/en.srt", name: "English", language: "en"),
                                                SourceSubtitle(url: subtitleURL, name: "繁中", language: "zh-TW")])
        let sheet = try #require(try await harness.manager.options(for: target, preferredSubtitleLanguage: "zh-TW")
            .option(for: .saver))
        #expect(sheet.video?.height == 720)
        #expect(sheet.defaultSubtitleIDs == ["sidecar|1"])
        await harness.manager.setResolver { _ in target }
        await harness.manager.start()

        let asset = try #require(await queueAutomatic(harness, "ep1", mode: .saver, language: "zh-TW"))
        let downloading = try #require(await harness.waitFor(asset.id, .downloading))

        #expect(downloading.video == sheet.video)
        #expect(downloading.subtitles.map(\.id) == sheet.defaultSubtitleIDs)
    }

    // An episode the sheet would have refused (DRM) is not packaged; it waits in 需要處理 with the
    // reason, and 重新下載 reads the source again rather than the placeholder.
    @Test func downloadAllShowsARefusedEpisodeAndResolvesItAgainOnRetry() async throws {
        let network = FakeNetwork([Fixture.master.absoluteString: .text(Fixture.masterText([
            "#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://k\",KEYFORMAT=\"com.apple.streamingkeydelivery\"",
            Fixture.variant(1920, 1080, bandwidth: 5_000_000, uri: "v.m3u8"),
        ]))])
        let harness = OfflineHarness(network: network)
        let resolved = Resolutions()
        await harness.manager.setResolver { asset in
            resolved.append(asset.identity.episodeURL)
            return Fixture.target()
        }
        await harness.manager.start()
        let asset = try #require(await queueAutomatic(harness, "ep1"))

        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .drmProtected)
        #expect(await harness.transport.submitted.isEmpty)

        await harness.manager.resume(asset.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while resolved.all.count < 2, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(resolved.all.count == 2)
        #expect(!harness.log.all.contains { $0.url?.scheme == "about" })
    }

    // 從目前觀看進度之後: the watched episode and everything after it on the line, minus what
    // already has a download in any state.
    @Test func downloadAllStartsWhereTheViewerLeftOff() {
        let flag = Flag(name: "線路①", episodes: (1...5).map { Episode(name: "第0\($0)集", url: "https://s.example.com/\($0)") })
        func names(_ picked: [(index: Int, episode: Episode)]) -> [String] { picked.map(\.episode.name) }

        let fromThird = OfflineBulkSelection.downloadAll(
            flag, watchedFlag: "線路①", watchedURL: "https://s.example.com/3", watchedName: "第03集", spider: false,
            hasDownload: { $0.url == "https://s.example.com/4" })
        #expect(names(fromThird) == ["第03集", "第05集"])
        #expect(fromThird.map(\.index) == [2, 4])

        // Watched on another line: the same episode by name.
        let otherLine = OfflineBulkSelection.downloadAll(
            flag, watchedFlag: "線路②", watchedURL: "https://other.example.com/2", watchedName: "第02集", spider: false,
            hasDownload: { _ in false })
        #expect(names(otherLine) == ["第02集", "第03集", "第04集", "第05集"])

        // No history, or an episode the line no longer lists: the whole line.
        let none = OfflineBulkSelection.downloadAll(flag, watchedFlag: nil, watchedURL: nil, watchedName: nil, spider: false,
                                                    hasDownload: { _ in false })
        #expect(none.count == 5)
        let gone = OfflineBulkSelection.downloadAll(flag, watchedFlag: "線路①", watchedURL: "https://s.example.com/9",
                                                    watchedName: "第09集", spider: false, hasDownload: { _ in false })
        #expect(gone.count == 5)

        // An episode the screen does not offer is never queued.
        let withBlank = Flag(name: "線路①", episodes: flag.episodes + [Episode(name: "預告", url: "")])
        #expect(OfflineBulkSelection.downloadAll(withBlank, watchedFlag: nil, watchedURL: nil, watchedName: nil, spider: true,
                                                 hasDownload: { _ in false }).count == 5)
    }
}

/// The episodes a resolver was asked for, in order.
final class Resolutions: @unchecked Sendable {
    private let lock = NSLock()
    private var urls = [String]()
    func append(_ url: String) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
}
