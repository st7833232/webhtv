import Foundation
import Testing
@testable import WebHTVCore

/// IOS-POC-51: what the viewer reported — 「最多約 281 MB」 before, more than 700 MB after. The
/// estimate came from the BANDWIDTH a playlist declares, which a source can understate; the size
/// now comes from what its segments really weigh, before and while downloading, because the space
/// check and the sheet both rely on it.
struct OfflineSizeEstimateTests {
    static let base = "https://cdn.example.com/show/ep1/"
    static let master = URL(string: base + "master.m3u8")!
    /// Eight 6 s segments of 3 MB each: 500,000 bytes a second, 24 MB over 48 s. The master
    /// declares 800 kb/s, which would make it 4.8 MB.
    static let segmentBytes: Int64 = 3_000_000
    static let declared = OfflineSizeEstimate(bytes: 4_800_000, basis: .peakBandwidth)
    static let measured = OfflineSizeEstimate(bytes: 24_000_000, basis: .sampled)

    /// The stream, with each segment answering a one-byte request as `segment` says.
    static func network(segment: FakeNetwork.Response? = .init(data: Data([0x47]), status: 206,
                                                               headers: ["content-range": "bytes 0-0/\(segmentBytes)"]),
                        segmentBase: String = base + "1080/") -> FakeNetwork {
        var responses: [String: FakeNetwork.Response] = [
            master.absoluteString: .text(Fixture.masterText([Fixture.variant(1920, 1080, bandwidth: 800_000, uri: "1080/index.m3u8")])),
            base + "1080/index.m3u8": .text(Fixture.media(8, prefix: segmentBase + "seg")),
        ]
        if let segment {
            for index in 0..<8 { responses[segmentBase + "seg\(index).ts"] = segment }
        }
        return FakeNetwork(responses)
    }

    private func start(_ harness: OfflineHarness, target: PlaybackTarget = Fixture.target(master)) async -> OfflineAsset? {
        await harness.manager.start()
        let result = await harness.manager.enqueue(
            identity: Fixture.identity(), title: Fixture.title(), target: target, choice: OfflineDownloadChoice(mode: .smart),
            estimate: OfflineSizeEstimate(bytes: 1_000_000, basis: .averageBandwidth),
            autoDeleteAfterWatching: false, allowsCellular: false)
        guard case .created(let asset) = result else { return nil }
        return asset
    }

    private func sampleRequests(_ harness: OfflineHarness) -> [URLRequest] {
        harness.log.all.filter { $0.url?.lastPathComponent.hasSuffix(".ts") == true }
    }

    // The reported case: the segments, not the declared BANDWIDTH, decide the size — read one
    // byte at a time, never by downloading the segments.
    @Test func aBandwidthTheSourceUnderstatesIsReplacedByTheSegmentsRealSize() async throws {
        let harness = OfflineHarness(network: Self.network())
        let asset = try #require(await start(harness))

        let downloading = try #require(await harness.waitFor(asset.id, .downloading))
        #expect(downloading.estimate == Self.measured)
        let samples = sampleRequests(harness)
        #expect(samples.count == OfflineDownloadManager.sampledSegments)
        #expect(samples.allSatisfy { $0.value(forHTTPHeaderField: "Range") == "bytes=0-0" })
    }

    // Why it matters: with the declared 4.8 MB this fits in 510 MB; the real 24 MB does not.
    @Test func theSpaceCheckUsesTheMeasuredSize() async throws {
        let harness = OfflineHarness(network: Self.network(), capacity: 510_000_000)
        let asset = try #require(await start(harness))

        let failed = try #require(await harness.waitFor(asset.id, .failed))
        #expect(failed.failure?.kind == .insufficientStorage)
    }

    // The sheet shows the number the download then uses.
    @Test func theSheetMeasuresWhatTheDownloadWillUse() async throws {
        let harness = OfflineHarness(network: Self.network())
        let options = try await harness.manager.options(for: Fixture.target(Self.master))
        #expect(options.option(for: .smart)?.estimate == Self.declared)

        let shown = await harness.manager.sizeEstimate(for: Fixture.target(Self.master),
                                                       choice: OfflineDownloadChoice(mode: .smart, variant: options.option(for: .smart)?.variant))
        #expect(shown == Self.measured)
        #expect(await harness.manager.snapshot().assets.isEmpty)
    }

    // Segments on another host get no Cookie, as in the download itself.
    @Test func measuringKeepsCredentialsOnTheStreamsOwnHost() async throws {
        let harness = OfflineHarness(network: Self.network(segmentBase: "https://seg.other.example/ep1/"))
        let target = Fixture.target(Self.master, headers: ["Cookie": "sid=secret", "User-Agent": "WebHTV"])
        _ = await harness.manager.sizeEstimate(for: target, choice: OfflineDownloadChoice(mode: .smart))

        let samples = sampleRequests(harness)
        #expect(samples.count == OfflineDownloadManager.sampledSegments)
        #expect(samples.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        #expect(samples.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "WebHTV" })
        #expect(harness.log.all.contains { $0.url == Self.master && $0.value(forHTTPHeaderField: "Cookie") == "sid=secret" })
    }

    // A server that names no size leaves the declared estimate, shown as declared.
    @Test func withoutSizesTheDeclaredEstimateStays() async throws {
        let harness = OfflineHarness(network: Self.network(segment: .init(data: Data([0x47]), status: 200)))
        let asset = try #require(await start(harness))

        #expect(try #require(await harness.waitFor(asset.id, .downloading)).estimate == Self.declared)
    }

    // A playlist with no master declares nothing: it used to have no estimate at all.
    @Test func aBareMediaPlaylistGetsASize() async throws {
        let media = URL(string: Self.base + "1080/index.m3u8")!
        let harness = OfflineHarness(network: Self.network())
        let asset = try #require(await start(harness, target: Fixture.target(media)))

        #expect(try #require(await harness.waitFor(asset.id, .downloading)).estimate == Self.measured)
    }

    // MARK: While downloading

    private static func unit(_ index: Int, _ path: String, seconds: Double?, role: OfflineDownloadUnit.Role = .segment) -> OfflineDownloadUnit {
        OfflineDownloadUnit(index: index, remoteURL: URL(string: "https://cdn.example.com/\(index)")!, byteRange: nil,
                            relativePath: path, role: role, seconds: seconds)
    }

    /// Ten 6 s video segments, ten 6 s audio segments, one key.
    static let plan = OfflinePackagePlan(
        units: (0..<10).map { unit($0, "media/v\($0).ts", seconds: 6) } + (0..<10).map { unit(10 + $0, "audio/a\($0).aac", seconds: 6) }
            + [unit(20, "keys/k1.key", seconds: nil, role: .key)],
        playlists: [:], package: .hls(entryPath: "playlists/index.m3u8"), origin: master, headers: [:])

    // Video and audio each at their own rate: averaging all files together would count the small
    // audio files at the video's size.
    @Test func eachTrackIsProjectedAtItsOwnRate() {
        let sizes: [Int: Int64] = [0: 1_000_000, 1: 1_000_000, 10: 100_000, 20: 16]
        // Video 2 MB / 12 s over 60 s = 10 MB; audio 0.1 MB / 6 s over 60 s = 1 MB; the key.
        #expect(Self.plan.projectedBytes(finished: sizes) == 11_000_016)
    }

    @Test func noProjectionBeforeATenthOfTheMainTrack() {
        #expect(Self.plan.projectedBytes(finished: [20: 16]) == nil)
        // A plan saved before segments carried durations never projects.
        let old = OfflinePackagePlan(units: (0..<10).map { Self.unit($0, "media/v\($0).ts", seconds: nil) }, playlists: [:],
                                     package: .hls(entryPath: "playlists/index.m3u8"), origin: Self.master, headers: [:])
        #expect(old.projectedBytes(finished: [0: 1_000_000, 1: 1_000_000, 2: 1_000_000]) == nil)
    }

    // A running download shows the size its segments are coming to, and keeps it over a relaunch.
    @Test func aRunningDownloadProjectsItsSizeFromWhatArrived() async throws {
        let harness = OfflineHarness(network: Fixture.simpleNetwork())
        let (asset, requests) = try await harness.startSimpleDownload()
        #expect(await harness.manager.asset(asset.id)?.progress.projectedBytes == nil)

        await harness.transport.finish(requests[0].tag, body: Fixture.segment(1880))
        // One of four 6 s segments: 1,880 bytes for 6 s, over 24 s.
        #expect(await harness.manager.asset(asset.id)?.progress.projectedBytes == 7520)

        let relaunched = harness.relaunched(network: Fixture.simpleNetwork())
        await relaunched.manager.start()
        #expect(await relaunched.manager.asset(asset.id)?.progress.projectedBytes == 7520)
    }
}
