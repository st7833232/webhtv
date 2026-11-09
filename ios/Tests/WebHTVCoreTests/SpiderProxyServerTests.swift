#if canImport(Network)
import Foundation
import Testing
@testable import WebHTVCore
#if canImport(AVFoundation)
import AVFoundation
#endif

/// W-202: the loopback `localProxy` server — range splitting, HEAD, the stream's head, disconnects,
/// timeouts, the token and the 9978 rewrite. The spider and the connection are stand-ins.
struct SpiderProxyServerTests {
    static let seg = SpiderProxyServer.segment

    /// A spider serving `total` bytes (`byte(i) = i % 251`) that answers Range with 206, or ignores it.
    final class Media: SpiderProxying, @unchecked Sendable {
        let total: Int64
        let honoursRange: Bool
        /// py/哔哩.py answers a bare `[206, mime, body]`: the range, but no Content-Range.
        let bare: Bool
        let delay: Duration
        private let lock = NSLock()
        private var asked = [String]()
        var ranges: [String] { lock.withLock { asked } }

        init(total: Int64, honoursRange: Bool = true, bare: Bool = false, delay: Duration = .zero) {
            self.total = total
            self.honoursRange = honoursRange
            self.bare = bare
            self.delay = delay
        }

        static func bytes(_ range: ClosedRange<Int64>) -> Data { Data(range.map { UInt8($0 % 251) }) }

        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            lock.withLock { asked.append(params["range"] ?? "") }
            if delay > .zero { try await Task.sleep(for: delay) }
            guard honoursRange, let window = SpiderProxyServer.window(params["range"]) else {
                return SpiderProxyResponse(status: 200, mime: "video/mp4", body: Self.bytes(0...(total - 1)))
            }
            let end = min(window.end ?? total - 1, total - 1)
            guard window.start <= end else { return SpiderProxyResponse(status: 206, mime: "video/mp4", body: Data()) }
            return SpiderProxyResponse(status: 206, mime: "video/mp4",
                                       headers: bare ? [:] : ["Content-Range": "bytes \(window.start)-\(end)/\(total)"],
                                       body: Self.bytes(window.start...end))
        }
    }

    /// The player's side: everything written, and a connection that can drop after `dropAfter` writes.
    actor Sink: ProxyWriting {
        var head = ""
        var body = Data()
        var writes = 0
        var closed = false
        let dropAfter: Int?
        init(dropAfter: Int? = nil) { self.dropAfter = dropAfter }

        func write(head: Data?, body: Data?, more: Bool) async -> Bool {
            writes += 1
            if let head { self.head += String(decoding: head, as: UTF8.self) }
            if let body { self.body.append(body) }
            if !more { closed = true }
            return dropAfter.map { writes < $0 } ?? true
        }

        func close() async { closed = true }
        func header(_ name: String) -> String? {
            head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
    }

    func run(_ method: String = "GET", range: String?, media: Media, sink: Sink = Sink(),
             server: SpiderProxyServer = SpiderProxyServer()) async -> Sink {
        var params = ["do": "py", "type": "media"]
        params["range"] = range
        await server.handle(.init(method: method, params: params), target: media, writer: sink)
        return sink
    }

    @Test func anOpenEndedRangeIsAskedInSegmentsAndStreamedAsOne() async {
        let total = 2 * Self.seg + 1000
        let media = Media(total: total)
        let sink = await run(range: "bytes=0-", media: media)
        #expect(media.ranges == ["bytes=0-\(Self.seg - 1)", "bytes=\(Self.seg)-\(2 * Self.seg - 1)",
                                 "bytes=\(2 * Self.seg)-\(total - 1)"])
        #expect(await sink.head.hasPrefix("HTTP/1.1 206 Partial Content"))
        #expect(await sink.header("Content-Length") == String(total))
        #expect(await sink.header("Content-Range") == "bytes 0-\(total - 1)/\(total)")
        #expect(await sink.header("Accept-Ranges") == "bytes")
        #expect(await sink.body == Media.bytes(0...(total - 1)))
        #expect(await sink.closed)
    }

    @Test func noRangeIsTheWholeFileAsA200() async {
        let media = Media(total: Self.seg + 10)
        let sink = await run(range: nil, media: media)
        #expect(media.ranges.first == "bytes=0-\(Self.seg - 1)")
        #expect(await sink.head.hasPrefix("HTTP/1.1 200 OK"))
        #expect(await sink.header("Content-Length") == String(Self.seg + 10))
        #expect(await sink.header("Content-Range") == nil)
        #expect(await sink.body.count == Int(Self.seg + 10))
    }

    @Test func aLargeBoundedRangeIsSplitAndReportedAsAsked() async {
        let total = 3 * Self.seg
        let media = Media(total: total)
        let start: Int64 = 1000, end = 2 * Self.seg + 5
        let sink = await run(range: "bytes=\(start)-\(end)", media: media)
        #expect(media.ranges.count == 2)
        #expect(media.ranges.last == "bytes=\(start + Self.seg)-\(end)")
        #expect(await sink.header("Content-Range") == "bytes \(start)-\(end)/\(total)")
        #expect(await sink.header("Content-Length") == String(end - start + 1))
        #expect(await sink.body == Media.bytes(start...end))
    }

    @Test func aSmallRangeGoesToTheSpiderUnchanged() async {
        let media = Media(total: 5000)
        let sink = await run(range: "bytes=10-99", media: media)
        #expect(media.ranges == ["bytes=10-99"])
        #expect(await sink.head.hasPrefix("HTTP/1.1 206"))
        #expect(await sink.body == Media.bytes(10...99))
    }

    @Test func aWholeMP4StillHonoursThePlayersOpenEndedRange() async {
        let media = Media(total: 3000, honoursRange: false)
        let sink = await run(range: "bytes=0-", media: media)
        #expect(media.ranges.count == 1)
        #expect(await sink.head.hasPrefix("HTTP/1.1 206"))
        #expect(await sink.header("Content-Length") == "3000")
        #expect(await sink.header("Content-Range") == "bytes 0-2999/3000")
        #expect(await sink.header("Accept-Ranges") == "bytes")
    }

    @Test func aWholeMP4AnswersTheNativeTwoByteProbe() async {
        let media = Media(total: 3000, honoursRange: false)
        let sink = await run(range: "bytes=0-1", media: media)
        #expect(await sink.head.hasPrefix("HTTP/1.1 206"))
        #expect(await sink.header("Content-Length") == "2")
        #expect(await sink.header("Content-Range") == "bytes 0-1/3000")
        #expect(await sink.body == Media.bytes(0...1))
    }

    @Test(arguments: ["bytes=1200-1299", "bytes=2990-9999", "bytes=-10"])
    func aWholeMP4CanSeekAndClampToItsEnd(range: String) async {
        let media = Media(total: 3000, honoursRange: false)
        let sink = await run(range: range, media: media)
        let bounds = OfflineMediaServer.byteRange(range, size: 3000)!
        #expect(await sink.head.hasPrefix("HTTP/1.1 206"))
        #expect(await sink.header("Content-Range") == "bytes \(bounds.lowerBound)-\(bounds.upperBound)/3000")
        #expect(await sink.body == Media.bytes(bounds))
    }

    @Test(arguments: ["bytes=3000-", "bytes=-0", "bytes=-1-2", "bytes=0-nope"])
    func aWholeMP4RejectsAnUnsatisfiableOrInvalidRange(range: String) async {
        let sink = await run(range: range, media: Media(total: 3000, honoursRange: false))
        #expect(await sink.head.hasPrefix("HTTP/1.1 416"))
        #expect(await sink.header("Content-Range") == "bytes */3000")
        #expect(await sink.body.isEmpty)
    }

    @Test func headOfAWholeMP4SaysItsSizeWithoutSendingIt() async {
        let sink = await run("HEAD", range: nil, media: Media(total: 3000, honoursRange: false))
        #expect(await sink.head.hasPrefix("HTTP/1.1 200"))
        #expect(await sink.header("Content-Length") == "3000")
        #expect(await sink.header("Accept-Ranges") == "bytes")
        #expect(await sink.body.isEmpty)
    }

    @Test func aWholeMP4WithoutARangeStillReturnsTheWholeFile() async {
        let sink = await run(range: nil, media: Media(total: 3000, honoursRange: false))
        #expect(await sink.head.hasPrefix("HTTP/1.1 200"))
        #expect(await sink.header("Content-Range") == nil)
        #expect(await sink.body == Media.bytes(0...2999))
    }

    @Test func rangeAdaptationLeavesErrorsManifestsAndRealPartialResponsesUntouched() {
        for answer in [
            SpiderProxyResponse(status: 403, mime: "video/mp4", body: Data("forbidden".utf8)),
            SpiderProxyResponse(status: 200, mime: "application/dash+xml", body: Data("<MPD/>".utf8)),
            SpiderProxyResponse(status: 206, mime: "video/mp4", headers: ["Content-Range": "bytes 5-6/100"], body: Data([5, 6])),
            SpiderProxyResponse(status: 200, mime: "video/mp4", headers: ["Content-Encoding": "gzip"], body: Data([1, 2, 3])),
        ] {
            #expect(SpiderProxyServer.rangedMP4(answer, range: "bytes=0-1") == answer)
        }
    }

    struct Fixed: SpiderProxying {
        let response: SpiderProxyResponse
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? { response }
    }

    /// W-245: a whole episode is noted under the address it was asked by — and only one that really was
    /// a whole `200 video/mp4`, on any of the three paths that serve one in ranges.
    @Test func aWholeEpisodeIsNotedByTheAddressItWasAskedBy() async {
        let server = SpiderProxyServer()
        let whole = SpiderProxyResponse(status: 200, mime: "video/mp4", body: Media.bytes(0...99))
        // The small-window path (a two-byte probe), the HEAD path and the "ignores Range" open-ended path.
        await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-1"], query: "do=py&vid=1"),
                            target: Fixed(response: whole), writer: Sink())
        await server.handle(.init(method: "HEAD", params: ["do": "py"], query: "do=py&vid=2"),
                            target: Fixed(response: whole), writer: Sink())
        await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-"], query: "do=py&vid=3"),
                            target: Fixed(response: whole), writer: Sink())
        // The same spider, another address that is not a whole MP4: a real 206, a manifest, an error.
        for (vid, answer) in [
            ("4", SpiderProxyResponse(status: 206, mime: "video/mp4", headers: ["Content-Range": "bytes 0-1/100"], body: Data([0, 1]))),
            ("5", SpiderProxyResponse(status: 200, mime: "application/vnd.apple.mpegurl", body: Data("#EXTM3U".utf8))),
            ("6", SpiderProxyResponse(status: 403, mime: "video/mp4", body: Data("no".utf8))),
        ] {
            await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-1"], query: "do=py&vid=\(vid)"),
                                target: Fixed(response: answer), writer: Sink())
        }
        func bytes(_ vid: String) -> Int64? {
            server.wholeMP4Bytes(of: URL(string: "http://127.0.0.1:9/token/proxy?do=py&vid=\(vid)")!)
        }
        #expect(bytes("1") == 100 && bytes("2") == 100 && bytes("3") == 100)
        #expect(bytes("4") == nil && bytes("5") == nil && bytes("6") == nil)
        #expect(bytes("7") == nil, "never asked")
    }

    // W-262: a whole episode whose video is ByteVC2 opens on MPV next time; H.264 and a real 206 do not.
    @Test func aWholeByteVC2EpisodeIsMarkedForMPV() async {
        let server = SpiderProxyServer()
        let bvc2 = MP4Fixture.file([MP4Fixture.track(handler: "soun", entry: "mp4a"), MP4Fixture.track(handler: "vide", entry: "bvc2")])
        let avc1 = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "avc1")])
        for (vid, answer) in [
            ("1", SpiderProxyResponse(status: 200, mime: "video/mp4", body: bvc2)),
            ("2", SpiderProxyResponse(status: 200, mime: "video/mp4", body: avc1)),
            ("3", SpiderProxyResponse(status: 206, mime: "video/mp4", headers: ["Content-Range": "bytes 0-1/\(bvc2.count)"], body: bvc2.prefix(2))),
        ] {
            await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-1"], query: "do=py&vid=\(vid)"),
                                target: Fixed(response: answer), writer: Sink())
        }
        func mpv(_ vid: String) -> Bool { server.prefersMPV(URL(string: "http://127.0.0.1:9/token/proxy?do=py&vid=\(vid)")!) }
        #expect(mpv("1"))
        #expect(!mpv("2") && !mpv("3") && !mpv("4"))
        // The same file answered again as H.264 (another quality behind the same address) is no longer marked.
        await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-1"], query: "do=py&vid=1"),
                            target: Fixed(response: SpiderProxyResponse(status: 200, mime: "video/mp4", body: avc1)), writer: Sink())
        #expect(!mpv("1"))
    }

    /// W-262 (Ponytail): with 16 episodes noted, a further range of the one playing must not clear its own mark.
    @Test func theSixteenthEpisodeKeepsItsVVCMarkAcrossItsOwnRanges() async {
        let server = SpiderProxyServer()
        let bvc2 = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "bvc2")])
        let avc1 = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "avc1")])
        func ask(_ vid: Int, _ body: Data) async {
            await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-1"], query: "do=py&vid=\(vid)"),
                                target: Fixed(response: SpiderProxyResponse(status: 200, mime: "video/mp4", body: body)), writer: Sink())
        }
        for vid in 1...15 { await ask(vid, avc1) }
        await ask(16, bvc2)
        await ask(16, bvc2) // the player's next range of the same episode
        #expect(server.prefersMPV(URL(string: "http://127.0.0.1:9/token/proxy?do=py&vid=16")!))
    }

    // W-262: what the shared proxy learned decides the engine of the next open of that address.
    @Test func aByteVC2EpisodeTheSharedProxyServedOpensOnMPV() async {
        let query = "do=py&vid=w262-\(UUID().uuidString)"
        let url = URL(string: "http://127.0.0.1:9/\(SpiderProxyServer.shared.token)/proxy?\(query)")!
        #expect(!PlayerRouter.needsMPV(url))
        let bvc2 = MP4Fixture.file([MP4Fixture.track(handler: "vide", entry: "bvc2")])
        await SpiderProxyServer.shared.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-1"], query: query),
                                              target: Fixed(response: SpiderProxyResponse(status: 200, mime: "video/mp4", body: bvc2)),
                                              writer: Sink())
        #expect(PlayerRouter.needsMPV(url))
    }

    @Test func aWholeMP4DoesNotOverrideIfRange() async {
        let source = SpiderProxyResponse(status: 200, mime: "video/mp4", headers: ["ETag": #""new""#], body: Media.bytes(0...99))
        let sink = Sink()
        await SpiderProxyServer().handle(.init(method: "GET", params: ["do": "py", "range": "bytes=10-19", "if-range": #""old""#]),
                                         target: Fixed(response: source), writer: sink)
        #expect(await sink.head.hasPrefix("HTTP/1.1 200"))
        #expect(await sink.header("Content-Range") == nil)
        #expect(await sink.header("ETag") == #""new""#)
        #expect(await sink.body == source.body)
    }

    @Test func aWholeMP4IgnoresUnknownRangeUnits() async {
        let sink = await run(range: "items=0-1", media: Media(total: 100, honoursRange: false))
        #expect(await sink.head.hasPrefix("HTTP/1.1 200"))
        #expect(await sink.header("Content-Range") == nil)
        #expect(await sink.body == Media.bytes(0...99))
    }

    @Test(arguments: ["bytes=0-9223372036854775807", "bytes=9223372036854775807-"])
    func aWholeMP4HandlesInt64RangeBoundariesWithoutOverflow(range: String) async {
        let sink = await run(range: range, media: Media(total: 100, honoursRange: false))
        if range.hasPrefix("bytes=0-") {
            #expect(await sink.head.hasPrefix("HTTP/1.1 206"))
            #expect(await sink.body == Media.bytes(0...99))
        } else {
            #expect(await sink.head.hasPrefix("HTTP/1.1 416"))
            #expect(await sink.body.isEmpty)
        }
    }

    final class WholeFile: SpiderRuntime, @unchecked Sendable {
        let data: Data
        init(_ data: Data) { self.data = data }
        func initialize(extend: String) async throws {}
        func homeContent(filter: Bool) async throws -> String { "{}" }
        func categoryContent(tid: String, page: String, filter: Bool, extend: [String: String]) async throws -> String { "{}" }
        func detailContent(ids: [String]) async throws -> String { "{}" }
        func searchContent(key: String, quick: Bool, page: String) async throws -> String { "{}" }
        func playerContent(flag: String, id: String, vipFlags: [String]) async throws -> String { "{}" }
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            SpiderProxyResponse(status: 200, mime: "video/mp4", body: data)
        }
    }

    #if canImport(AVFoundation)
    /// Opt-in real AVFoundation check. The fixture is generated locally, never downloaded drama content.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEBHTV_NATIVE_PROXY_MP4"] != nil))
    @MainActor func nativePlayerPlaysAndSeeksAWholeFileSpider() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["WEBHTV_NATIVE_PROXY_MP4"])
        let file = try Data(contentsOf: URL(fileURLWithPath: path))
        let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"whole","name":"whole","type":3,"api":"./whole.py"}"#.utf8))
        let session = SpiderSession(site: site, runtime: WholeFile(file))
        let server = SpiderProxyServer()
        let address = try #require(await server.serve("http://127.0.0.1:9978/proxy?do=py&vid=123", for: session, dash: false))
        let url = try #require(URL(string: address))
        #expect(!PlayerRouter.needsMPV(url))
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline && item.status != .failed && player.currentTime().seconds < 0.2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        #expect(player.currentTime().seconds >= 0.2)
        let sought = await player.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(sought)
        #expect(player.currentTime().seconds >= 0.9)
    }
    #endif

    @Test func aBare206IsReadOnUntilAShortAnswerWithNoLength() async {
        let total = 2 * Self.seg + 777
        let media = Media(total: total, bare: true)
        let sink = await run(range: nil, media: media)
        #expect(media.ranges.count == 3) // nothing asked past the short last answer
        #expect(await sink.head.hasPrefix("HTTP/1.1 200 OK"))
        #expect(await sink.header("Content-Length") == nil)
        #expect(await sink.header("Accept-Ranges") == "bytes")
        #expect(await sink.body == Media.bytes(0...(total - 1)))
        #expect(await sink.closed)
    }

    @Test func aSeekIntoABare206StreamStartsThere() async {
        let total = 3 * Self.seg
        let media = Media(total: total, bare: true)
        let start = Self.seg + 12345
        let sink = await run(range: "bytes=\(start)-", media: media)
        #expect(media.ranges.first == "bytes=\(start)-\(start + Self.seg - 1)")
        #expect(await sink.head.hasPrefix("HTTP/1.1 206"))
        #expect(await sink.body == Media.bytes(start...(total - 1)))
    }

    @Test func aBare206OfWholeSegmentsEndsAtTheEmptyAnswer() async {
        let media = Media(total: 2 * Self.seg, bare: true)
        let sink = await run(range: nil, media: media)
        #expect(media.ranges.count == 3)
        #expect(await sink.body == Media.bytes(0...(2 * Self.seg - 1)))
    }

    /// A spider that answers the first segment properly, then `later` for every segment after it.
    final class Drifting: SpiderProxying, @unchecked Sendable {
        let media: Media
        let later: SpiderProxyResponse
        init(total: Int64, bare: Bool = false, later: SpiderProxyResponse) {
            media = Media(total: total, bare: bare)
            self.later = later
        }
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            media.ranges.isEmpty ? try await media.proxy(params: params) : later
        }
    }

    @Test(arguments: [
        SpiderProxyResponse(status: 200, mime: "video/mp4", body: Media.bytes(0...99)),
        SpiderProxyResponse(status: 206, mime: "video/mp4", headers: ["Content-Range": "bytes 0-99/999999999"],
                            body: Media.bytes(0...99)),
    ])
    func aLaterSegmentThatIsNotTheNextBytesEndsTheStream(later: SpiderProxyResponse) async {
        let spider = Drifting(total: 3 * Self.seg, later: later)
        let sink = Sink()
        await SpiderProxyServer().handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-"]),
                                         target: spider, writer: sink)
        #expect(await sink.body == Media.bytes(0...(Self.seg - 1)))
        #expect(await sink.closed)
    }

    @Test func headAsksForOneByteAndSendsNoBody() async {
        let media = Media(total: 9 * Self.seg)
        let sink = await run("HEAD", range: nil, media: media)
        #expect(media.ranges == ["bytes=0-0"])
        #expect(await sink.header("Content-Length") == String(9 * Self.seg))
        #expect(await sink.header("Accept-Ranges") == "bytes")
        #expect(await sink.body.isEmpty)
    }

    @Test func aPlayerThatLeavesStopsTheSegments() async {
        let media = Media(total: 5 * Self.seg)
        _ = await run(range: "bytes=0-", media: media, sink: Sink(dropAfter: 1))
        #expect(media.ranges.count == 1)
    }

    @Test func aSpiderThatTakesTooLongIsA504() async {
        let server = SpiderProxyServer()
        server.callTimeout = .milliseconds(50)
        let sink = await run(range: "bytes=0-", media: Media(total: 100, delay: .seconds(5)), server: server)
        #expect(await sink.head.hasPrefix("HTTP/1.1 504"))
    }

    /// W-252: a slow spider answering one fixed response, counting how often it is asked.
    final class Slow: SpiderProxying, @unchecked Sendable {
        let response: SpiderProxyResponse
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        init(_ response: SpiderProxyResponse) { self.response = response }
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            lock.withLock { calls += 1 }
            try await Task.sleep(for: .milliseconds(300))
            return response
        }
    }

    /// The native probe, then MPV's open while the cold script still runs: one script call, both answered.
    @Test(arguments: [SpiderProxyResponse(status: 500, mime: "text/plain", body: Data("failed".utf8)),
                      SpiderProxyResponse(status: 200, mime: "video/mp4", body: Media.bytes(0...2999))])
    func aRequestJoinsTheSameFileAlreadyBeingAnswered(answer: SpiderProxyResponse) async {
        let server = SpiderProxyServer()
        let spider = Slow(answer)
        let probe = Sink(), open = Sink()
        async let first: Void = server.handle(.init(method: "GET", params: ["do": "py", "vid": "1", "range": "bytes=0-1"]),
                                              target: spider, writer: probe)
        try? await Task.sleep(for: .milliseconds(100))
        await server.handle(.init(method: "GET", params: ["do": "py", "vid": "1", "range": "bytes=0-524287"]),
                            target: spider, writer: open)
        await first
        #expect(spider.count == 1)
        let status = answer.status == 500 ? "HTTP/1.1 500" : "HTTP/1.1 206"
        #expect(await probe.head.hasPrefix(status))
        #expect(await open.head.hasPrefix(status))
        if answer.status == 200 { #expect(await open.body == Media.bytes(0...2999)) }
        // Once answered, the next request asks the spider again: a passing failure gets its retry (W-246).
        await server.handle(.init(method: "GET", params: ["do": "py", "vid": "1", "range": "bytes=0-1"]),
                            target: spider, writer: Sink())
        #expect(spider.count == 2)
    }

    /// W-252 review C1: a call that answers without ever suspending must not stay noted — every later
    /// request for the same file asks the spider again, whether it failed or threw.
    final class Instant: SpiderProxying, @unchecked Sendable {
        let throwing: Bool
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        init(throwing: Bool) { self.throwing = throwing }
        struct Failure: Error {}
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            lock.withLock { calls += 1 }
            if throwing { throw Failure() }
            return SpiderProxyResponse(status: 500, mime: "text/plain", body: Data("failed".utf8))
        }
    }

    @Test(arguments: [false, true])
    func anAnswerAtOnceIsNeverReusedByTheNextRequest(throwing: Bool) async {
        let server = SpiderProxyServer()
        let spider = Instant(throwing: throwing)
        for _ in 0..<300 {
            await server.handle(.init(method: "GET", params: ["do": "py", "vid": "1", "range": "bytes=0-1"]),
                                target: spider, writer: Sink())
        }
        #expect(spider.count == 300)
    }

    /// A spider serving real ranges answers each one itself; another file is never joined.
    @Test func aRangeAnswerIsNotSharedWithAnotherRangeOrFile() async {
        let server = SpiderProxyServer()
        let media = Media(total: 3000, delay: .milliseconds(300))
        let a = Sink(), b = Sink()
        async let first: Void = server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-9"]),
                                              target: media, writer: a)
        try? await Task.sleep(for: .milliseconds(100))
        await server.handle(.init(method: "GET", params: ["do": "py", "range": "bytes=10-19"]), target: media, writer: b)
        await first
        #expect(await a.body == Media.bytes(0...9))
        #expect(await b.body == Media.bytes(10...19))
        #expect(media.ranges.count == 2)
    }

    /// googlevideo's 403 to a reader too far ahead, relayed by the spider once, then the bytes.
    final class Refusing: SpiderProxying, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            let first = lock.withLock { calls += 1; return calls == 1 }
            return first ? SpiderProxyResponse(status: 403, mime: "text/plain", body: Data())
                : SpiderProxyResponse(status: 206, mime: "video/mp4", headers: ["Content-Range": "bytes 0-9/10"],
                                      body: Media.bytes(0...9))
        }
    }

    @Test func a403IsRelayedOnceNotRetried() async {
        let spider = Refusing()
        let sink = Sink()
        await SpiderProxyServer().handle(.init(method: "GET", params: ["do": "py", "range": "bytes=0-9"]),
                                         target: spider, writer: sink)
        #expect(spider.count == 1)
        #expect(await sink.head.hasPrefix("HTTP/1.1 403"))
    }

    @Test func onlyTheTokenPathParsesAndHeadersJoinTheQuery() {
        let token = "abc"
        let head = "GET /abc/proxy?do=py&type=mpd&vid=x HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-"
        let request = SpiderProxyServer.parse(head, token: token)
        #expect(request?.params["type"] == "mpd")
        #expect(request?.params["range"] == "bytes=0-")
        #expect(SpiderProxyServer.parse("GET /wrong/proxy?do=py HTTP/1.1", token: token) == nil)
        #expect(SpiderProxyServer.parse("GET /proxy?do=py HTTP/1.1", token: token) == nil)
        #expect(SpiderProxyServer.parse("POST /abc/proxy HTTP/1.1", token: token) == nil)
    }

    @Test func androidsAddressIsRewrittenInPlayAddressesAndText() {
        let base = URL(string: "http://127.0.0.1:5555/tok/")!
        let mpd = "<BaseURL>http://127.0.0.1:9978/proxy?do=py&amp;type=media</BaseURL>"
        #expect(SpiderProxyServer.rewrite(mpd, base: base)
                == "<BaseURL>http://127.0.0.1:5555/tok/proxy?do=py&amp;type=media</BaseURL>")
        #expect(SpiderProxyServer.isText("application/dash+xml") && !SpiderProxyServer.isText("video/mp4"))
    }

    /// A fragmented MP4 of `total` bytes: `ftyp`, then a `sidx` whose two references reach the last byte.
    static func indexedFile(total: Int64) -> Data {
        func be(_ value: Int64, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(value >> (8 * $0) & 0xff) } }
        let head = be(16, 4) + Array("ftypisom".utf8) + be(0, 4)
        let sidx = be(56, 4) + Array("sidx".utf8) + be(0, 4) + be(1, 4) + be(1000, 4) + be(0, 4) + be(0, 4) + be(0, 2)
            + be(2, 2) + be(Self.seg, 4) + be(4000, 4) + be(0, 4) + be(total - 72 - Self.seg, 4) + be(2000, 4) + be(0, 4)
        return Data(head + sidx) + Media.bytes(72...(total - 1))
    }

    /// py/哔哩.py serving such a file: bare 206 answers, no Content-Range.
    final class Indexed: SpiderProxying, @unchecked Sendable {
        let file: Data
        /// YouTube｜PY says the range it answers; py/哔哩.py does not.
        let says: Bool
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        init(_ file: Data, says: Bool = false) { self.file = file; self.says = says }
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            lock.withLock { count += 1 }
            let window = SpiderProxyServer.window(params["range"])!
            let end = min(Int(window.end ?? Int64(file.count - 1)), file.count - 1)
            return SpiderProxyResponse(status: 206, mime: "video/mp4",
                                       headers: says ? ["Content-Range": "bytes \(window.start)-\(end)/\(file.count)"] : [:],
                                       body: Int(window.start) > end ? Data() : file[Int(window.start)...end])
        }
    }

    @Test func aBareMP4TellsItsSizeThroughItsIndexSoASeekLands() async {
        let total = 3 * Self.seg + 10
        let file = Self.indexedFile(total: total)
        #expect(SpiderProxyServer.sidxTotal(file) == total)
        #expect(SpiderProxyServer.sidxTotal(Media.bytes(0...4095)) == nil)
        let server = SpiderProxyServer(), spider = Indexed(file)
        let whole = Sink()
        await server.handle(.init(method: "GET", params: ["do": "py", "url": "a", "range": "bytes=0-"]),
                            target: spider, writer: whole)
        #expect(await whole.header("Content-Length") == String(total))
        #expect(await whole.body == file)
        let start = 2 * Self.seg + 5
        let seek = Sink()
        await server.handle(.init(method: "GET", params: ["do": "py", "url": "a", "range": "bytes=\(start)-"]),
                            target: spider, writer: seek)
        #expect(await seek.header("Content-Range") == "bytes \(start)-\(total - 1)/\(total)")
        #expect(await seek.body == file[Int(start)...])
    }

    @Test func aSegmentBaseFileIsListedByItsIndexAndItsPartsSayWhereTheyAre() async {
        let total = 3 * Self.seg + 10
        let spider = Indexed(Self.indexedFile(total: total)), server = SpiderProxyServer()
        let address = "http://127.0.0.1:1/t/proxy?do=py&amp;url=a"
        func manifest(_ inside: String, set: String = "") -> String {
            "<MPD><Period><AdaptationSet mimeType=\"video/mp4\">\(set)<Representation id=\"v\"><BaseURL>\(address)</BaseURL>"
                + inside + "</Representation></AdaptationSet></Period></MPD>"
        }
        let listed = await server.segmentLists(manifest("<SegmentBase indexRange=\"16-71\"><Initialization range=\"0-15\"/></SegmentBase>"),
                                               base: URL(string: "http://127.0.0.1:1/t/")!, target: spider)
        #expect(listed == manifest(
            "<SegmentList timescale=\"1000\"><Initialization range=\"0-15\"/><SegmentURL mediaRange=\"72-\(71 + Self.seg)\"/>"
                + "<SegmentURL mediaRange=\"\(72 + Self.seg)-\(total - 1)\"/></SegmentList>",
            set: "<SegmentList timescale=\"1000\"><SegmentTimeline><S d=\"4000\"/><S d=\"2000\"/></SegmentTimeline></SegmentList>"))
        let ranged = await SpiderProxyServer().segmentLists(
            manifest("<SegmentBase indexRange=\"16-71\"><Initialization range=\"0-15\"/></SegmentBase>"),
            base: URL(string: "http://127.0.0.1:1/t/")!, target: Indexed(Self.indexedFile(total: total), says: true))
        #expect(ranged == manifest("<SegmentBase indexRange=\"16-71\"><Initialization range=\"0-15\"/></SegmentBase>"))
        let calls = spider.calls
        #expect(await server.segmentLists(manifest("<SegmentBase indexRange=\"16-71\"><Initialization range=\"0-15\"/></SegmentBase>"),
                                          base: URL(string: "http://127.0.0.1:1/t/")!, target: spider) == listed)
        #expect(spider.calls == calls) // the second read of the manifest asks the spider nothing
        let part = Sink()
        await server.handle(.init(method: "GET", params: ["do": "py", "url": "a", "range": "bytes=100-199"], query: "do=py&url=a"),
                            target: spider, writer: part)
        #expect(await part.header("Content-Range") == "bytes 100-199/\(total)")
    }

    static func rep(_ codecs: String, _ bandwidth: Int) -> String {
        "<Representation bandwidth=\"\(bandwidth)\" codecs=\"\(codecs)\" id=\"\(codecs)-\(bandwidth)\">"
            + "<BaseURL>u\(bandwidth)</BaseURL><SegmentBase indexRange=\"9-99\"/></Representation>"
    }

    /// py/哔哩.py's manifest: six video qualities in one set, three audio tracks in another.
    @Test func aManifestKeepsTheBestH264AndTheBestAudio() {
        let mpd = "<MPD><Period><AdaptationSet mimeType=\"video/mp4\">"
            + [Self.rep("avc1.64001F", 517065), Self.rep("hvc1.1.6", 349849), Self.rep("av01.0", 995837),
               Self.rep("avc1.64001E", 305202)].joined()
            + "</AdaptationSet><AdaptationSet mimeType=\"audio/mp4\">"
            + [Self.rep("mp4a.40.2", 67177), Self.rep("mp4a.40.2", 166920)].joined()
            + "</AdaptationSet></Period></MPD>"
        #expect(SpiderProxyServer.oneRepresentationPerType(mpd) == "<MPD><Period><AdaptationSet mimeType=\"video/mp4\">"
            + Self.rep("avc1.64001F", 517065) + "</AdaptationSet><AdaptationSet mimeType=\"audio/mp4\">"
            + Self.rep("mp4a.40.2", 166920) + "</AdaptationSet></Period></MPD>")
    }

    /// py/油管-6.py's manifest: one set per video track; the sets left without a Representation go.
    @Test func aManifestDropsTheVideoSetsItNoLongerNeeds() {
        let mpd = "<MPD><Period><AdaptationSet mimeType=\"video/webm\">" + Self.rep("vp9", 900) + "</AdaptationSet>"
            + "<AdaptationSet mimeType=\"video/webm\">" + Self.rep("vp9", 2000) + "</AdaptationSet>"
            + "<AdaptationSet mimeType=\"audio/mp4\">" + Self.rep("mp4a.40.2", 128000) + "</AdaptationSet></Period></MPD>"
        #expect(SpiderProxyServer.oneRepresentationPerType(mpd) == "<MPD><Period>"
            + "<AdaptationSet mimeType=\"video/webm\">" + Self.rep("vp9", 2000) + "</AdaptationSet>"
            + "<AdaptationSet mimeType=\"audio/mp4\">" + Self.rep("mp4a.40.2", 128000) + "</AdaptationSet></Period></MPD>")
    }

    @Test func windowsAndContentRanges() {
        #expect(SpiderProxyServer.window(nil)! == (0, nil))
        #expect(SpiderProxyServer.window("bytes=5-")! == (5, nil))
        #expect(SpiderProxyServer.window("bytes=5-9")! == (5, 9))
        #expect(SpiderProxyServer.window("bytes=-500") == nil)
        #expect(SpiderProxyServer.window("bytes=0-1,5-9") == nil)
        #expect(SpiderProxyServer.contentRange(["content-range": "bytes 0-9/100"])! == (0, 9, 100))
        #expect(SpiderProxyServer.contentRange(["Content-Range": "bytes */100"]) == nil)
    }

    @Test func dashGoesToMPV() {
        #expect(PlayerRouter.needsMPV(URL(string: "https://a.example/v/manifest.mpd")!))
        #expect(!PlayerRouter.needsMPV(URL(string: "https://a.example/v/index.m3u8")!))
    }
}

/// W-268: downloads name their site; the spider answering, and how long it may take, follow from that.
extension SpiderProxyServerTests {
    final class Recording: SpiderProxying, @unchecked Sendable {
        let body: String
        private let lock = NSLock()
        private var seen = [[String: String]]()
        var asked: [[String: String]] { lock.withLock { seen } }
        init(_ body: String) { self.body = body }
        func proxy(params: [String: String]) async throws -> SpiderProxyResponse? {
            lock.withLock { seen.append(params) }
            return SpiderProxyResponse(status: 200, mime: "text/plain", body: Data(body.utf8))
        }
    }

    func get(_ server: SpiderProxyServer, _ query: String) async -> Sink {
        let sink = Sink()
        await server.respond(to: "GET /\(server.token)/proxy?\(query) HTTP/1.1\r\nHost: 127.0.0.1", on: sink)
        return sink
    }

    @Test func aDownloadIsAnsweredByItsOwnSitesSpiderNotTheOneThatPlayedLast() async throws {
        let server = SpiderProxyServer()
        let downloaded = Recording("A")
        #expect(await server.downloadBase(siteID: "a") { downloaded } != nil)
        let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"b","name":"b","type":3,"api":"./b.py"}"#.utf8))
        _ = try #require(await server.serve("http://127.0.0.1:9978/proxy?do=py&f=1", for: SpiderSession(site: site, runtime: WholeFile(Data("B".utf8))),
                                            dash: false))

        #expect(await get(server, "do=py&f=1&\(OfflineLocalProxy.siteParameter)=a").body == Data("A".utf8))
        #expect(await get(server, "do=py&f=1").body == Data("B".utf8))
        let b = try #require(site.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(await get(server, "do=py&f=1&\(OfflineLocalProxy.siteParameter)=\(b)").body == Data("B".utf8))
        // An unknown site is not handed to whichever spider played last; the download tries again (W-270).
        #expect(await get(server, "do=py&f=1&\(OfflineLocalProxy.siteParameter)=c").head.hasPrefix("HTTP/1.1 503"))
        #expect(downloaded.asked.count == 1 && downloaded.asked[0][OfflineLocalProxy.siteParameter] == nil)
        // The app's current spider replaces the one kept; with none, the kept one still serves.
        #expect(await server.downloadBase(siteID: "a") { Recording("A2") } != nil)
        #expect(await get(server, "do=py&f=1&\(OfflineLocalProxy.siteParameter)=a").body == Data("A2".utf8))
        #expect(await server.downloadBase(siteID: "a") { nil } != nil)
        #expect(await get(server, "do=py&f=1&\(OfflineLocalProxy.siteParameter)=a").body == Data("A2".utf8))
    }

    /// W-270: dropping the app's sessions (a reloaded configuration or spider pack) lets the proxy's per-site
    /// spiders go too, so the old one is freed; a download makes its site's again.
    @Test func aSessionResetFreesTheSpidersKeptForDownloads() async {
        let site = "w270-\(UUID().uuidString)"
        weak var old: Recording?
        do {
            let spider = Recording("old")
            old = spider
            #expect(await SpiderProxyServer.shared.downloadBase(siteID: site) { spider } != nil)
        }
        #expect(old != nil)
        await SpiderSessionStore().reset()
        #expect(old == nil)
        // A transfer already queued gets 503, which the download retries (a 404 would fail it), and the retry
        // makes the site's spider again.
        #expect(await get(SpiderProxyServer.shared, "do=py&f=1&\(OfflineLocalProxy.siteParameter)=\(site)").head.hasPrefix("HTTP/1.1 503"))
    }

    @Test func onlyADownloadGetsTheLongerLimit() async {
        let server = SpiderProxyServer()
        server.callTimeout = .milliseconds(50)
        server.downloadTimeout = .seconds(5)
        let slow = Media(total: 100, delay: .milliseconds(300))
        _ = await server.downloadBase(siteID: "a") { slow }
        let downloaded = await get(server, "do=py&type=media&\(OfflineLocalProxy.siteParameter)=a")
        #expect(await downloaded.head.hasPrefix("HTTP/1.1 200"))
        #expect(await downloaded.body == Media.bytes(0...99))
        // The player's request for the same file keeps playback's limit.
        #expect(await run(range: nil, media: slow, server: server).head.hasPrefix("HTTP/1.1 504"))
    }
}
#endif
