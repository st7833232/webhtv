import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-25. What the app does with the detector's ranges: which playlists are read and how often,
// when a plan is trusted, and every rule that decides whether a reading of the engine becomes a
// seek. The playlists are `Corpus`'s, whose ranges `HLSAdsParserTests` pins to Android's output.

/// Serves playlists by address, in order when an address has several answers, and remembers every
/// request — so a test can say what was read, how often, and what never was.
private actor FakeServer {
    /// An answer that is a failed request rather than a body.
    static let failure = "\u{0}failure"
    private var responses: [String: [String]]
    private let redirects: [String: String]
    private(set) var hits = [String]()

    init(_ responses: [String: [String]], redirects: [String: String] = [:]) {
        self.responses = responses
        self.redirects = redirects
    }

    func respond(_ url: URL) throws -> HLSFetchedPlaylist {
        let key = url.absoluteString
        hits.append(key)
        guard var answers = responses[key], !answers.isEmpty else { throw URLError(.fileDoesNotExist) }
        let text = answers.count > 1 ? answers.removeFirst() : answers[0]
        responses[key] = answers
        guard text != Self.failure else { throw URLError(.networkConnectionLost) }
        return HLSFetchedPlaylist(text: text, url: redirects[key].flatMap(URL.init(string:)) ?? url)
    }

    nonisolated var fetch: HLSAdPlanner.Fetch { { url in try await self.respond(url) } }
}

private let mediaURL = URL(string: "https://cdn.example.com/show/ep1/index.m3u8")!
private let masterURL = URL(string: "https://cdn.example.com/show/ep1/master.m3u8")!
private let withAd = Corpus.input("b-host-ad-middle")          // [120 s, 135 s) of 255 s
private let withoutAds = Corpus.input("a-no-ads")
private let adRange = HLSAdTimeline.Range(startMs: 120_000, endMs: 135_000)

private func master(_ uris: [String]) -> String {
    "#EXTM3U\n" + uris.enumerated().map { index, uri in
        "#EXT-X-STREAM-INF:BANDWIDTH=\((index + 1) * 800_000),RESOLUTION=640x360\n\(uri)\n"
    }.joined()
}

// MARK: - Which playlists are read

@Test func onlyAnHTTPAddressContainingM3u8IsEverACandidate() {
    #expect(HLSAdPlanner.isCandidate(URL(string: "https://cdn.example.com/a/index.m3u8?token=1")!))
    #expect(HLSAdPlanner.isCandidate(URL(string: "http://cdn.example.com/a/INDEX.M3U8")!))
    // `MpvPlayer.isLikelyHls` looks for "m3u8" anywhere, a wrapped address included.
    #expect(HLSAdPlanner.isCandidate(URL(string: "https://player.example.com/?url=https://cdn/x.m3u8")!))
    #expect(!HLSAdPlanner.isCandidate(URL(string: "https://cdn.example.com/a/movie.mp4")!))
    #expect(!HLSAdPlanner.isCandidate(URL(string: "https://cdn.example.com/a/manifest.mpd")!))
    #expect(!HLSAdPlanner.isCandidate(URL(string: "https://cdn.example.com/a/live.flv")!))
    #expect(!HLSAdPlanner.isCandidate(URL(string: "rtmp://cdn.example.com/a/index.m3u8")!))
    #expect(!HLSAdPlanner.isCandidate(URL(string: "file:///tmp/index.m3u8")!))
}

@Test func dashAndMp4AreNeverRequestedAtAll() async {
    let server = FakeServer([:])
    for address in ["https://cdn.example.com/a/movie.mp4", "https://cdn.example.com/a/manifest.mpd"] {
        let plan = await HLSAdPlanner.plan(for: URL(string: address)!, fetch: server.fetch)
        #expect(plan.timeline.ranges.isEmpty)
        #expect(plan.timeline.reason == "not-hls")
    }
    #expect(await server.hits.isEmpty)
}

@Test func aPlaylistWithoutAdsIsReadOnceAndChangesNothing() async {
    let server = FakeServer([mediaURL.absoluteString: [withoutAds]])
    let plan = await HLSAdPlanner.plan(for: mediaURL, fetch: server.fetch)
    #expect(plan.timeline == HLSAdTimeline.none)
    #expect(plan.timeline(for: .native) == nil)
    #expect(await server.hits.count == 1)
}

@Test func aMediaPlaylistWithAnAdIsReadTwiceAndKeepsItsRanges() async {
    let server = FakeServer([mediaURL.absoluteString: [withAd]])
    let plan = await HLSAdPlanner.plan(for: mediaURL, fetch: server.fetch)
    #expect(plan.timeline.ranges == [adRange])
    #expect(plan.timeline.durationUs == 255_000_000)
    #expect(plan.hasDiscontinuity)
    #expect(await server.hits == [mediaURL.absoluteString, mediaURL.absoluteString])
}

@Test func aPlaylistThatCutsDifferentlyWhenReadAgainSkipsNothing() async {
    // A CDN that inserts its ad somewhere else on every request: the reading the engine got may
    // not be the one analysed, so neither is trusted.
    let moved = Corpus.pl(Corpus.prog(0..<10), Corpus.disc, Corpus.ads(3), Corpus.disc, Corpus.prog(10..<40))
    let server = FakeServer([mediaURL.absoluteString: [withAd, moved]])
    let plan = await HLSAdPlanner.plan(for: mediaURL, fetch: server.fetch)
    #expect(plan.timeline.ranges.isEmpty)
    #expect(plan.timeline.reason == "unstable-playlist")
}

@Test func aSecondReadingThatFailsSkipsNothing() async {
    // Without the second reading the first cannot be shown to be the one the engine got.
    let server = FakeServer([mediaURL.absoluteString: [withAd, FakeServer.failure]])
    let plan = await HLSAdPlanner.plan(for: mediaURL, fetch: server.fetch)
    #expect(plan.timeline.ranges.isEmpty)
    #expect(plan.timeline.reason == "fetch-failed")
    #expect(await server.hits.count == 2)
}

@Test func aFailedFirstReadingSkipsNothing() async {
    let plan = await HLSAdPlanner.plan(for: mediaURL, fetch: FakeServer([:]).fetch)
    #expect(plan.timeline.ranges.isEmpty)
    #expect(plan.timeline.reason == "fetch-failed")
}

@Test func liveLowLatencyMalformedAndNonPlaylistBodiesSkipNothing() async {
    for body in [Corpus.input("m-live-no-endlist"), Corpus.input("n-llhls-parts"), Corpus.input("r-malformed-extinf"),
                 "<html><body>not a playlist</body></html>", ""] {
        let plan = await HLSAdPlanner.plan(for: mediaURL, fetch: FakeServer([mediaURL.absoluteString: [body]]).fetch)
        #expect(plan.timeline.ranges.isEmpty)
    }
}

// MARK: - Variants

@Test func everyDeclaredVariantAgreeingIsTheOnlyWayAMasterGetsRanges() async {
    // Relative variant URIs resolve against the address the master finally came from.
    let entry = "https://entry.example.com/play/ep1.m3u8"
    let server = FakeServer([entry: [master(["low/index.m3u8", "mid/index.m3u8"])],
                             "https://cdn.example.com/show/ep1/low/index.m3u8": [withAd],
                             "https://cdn.example.com/show/ep1/mid/index.m3u8": [withAd]],
                            redirects: [entry: masterURL.absoluteString])
    let plan = await HLSAdPlanner.plan(for: URL(string: entry)!, fetch: server.fetch)
    #expect(plan.timeline.ranges == [adRange])
    #expect(plan.timeline(for: .native)?.ranges == [adRange])
}

@Test func aVariantThatCutsDifferentlyMeansNothingIsSkipped() async {
    // Probing a rendition does not mean the player chose it; AVPlayer also switches between them.
    let server = FakeServer([masterURL.absoluteString: [master(["low/index.m3u8", "mid/index.m3u8"])],
                             "https://cdn.example.com/show/ep1/low/index.m3u8": [withAd],
                             "https://cdn.example.com/show/ep1/mid/index.m3u8": [withoutAds]])
    #expect(await HLSAdPlanner.plan(for: masterURL, fetch: server.fetch).timeline.ranges.isEmpty)
}

@Test func aVariantThatCannotBeReadMeansNothingIsSkipped() async {
    let server = FakeServer([masterURL.absoluteString: [master(["low/index.m3u8", "mid/index.m3u8"])],
                             "https://cdn.example.com/show/ep1/low/index.m3u8": [withAd]])
    let plan = await HLSAdPlanner.plan(for: masterURL, fetch: server.fetch)
    #expect(plan.timeline.ranges.isEmpty)
    #expect(plan.timeline.reason == "variant-unreadable")
}

@Test func anUnreadableVariantSharingABitrateIsNotMistakenForADuplicate() async {
    // The resolver counts declared bitrates, so a 720p entry at the 360p entry's bandwidth adds
    // nothing to the count: only reading every entry shows the player's choice was checked.
    let text = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
    sd/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
    hd/index.m3u8

    """
    let server = FakeServer([masterURL.absoluteString: [text],
                             "https://cdn.example.com/show/ep1/sd/index.m3u8": [withAd]])
    let plan = await HLSAdPlanner.plan(for: masterURL, fetch: server.fetch)
    #expect(plan.timeline.ranges.isEmpty)
    #expect(plan.timeline.reason == "variant-unreadable")
}

@Test func audioRenditionsAndIFramePlaylistsAreNeitherReadNorCounted() async {
    let text = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="zh",URI="audio/zh.m3u8"
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200000,URI="iframe/index.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360,AUDIO="aud"
    video/index.m3u8

    """
    let server = FakeServer([masterURL.absoluteString: [text],
                             "https://cdn.example.com/show/ep1/video/index.m3u8": [withAd]])
    let plan = await HLSAdPlanner.plan(for: masterURL, fetch: server.fetch)
    #expect(plan.timeline.ranges == [adRange])
    let hits = await server.hits
    #expect(!hits.contains { $0.contains("audio/") || $0.contains("iframe/") })
}

@Test func aMasterDeclaringMoreThanEightVariantsIsNotRead() async {
    let uris = (0..<9).map { "v\($0)/index.m3u8" }
    let server = FakeServer([masterURL.absoluteString: [master(uris)]])
    let plan = await HLSAdPlanner.plan(for: masterURL, fetch: server.fetch)
    #expect(plan.timeline.reason == "too-many-variants")
    #expect(await server.hits == [masterURL.absoluteString])
}

@Test func streamVariantsAreReadAsAndroidsRewriterReadsThem() {
    // Android's `HlsPlaylistRewriter.rewrite` over this text on JDK 21 listed exactly these STREAM
    // variants (it also listed the I-frame playlist, as I_FRAME, which never counts).
    let text = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="中文",LANGUAGE="zh",URI="audio/zh.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1280000,AVERAGE-BANDWIDTH=1000000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=640x360,AUDIO="aud"
    low/index.m3u8
    #EXT-X-STREAM-INF:CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920X1080,BANDWIDTH=5000000,FRAME-RATE=25.000
    https://cdn.example.com/hd/index.m3u8?token=a,b
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200000,URI="iframe/index.m3u8"
    #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=700000,RESOLUTION=bad
      mid/index.m3u8\u{20}\u{20}
    #EXT-X-STREAM-INF:BANDWIDTH=-5,RESOLUTION=0x0
    #EXT-X-SOMETHING
    neg/index.m3u8

    """
    let entries = HLSAdPlanner.streamVariants(text)
    #expect(entries.map { $0.uri } == ["low/index.m3u8", "https://cdn.example.com/hd/index.m3u8?token=a,b",
                                   "mid/index.m3u8", "neg/index.m3u8"])
    #expect(entries.map { $0.variant } == [
        .init(bandwidth: 1_280_000, averageBandwidth: 1_000_000, width: 640, height: 360),
        .init(bandwidth: 5_000_000, averageBandwidth: 0, width: 1920, height: 1080),
        .init(bandwidth: 0, averageBandwidth: 700_000, width: 0, height: 0),
        .init(bandwidth: 0, averageBandwidth: 0, width: 0, height: 0),
    ])
    // Three regular variants with a bitrate: the zero-bitrate one can never make the count, so a
    // plan that read it as well has one variant too many and is refused.
    #expect(HLSAdTimeline.declaredVariantCount(entries.map { $0.variant }) == 3)
}

// MARK: - Plans iOS does not trust

@Test func aPlanSkippingMoreThanAQuarterOfTheRuntimeIsRefused() {
    // Android's own mapping of this playlist is [60 s, 90 s) of 102 s.
    let text = Corpus.pl(Corpus.prog(0..<10), Corpus.disc, Corpus.seg("https://ad.example.net/x/long.ts", "30"),
                         Corpus.disc, Corpus.prog(10..<12))
    #expect(HLSAdTimeline.from(original: text, filtered: HLSAdsParser.process(text)).ranges
        == [.init(startMs: 60_000, endMs: 90_000)])
    #expect(HLSAdPlanner.plan(mediaPlaylist: text).timeline.reason == "implausible-share")
}

@Test func morePathGroupRangesThanTheDetectorAllowsBreaksIsRefused() {
    // Four separate ranges in a ten-minute playlist; the detector itself allows three ad breaks up
    // to thirty minutes. Android maps all four.
    let text = Corpus.pl(Corpus.prog(0..<20), Corpus.disc, Corpus.ads(1, "a"), Corpus.disc, Corpus.prog(20..<40),
                         Corpus.disc, Corpus.ads(1, "b"), Corpus.disc, Corpus.prog(40..<60), Corpus.disc,
                         Corpus.ads(1, "c"), Corpus.disc, Corpus.prog(60..<80), Corpus.disc, Corpus.ads(1, "d"),
                         Corpus.disc, Corpus.prog(80..<100))
    #expect(HLSAdTimeline.from(original: text, filtered: HLSAdsParser.process(text)).ranges.count == 4)
    #expect(HLSAdPlanner.plan(mediaPlaylist: text).timeline.reason == "too-many-ranges")
}

@Test func theAndroidReportedPlaylistIsTrustedAsAndroidTrustsIt() {
    let plan = HLSAdPlanner.plan(mediaPlaylist: Corpus.input("i-mixed-real-structure"))
    #expect(plan.timeline.ranges == [.init(startMs: 496_320, endMs: 512_786), .init(startMs: 2_013_507, endMs: 2_031_173)])
}

// MARK: - Which engine may act

@Test func bothEnginesActOnAPlaylistWithDiscontinuities() {
    // Since 0.1.23 (24) MPV's Libavformat maps timestamps across #EXT-X-DISCONTINUITY onto the
    // playlist timeline (IOS-POC-26-2b), the one AVPlayer keeps; the app refuses to link without it.
    let plan = HLSAdPlanner.plan(mediaPlaylist: withAd)
    #expect(plan.hasDiscontinuity)
    #expect(plan.timeline(for: .native)?.ranges == [adRange])
    #expect(plan.timeline(for: .mpv)?.ranges == [adRange])
    #expect(HLSAdPlan(timeline: plan.timeline, hasDiscontinuity: false).timeline(for: .mpv)?.ranges == [adRange])
}

// MARK: - Decisions over one item

private func adPlan(discontinuity: Bool = true, _ name: String = "b-host-ad-middle") -> HLSAdPlan {
    let plan = HLSAdPlanner.plan(mediaPlaylist: Corpus.input(name))
    return HLSAdPlan(timeline: plan.timeline, hasDiscontinuity: discontinuity)
}

/// One item's skipper, driven the way `PlaybackSession`'s watch drives it: a reading every tenth
/// of a second unless a test says otherwise.
private struct Drive {
    var skipper = HLSAdSkipper()
    var now = ContinuousClock.now
    var engine = PlaybackEngineKind.native
    var duration = 255.0
    var ending: Double?
    var enabled = true

    init(_ plan: HLSAdPlan?, url: String = "https://cdn.example.com/show/ep1/index.m3u8") {
        let generation = skipper.begin(url: URL(string: url)!)
        if let plan { skipper.adopt(plan, for: generation) }
    }

    mutating func read(_ position: Double, playing: Bool = true, rate: Float = 1,
                       after step: Duration = .milliseconds(100)) -> Double? {
        now = now + step
        return skipper.automaticTarget(position: position, duration: duration, rate: rate, playing: playing,
                                       engine: engine, enabled: enabled, endingThreshold: ending, now: now)
    }

    mutating func seek(_ seconds: Double) -> Double {
        skipper.manualTarget(seconds, duration: duration, engine: engine, enabled: enabled,
                             endingThreshold: ending, now: now)
    }
}

@Test func playbackRunningIntoAnAdJumpsToItsEndExactlyOnce() {
    var drive = Drive(adPlan())
    #expect(drive.read(119.8) == nil)       // the first reading has nothing to be compared with
    #expect(drive.read(119.9) == nil)       // advancing, but still programme
    #expect(drive.read(119.9999) == nil)    // 119 999 ms: a range is entered only once inside it
    #expect(drive.read(120.0) == 135)
    #expect(drive.read(120.1) == nil)       // a stale reading from before the seek landed
    #expect(drive.read(135.0) == nil)       // the landing: a jump, not playback
    #expect(drive.read(135.1) == nil)
    #expect(drive.skipper.suspensionReason == nil)
}

@Test func mpvLandsATenthOfASecondBeforeTheEnd() {
    var drive = Drive(adPlan(discontinuity: false))
    drive.engine = .mpv
    _ = drive.read(119.8)
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 134.9)
    #expect(drive.read(134.9, after: .milliseconds(300)) == nil)
    #expect(drive.read(135.0) == nil)       // playing on from the target: landed
    #expect(drive.read(135.1) == nil)
    #expect(drive.skipper.suspensionReason == nil)
}

@Test func mpvReportingItsSeekTargetIsNotALanding() {
    // After a seek mpv reports the target itself as the position until the first frame decodes;
    // only that frame says where the seek landed, here a whole segment late.
    var drive = Drive(adPlan(discontinuity: false))
    drive.engine = .mpv
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 134.9)
    #expect(drive.read(134.9) == nil)
    #expect(drive.read(134.9) == nil)
    #expect(drive.read(141.0) == nil)
    #expect(drive.skipper.suspensionReason == "landed-past-target")
}

@Test func mpvWaitsAQuarterSecondIntoAnAdOnAPlaylistWithDiscontinuities() {
    // IOS-POC-26 H1: past a cut crossed without a seek, MPV's position can read later than the
    // playlist time on screen (0.232 s after two breaks on its fixtures, no fixed bound). Skipping
    // when it reads 120.0 would cut that much programme; waiting shows ad instead.
    var drive = Drive(adPlan())
    drive.engine = .mpv
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == nil)
    #expect(drive.read(120.1) == nil)
    #expect(drive.read(120.2) == nil)
    // Readings inside the delay must not use the range up: it is still skipped once it is over.
    #expect(drive.read(120.25) == 134.9)
    #expect(drive.read(134.9, after: .milliseconds(300)) == nil)
    #expect(drive.read(135.0) == nil)
    #expect(drive.skipper.suspensionReason == nil)
}

@Test func aViewersSeekIntoAnAdOnMpvIsNotDelayed() {
    // The delay guards playback; a seek's target is where the viewer chose to be. (A seek mpv
    // serves from its cache keeps any offset, so a target just inside the start can still be
    // programme on screen: an accepted edge of at most that offset.)
    var drive = Drive(adPlan())
    drive.engine = .mpv
    #expect(drive.seek(120.1) == 134.9)
    #expect(drive.seek(119.0) == 119.0)
}

@Test func aPausedPlayerInsideAnAdStaysThereUntilItPlays() {
    var drive = Drive(adPlan())
    _ = drive.read(125, playing: false, rate: 0)
    #expect(drive.read(125, playing: false, rate: 0) == nil)
    // A paused engine's position can still creep forward; only a playing one is skipped.
    #expect(drive.read(125.1, playing: false, rate: 0) == nil)
    #expect(drive.read(125.1, playing: true) == nil)    // play pressed: not advancing yet
    #expect(drive.read(125.2) == 135)
}

@Test func aPlayerPausedJustBeforeAnAdSkipsItOnlyOnceItPlaysIntoIt() {
    var drive = Drive(adPlan())
    _ = drive.read(119.5, playing: false)
    #expect(drive.read(119.5, playing: false, after: .seconds(30)) == nil)
    #expect(drive.read(119.5) == nil)           // play pressed: no motion yet
    #expect(drive.read(119.8, after: .milliseconds(300)) == nil)
    #expect(drive.read(120.05) == 135)
}

@Test func anOpeningThatEndsInsideAnAdStartsWhereTheAdEnds() {
    // IOS-POC-5S-2 starts the item at max(opening, resume) = 125 s, inside [120 s, 135 s): once
    // the engine is playing there, the ad goes, so the opening and the ad compose forward only.
    var drive = Drive(adPlan())
    #expect(drive.read(125.0) == nil)
    #expect(drive.read(125.1) == 135)
    _ = drive.read(135.0)
    #expect(drive.read(135.1) == nil)
}

@Test func aLoadsPlaceholderZeroAndTheJumpToItsStartAreNotPlayback() {
    // An engine handed the item at 600 s reads 0 until its first position arrives; the pre-roll at
    // [0, 12 s) must not pull it back there.
    var drive = Drive(adPlan("c-dir-ad-head"))
    drive.duration = 192
    drive.skipper.engineReloaded()
    #expect(drive.read(0) == nil)
    #expect(drive.read(0) == nil)
    #expect(drive.read(180) == nil)
    #expect(drive.read(180.1) == nil)
    // A load that really starts at 0 does play the pre-roll, and that is skipped.
    var fresh = Drive(adPlan("c-dir-ad-head"))
    fresh.duration = 192
    #expect(fresh.read(0) == nil)
    #expect(fresh.read(0.1) == 12)
}

@Test func aViewersSeekIntoAnAdLandsAtItsEndAndAnyOtherSeekIsUntouched() {
    var drive = Drive(adPlan())
    #expect(drive.seek(125) == 135)
    #expect(drive.seek(120) == 135)
    #expect(drive.seek(119.999) == 119.999)
    #expect(drive.seek(135) == 135)      // the end is programme: [start, end)
    #expect(drive.seek(50) == 50)
    #expect(drive.seek(200) == 200)
}

@Test func aReadingFromBeforeAViewersSeekCannotPullPlaybackIntoASkip() {
    var drive = Drive(adPlan())
    _ = drive.read(124.9, playing: false)
    #expect(drive.seek(50) == 50)
    // MPV can go on reporting the old position, still advancing, until the seek is done.
    #expect(drive.read(125.0) == nil)
    #expect(drive.read(125.1) == nil)
    #expect(drive.read(50.0) == nil)
    #expect(drive.read(50.1) == nil)
    _ = drive.read(119.9, after: .seconds(70))
    #expect(drive.read(120.0) == 135)
}

@Test func aViewersSeekStopsHoldingSkipsBackOnceItsTargetIsLongOverdue() {
    // The seek's target is never reported (another seek replaced it inside the engine): after
    // `manualSettle`, playback inside an ad is skipped again.
    var drive = Drive(adPlan())
    #expect(drive.seek(50) == 50)
    #expect(drive.read(125.0) == nil)
    #expect(drive.read(125.1, after: .seconds(2)) == nil)
    #expect(drive.read(125.2, after: .seconds(2)) == 135)
}

@Test func aJumpTheSessionDidNotMakeForgetsWhichAdsWereSkipped() {
    // PiP's skip buttons and the system's controls seek the player without passing the session;
    // an ad jumped back into is skipped again, as after the viewer's own seek.
    var drive = Drive(adPlan())
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 135)
    _ = drive.read(135.0)
    _ = drive.read(135.1)                   // landed
    #expect(drive.read(120.1) == nil)       // PiP's fifteen seconds back
    #expect(drive.read(120.2) == 135)
    #expect(drive.skipper.suspensionReason == nil)
}

@Test func seekingBackBeforeASkippedAdSkipsItAgain() {
    var drive = Drive(adPlan())
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 135)
    _ = drive.read(135.0)
    #expect(drive.seek(100) == 100)
    _ = drive.read(100.0)
    _ = drive.read(119.9, after: .seconds(20))
    #expect(drive.read(120.0) == 135)
}

@Test func anEngineSwitchForgetsWhichAdsWereSkipped() {
    var drive = Drive(adPlan())
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 135)
    // Switched mid-seek: the other engine is handed the position the first had reached.
    drive.skipper.engineReloaded()
    _ = drive.read(120.2)
    #expect(drive.read(120.3) == 135)
}

@Test func theViewersEndingOwnsTheEndOfTheItem() {
    var straddling = Drive(adPlan())
    straddling.ending = 130
    _ = straddling.read(119.9)
    #expect(straddling.read(120.0) == 130)          // the ad beyond the ending is the ending's
    var after = Drive(adPlan())
    after.ending = 110
    _ = after.read(119.9)
    #expect(after.read(120.0) == nil)               // the ending hands over; no second auto-next
    #expect(after.seek(125) == 125)
}

@Test func aTrailingAdJumpsToTheEndSoTheEngineFinishesTheItem() {
    var drive = Drive(adPlan("d-dir-ad-tail"))
    drive.duration = 190
    _ = drive.read(179.9)
    #expect(drive.read(180.0) == 190)
}

@Test func theEngineMustBePlayingThePlaylistThatWasRead() {
    var drive = Drive(adPlan())
    drive.duration = 260           // five seconds more than the plan: another reading, another ad
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == nil)
    #expect(drive.seek(125) == 125)
    drive.duration = 255.9         // within a second: the same playlist
    _ = drive.read(125.0)
    #expect(drive.read(125.1) == 135)
}

@Test func turningTheSwitchOffStopsSkippingAtOnce() {
    var drive = Drive(adPlan())
    drive.enabled = false
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == nil)
    #expect(drive.seek(125) == 125)
}

@Test func aSkipThatLandsShortOfItsTargetStopsThatEngineForTheItem() {
    var drive = Drive(adPlan(discontinuity: false))
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 135)
    #expect(drive.read(120.1, after: .seconds(4)) == nil)
    #expect(drive.skipper.suspensionReason == "landed-short-of-target")
    #expect(drive.skipper.activeTimeline(engine: .native, duration: 255, enabled: true) == nil)
    #expect(drive.seek(125) == 125)
    // The other engine plays the timeline differently; it has not failed yet.
    #expect(drive.skipper.activeTimeline(engine: .mpv, duration: 255, enabled: true) != nil)
}

@Test func aSkipThatLandsPastItsTargetStopsSkipping() {
    // A whole segment late is programme lost; it must not happen twice.
    var drive = Drive(adPlan())
    _ = drive.read(119.9)
    #expect(drive.read(120.0) == 135)
    #expect(drive.read(141.0) == nil)
    #expect(drive.skipper.suspensionReason == "landed-past-target")
}

@Test func aPlanForThePreviousItemIsNeverAdopted() {
    var skipper = HLSAdSkipper()
    let first = skipper.begin(url: mediaURL)
    let second = skipper.begin(url: URL(string: "https://cdn.example.com/show/ep2/index.m3u8")!)
    let staleAdopted = skipper.adopt(adPlan(), for: first)
    #expect(!staleAdopted)
    #expect(skipper.plan == nil)
    #expect(skipper.activeTimeline(engine: .native, duration: 255, enabled: true) == nil)
    let adopted = skipper.adopt(adPlan(), for: second)
    #expect(adopted)
    #expect(skipper.activeTimeline(engine: .native, duration: 255, enabled: true) != nil)
}

@Test func thePlanIsAskedForOnceAndOnlyOnceTheEngineHasOpenedTheMedia() {
    var skipper = HLSAdSkipper()
    let generation = skipper.begin(url: mediaURL)
    #expect(skipper.planRequest(enabled: true, duration: 0) == nil)
    #expect(skipper.planRequest(enabled: false, duration: 255) == nil)
    #expect(skipper.planRequest(enabled: true, duration: 255) == generation)
    #expect(skipper.planRequest(enabled: true, duration: 255) == nil)
}

@Test func anAddressThatIsNotHLSIsSettledBeforeAnythingHappens() {
    var skipper = HLSAdSkipper()
    _ = skipper.begin(url: URL(string: "https://cdn.example.com/a/movie.mp4")!)
    #expect(skipper.isSettled)
    #expect(skipper.planRequest(enabled: true, duration: 100) == nil)
    var hls = HLSAdSkipper()
    let generation = hls.begin(url: mediaURL)
    #expect(!hls.isSettled)
    hls.adopt(.init(timeline: .none, hasDiscontinuity: false), for: generation)
    #expect(hls.isSettled)          // read, and nothing to skip: the watch can stop
}

@Test func theWatchCanWakeExactlyAtTheNextBoundary() {
    let drive = Drive(adPlan())
    let skipper = drive.skipper
    #expect(skipper.secondsUntilNextRange(position: 118, rate: 2, engine: .native, duration: 255, enabled: true) == 1)
    #expect(skipper.secondsUntilNextRange(position: 125, rate: 1, engine: .native, duration: 255, enabled: true) == 0)
    #expect(skipper.secondsUntilNextRange(position: 140, rate: 1, engine: .native, duration: 255, enabled: true) == nil)
    #expect(skipper.secondsUntilNextRange(position: 118, rate: 0, engine: .native, duration: 255, enabled: true) == nil)
}

@Test func theWatchWakesMpvWhenItsDelayIsOver() {
    // Waking at the range's start would only read inside the delay; MPV's boundary is 0.25 s in.
    let skipper = Drive(adPlan()).skipper
    #expect(skipper.secondsUntilNextRange(position: 118, rate: 2, engine: .mpv, duration: 255, enabled: true) == 1.125)
    #expect(skipper.secondsUntilNextRange(position: 120, rate: 1, engine: .mpv, duration: 255, enabled: true) == 0.25)
    #expect(skipper.secondsUntilNextRange(position: 125, rate: 1, engine: .mpv, duration: 255, enabled: true) == 0)
    // Without discontinuities MPV's boundary is the range's start, as AVPlayer's is.
    let plain = Drive(adPlan(discontinuity: false)).skipper
    #expect(plain.secondsUntilNextRange(position: 118, rate: 2, engine: .mpv, duration: 255, enabled: true) == 1)
}

@Test func theSwitchIsOnUntilTheViewerTurnsItOff() {
    let defaults = UserDefaults(suiteName: "HLSAdSkipPreferenceTests-\(UUID().uuidString)")!
    let preference = HLSAdSkipPreference(defaults: defaults)
    #expect(preference.enabled)
    preference.setEnabled(false)
    #expect(!preference.enabled)
    preference.setEnabled(true)
    #expect(preference.enabled)
}
