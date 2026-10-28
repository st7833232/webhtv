#if canImport(Network)
import Foundation
import Testing
@testable import WebHTVCore

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

    @Test func aSpiderThatIgnoresRangeIsForwardedAsItAnswered() async {
        let media = Media(total: 3000, honoursRange: false)
        let sink = await run(range: "bytes=0-", media: media)
        #expect(media.ranges.count == 1)
        #expect(await sink.head.hasPrefix("HTTP/1.1 200"))
        #expect(await sink.header("Content-Length") == "3000")
    }

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
#endif
