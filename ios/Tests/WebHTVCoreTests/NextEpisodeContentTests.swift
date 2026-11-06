import Foundation
import Testing
@testable import WebHTVCore

/// W-243. What is fetched ahead for the next episode, what the rewritten playlist says, and every
/// source that is left to play exactly as before.

/// A source that answers from a table. `redirects` sends an address on to another one, the way
/// URLSession follows a 302 before the fetcher sees the answer.
private final class Source: @unchecked Sendable {
    var bodies = [String: Data]()
    var redirects = [String: String]()
    var status = [String: Int]()
    private(set) var asked = [String]()
    private let lock = NSLock()

    func text(_ address: String, _ body: String) { bodies[address] = Data(body.utf8) }

    var fetch: OfflineFetch {
        { request, limit in
            let asked = request.url!.absoluteString
            let address = self.redirects[asked] ?? asked
            self.lock.withLock { self.asked.append(asked) }
            let body = self.bodies[address] ?? Data()
            return OfflineHTTPResponse(data: body.prefix(limit), status: self.status[address] ?? (self.bodies[address] == nil ? 404 : 200),
                                       url: URL(string: address), headers: [:], truncated: body.count > limit)
        }
    }
}

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("w243-\(UUID().uuidString)", isDirectory: true)
}

private func media(_ count: Int, seconds: Double = 6, header: String = "", segment: (Int) -> String = { "seg\($0).ts" }) -> String {
    var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(Int(seconds))", "#EXT-X-MEDIA-SEQUENCE:40"]
    if !header.isEmpty { lines.append(header) }
    for index in 0..<count { lines += ["#EXTINF:\(seconds),", segment(index)] }
    lines.append("#EXT-X-ENDLIST")
    return lines.joined(separator: "\n")
}

private func run(_ source: Source, _ address: String, start: Double = 0, into dir: URL = folder()) async throws
    -> (NextEpisodeContent.Result, String, URL) {
    let result = try await NextEpisodeContent.fetch(URL(string: address)!, headers: ["Referer": "https://site.example/"],
                                                    startSeconds: start, into: dir, using: source.fetch)
    let text = try String(contentsOf: dir.appendingPathComponent(NextEpisodeContent.mediaPlaylist), encoding: .utf8)
    return (result, text, dir)
}

private func segmentLines(_ text: String) -> [String] { text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") } }

@Suite struct NextEpisodeContentTests {
    @Test func onlyTheFetchedSegmentsPointHomeAndEveryTagStays() async throws {
        let source = Source()
        let header = "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-START:TIME-OFFSET=0"
        source.text("https://cdn.example/v/index.m3u8", media(6, header: header))
        for index in 0..<6 { source.bodies["https://cdn.example/v/seg\(index).ts"] = Data(repeating: 1, count: 100) }
        let (result, text, dir) = try await run(source, "https://cdn.example/v/index.m3u8")

        // 6 + 6 + 6 reaches 15 seconds: three segments, and nothing else is fetched — not the key.
        #expect(result == .init(entry: NextEpisodeContent.mediaPlaylist, segments: 3, seconds: 18, bytes: 300))
        #expect(segmentLines(text) == ["s0.ts", "s1.ts", "s2.ts", "https://cdn.example/v/seg3.ts",
                                       "https://cdn.example/v/seg4.ts", "https://cdn.example/v/seg5.ts"])
        #expect(!source.asked.contains("https://cdn.example/v/key.bin"))
        #expect(text.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.example/v/key.bin\""))
        // The sequence is the IV of a key without one (RFC 8216 §5.2); nothing the source wrote is lost.
        for tag in ["#EXT-X-MEDIA-SEQUENCE:40", "#EXT-X-START:TIME-OFFSET=0", "#EXT-X-ENDLIST", "#EXT-X-TARGETDURATION:6"] {
            #expect(text.contains(tag))
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("s2.ts").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("s3.ts").path))
    }

    @Test func theFetchStartsWhereTheOpeningSkipLandsPlayback() async throws {
        let source = Source()
        source.text("https://cdn.example/index.m3u8", media(8))
        for index in 0..<8 { source.bodies["https://cdn.example/seg\(index).ts"] = Data([1]) }
        // 13 s is inside the third segment (12–18).
        let (result, text, _) = try await run(source, "https://cdn.example/index.m3u8", start: 13)
        #expect(Array(segmentLines(text)[0...5]) == ["https://cdn.example/seg0.ts", "https://cdn.example/seg1.ts",
                                                     "s2.ts", "s3.ts", "s4.ts", "https://cdn.example/seg5.ts"])
        #expect(result.segments == 3 && result.seconds == 18)
        #expect(NextEpisodeContent.firstSegment(try segments(media(3)), at: 12) == 2)
        #expect(NextEpisodeContent.firstSegment(try segments(media(3)), at: 18) == nil)
    }

    @Test func twentyMegabytesIsTheMostOneEpisodeCosts() async throws {
        let source = Source()
        source.text("https://cdn.example/index.m3u8", media(4))
        let big = NextEpisodeContent.byteLimit / 2 + 1
        for index in 0..<4 { source.bodies["https://cdn.example/seg\(index).ts"] = Data(count: big) }
        let (result, text, _) = try await run(source, "https://cdn.example/index.m3u8")
        #expect(result.segments == 1)
        #expect(segmentLines(text)[1] == "https://cdn.example/seg1.ts")

        // A first segment that alone is over the limit fetches nothing.
        source.bodies["https://cdn.example/seg0.ts"] = Data(count: NextEpisodeContent.byteLimit + 1)
        await #expect(throws: NextEpisodeContent.Skip.tooLarge) { _ = try await run(source, "https://cdn.example/index.m3u8") }
    }

    @Test func aRedirectedPlaylistResolvesAgainstWhereItCameFrom() async throws {
        let source = Source()
        source.redirects["https://site.example/play.m3u8"] = "https://cdn.example/real/index.m3u8"
        source.text("https://cdn.example/real/index.m3u8", media(4))
        for index in 0..<4 { source.bodies["https://cdn.example/real/seg\(index).ts"] = Data([1]) }
        let (_, text, _) = try await run(source, "https://site.example/play.m3u8")
        #expect(segmentLines(text).last == "https://cdn.example/real/seg3.ts")
    }

    @Test func aSingleVariantMasterGetsALocalMasterAndAnInitSectionComesWithItsSegments() async throws {
        let source = Source()
        source.text("https://cdn.example/master.m3u8",
                    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,CLOSED-CAPTIONS=NONE\nhd/index.m3u8\n")
        source.text("https://cdn.example/hd/index.m3u8", media(4, header: "#EXT-X-MAP:URI=\"init.mp4\"") { "seg\($0).m4s" })
        source.bodies["https://cdn.example/hd/init.mp4"] = Data([9])
        for index in 0..<4 { source.bodies["https://cdn.example/hd/seg\(index).m4s"] = Data([1]) }
        let (result, text, dir) = try await run(source, "https://cdn.example/master.m3u8")
        #expect(result.entry == NextEpisodeContent.masterPlaylist)
        let master = try String(contentsOf: dir.appendingPathComponent(NextEpisodeContent.masterPlaylist), encoding: .utf8)
        #expect(master == "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,CLOSED-CAPTIONS=NONE\nmedia.m3u8\n")
        #expect(text.contains("#EXT-X-MAP:URI=\"init0.mp4\""))
        #expect(segmentLines(text) == ["s0.m4s", "s1.m4s", "s2.m4s", "https://cdn.example/hd/seg3.m4s"])
        #expect(result.bytes == 4)
    }

    @Test(arguments: [
        ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nb.m3u8\n", NextEpisodeContent.Skip.multiVariant),
        ("#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"x\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"a\"\nv.m3u8\n", .renditionURIs),
        ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,URI=\"iframe.m3u8\"\n", .renditionURIs),
        ("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts\n", .live),
        ("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n", .encryption),
        ("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"skd://key\"\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n", .encryption),
        ("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\",KEYFORMAT=\"com.widevine\"\n#EXTINF:6,\nseg.ts\n#EXT-X-ENDLIST\n", .encryption),
        ("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n#EXT-X-BYTERANGE:100@0\nall.ts\n#EXT-X-ENDLIST\n", .byteRanges),
    ])
    func aPlaylistThisCannotRewriteSafelyIsLeftAlone(_ playlist: String, _ skip: NextEpisodeContent.Skip) async throws {
        let source = Source()
        source.text("https://cdn.example/index.m3u8", playlist)
        await #expect(throws: skip) { _ = try await run(source, "https://cdn.example/index.m3u8") }
        // Nothing past the playlists was fetched.
        #expect(source.asked.allSatisfy { $0.hasSuffix(".m3u8") })
    }

    @Test func anMP4CostsOneSmallReadAndIsLeftAlone() async throws {
        let source = Source()
        source.bodies["https://cdn.example/movie"] = Data(count: 5_000_000)
        await #expect(throws: NextEpisodeContent.Skip.notHLS) { _ = try await run(source, "https://cdn.example/movie") }
        #expect(source.asked.count == 1)
    }

    @Test func onlyKkyssAdStrippedListIsTakenFromTheLocalProxy() {
        let kkys = URL(string: "http://127.0.0.1:52000/tok/proxy?do=py&type=adm3u8&url=https%3A%2F%2Fcdn.example%2Fi.m3u8")!
        #expect(NextEpisodeContent.eligible(kkys) == nil)
        #expect(NextEpisodeContent.eligible(URL(string: "http://127.0.0.1:52000/tok/proxy?do=py&type=mpd&url=x")!) == .localProxy)
        #expect(NextEpisodeContent.eligible(URL(string: "http://127.0.0.1:52000/tok/proxy?do=py&vid=1")!) == .localProxy)
        #expect(NextEpisodeContent.eligible(URL(string: "https://cdn.example/i.m3u8")!) == nil)
    }

    /// kkys (`kkys.py` `_ad_answer`): the master's one variant is itself a proxy address, and the
    /// variant comes back ad-stripped with absolute segment addresses. When the cache misses and the
    /// source fails, `localProxy` answers 302 to the original, unstripped list — which is what the
    /// player would have played anyway.
    @Test(arguments: [false, true])
    func kkyssListIsFetchedThroughTheProxyAndItsFallbackStillWorks(redirected: Bool) async throws {
        let source = Source()
        let proxy = "http://127.0.0.1:52000/tok/proxy?do=py&type=adm3u8&url="
        let original = "https://cdn.example/k/index.m3u8"
        if redirected {
            source.redirects[proxy + "m"] = original
            source.text(original, media(5))
        } else {
            source.text(proxy + "m", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n\(proxy)v\n")
            // Stripped: segment 1 (an ad) is gone, the rest are absolute.
            source.text(proxy + "v", media(4) { "https://cdn.example/k/seg\($0 == 0 ? 0 : $0 + 1).ts" })
        }
        for index in 0..<6 { source.bodies["https://cdn.example/k/seg\(index).ts"] = Data([1]) }
        let (result, text, _) = try await run(source, proxy + "m")
        #expect(result.segments == 3)
        let remote = segmentLines(text).filter { $0.hasPrefix("http") }
        if redirected {
            #expect(remote == ["https://cdn.example/k/seg3.ts", "https://cdn.example/k/seg4.ts"])
        } else {
            #expect(result.entry == NextEpisodeContent.masterPlaylist)
            #expect(remote == ["https://cdn.example/k/seg4.ts"])
            // The ad the proxy removed is not fetched and does not come back.
            #expect(!source.asked.contains("https://cdn.example/k/seg1.ts"))
        }
    }

    /// W-243 review C3, C3a, C4.
    @Test func onlyTheSourceFailingNearTheCopyIsResolvedAgain() {
        let network = PlaybackFailure.network("HTTP 403")
        let codec = PlaybackFailure.engineCapability("unsupported")
        #expect(NextEpisodeContent.copyFailure(network, position: 12, until: 46, started: true) == .recover)
        #expect(NextEpisodeContent.copyFailure(network, position: 0, until: 46, started: false) == .recover)
        // Thirty minutes in, the retry the copy kept must not reopen the episode from its start.
        #expect(NextEpisodeContent.copyFailure(network, position: 1800, until: 46, started: true) == .dropRetry)
        // A codec goes to MPV first, as it always did; once playing, without the copy's retry.
        #expect(NextEpisodeContent.copyFailure(codec, position: 5, until: 46, started: true) == .dropRetry)
        #expect(NextEpisodeContent.copyFailure(codec, position: 0, until: 46, started: false) == .keep)
    }

    @Test func aFailedFirstSegmentFetchesNothingAndALaterOneEndsTheRun() async throws {
        let source = Source()
        source.text("https://cdn.example/index.m3u8", media(4))
        source.bodies["https://cdn.example/seg0.ts"] = Data([1])
        // seg1 is missing: 404.
        let (result, text, _) = try await run(source, "https://cdn.example/index.m3u8")
        #expect(result.segments == 1)
        #expect(segmentLines(text)[1] == "https://cdn.example/seg1.ts")

        source.bodies["https://cdn.example/seg0.ts"] = nil
        await #expect(throws: NextEpisodeContent.Skip.failed("HTTP 404")) { _ = try await run(source, "https://cdn.example/index.m3u8") }
    }
}

private func segments(_ text: String) throws -> [HLSSegment] {
    guard case .media(let media) = try HLSPlaylist.parse(text, base: URL(string: "https://cdn.example/")!) else { return [] }
    return media.segments
}
