import Foundation
import Testing
@testable import WebHTVCore

// W-281: AnimeXifan (spider.jar second batch) against replies cut down from what next.xifanacg.com and
// api.xifanacg.com returned on 2026-11-10 (docs/W-281-animexifan-port.md §3). Each test pins one upstream behaviour
// or one deliberate difference.

/// Answers both xifan hosts through one handler and remembers each request with its body and headers.
final class XifanSite: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let body: String; let headers: [String: String] }
    typealias Handler = @Sendable (URL, String) -> (Int, String)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _, _ in nil }
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ handler: @escaping Handler) { lock.withLock { self.handler = handler; seen = [] } }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let url = request.url!, text = String(decoding: body, as: UTF8.self)
        let reply = Self.lock.withLock { () -> (Int, String)? in
            Self.seen.append(Seen(url: url, body: text, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.handler(url, text)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply?.0 ?? 404, httpVersion: nil,
                                                               headerFields: ["Content-Type": "text/html; charset=utf-8"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((reply?.1 ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func xifan() async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [XifanSite.self]
    let runtime = try JavaScriptSpiderRuntime(
        name: "AnimeXifan", script: try #require(registry.entry(for: "csp_AnimeXifan")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "W281-AnimeXifan", defaults: UserDefaults(suiteName: "W281-AnimeXifan")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: "")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func path(_ url: URL) -> String { url.path + (url.query.map { "?" + $0 } ?? "") }

/// A browse page's schema.org list; the second name carries braces and an escaped quote inside the string.
private let browse = #"""
<html><body><div hidden id="S:3"><script type="application/ld+json">{"@context":"https://schema.org","@type":"ItemList","numberOfItems":2,"itemListElement":[{"@type":"ListItem","position":1,"item":{"@type":"TVSeries","name":"宇宙骑士BLADE","url":"https://next.xifanacg.com/anime/3525","image":"https://img2.xfmanga.top/pic/cover/l/6b/57/2481_msJP0.jpg","datePublished":"1992"}},{"@type":"ListItem","position":2,"item":{"name":"括号{测试}\"引号","url":"https://next.xifanacg.com/anime/77","image":"","datePublished":"2026"}},{"@type":"ListItem","position":3,"item":{"name":"无编号","url":"https://next.xifanacg.com/browse"}}]}</script></div></body></html>
"""#

/// The home page: the same list inside the RSC payload, every quote escaped.
private let home = #"""
<script>self.__next_f.push([1,"4f:Ta23,{\"@context\":\"https://schema.org\",\"@type\":\"ItemList\",\"numberOfItems\":1,\"itemListElement\":[{\"@type\":\"ListItem\",\"position\":1,\"item\":{\"@type\":\"TVSeries\",\"name\":\"飙马野郎 JOJO的奇妙冒险 第二&第三赛段\",\"url\":\"https://next.xifanacg.com/anime/3441\",\"image\":\"https://img2.xfmanga.top/pic/cover/l/ab/4f/639938_2JKQ7.jpg\"}}]}\n"])</script>
"""#

/// A detail page: title, poster, synopsis, and two lines in the RSC payload (episode titles with `#` and `$`).
private let detailPage = #"""
<html><body><h1 class="text-2xl">飙马野郎 JOJO的奇妙冒险 第二&amp;第三赛段</h1>
<img src="https://next.xifanacg.com/logo.png"><img src="https://img2.xfmanga.top/pic/cover/l/ab/4f/639938_2JKQ7.jpg">
<p class="text-sm whitespace-pre-line">1890年的美国。</p>
<script>self.__next_f.push([1,"[{\"id\":4,\"code\":\"xfxf1\",\"name\":\"稀饭新番主线-1\",\"episodes\":[{\"id\":203869,\"kind\":\"main\",\"title\":\"警长对曼登·提姆的要求\",\"available_at\":\"2026-09-25T11:41:10+00:00\",\"episode_number\":1,\"stale_update_eligible_at\":\"2026-10-03\"},{\"id\":203870,\"kind\":\"main\",\"title\":\"沙漠#中$诞生\",\"episode_number\":2}]},{\"id\":2,\"code\":\"CS\",\"name\":\"稀饭备用-1\",\"episodes\":[{\"id\":203869,\"kind\":\"main\",\"title\":\"\",\"episode_number\":1}]},{\"id\":9,\"code\":\"EMPTY\",\"name\":\"空线\",\"episodes\":[]}]"])</script>
</body></html>
"""#

@Suite(.serialized) struct AnimeXifanSpiderTests {
    @Test func registersAnimeXifan() {
        let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
        #expect(registry.canDrive("csp_AnimeXifan"))
        #expect(SpiderRegistry.ported.contains("AnimeXifan"))
    }

    @Test func listsTheFiveFormatsAndPagesABrowseList() async throws {
        XifanSite.serve { url, _ in
            path(url) == "/browse?type=2&format=tv&sort=created_at&page=2" ? (200, browse) : nil
        }
        let runtime = try await xifan()
        let classes = try #require(try object(try await runtime.homeContent(filter: false))["class"] as? [[String: Any]])
        #expect(classes.map { $0["type_id"] as? String } == ["tv", "movie", "ova", "web", "other"])

        let page = try object(try await runtime.categoryContent(tid: "tv", page: "2", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        // Numeric ids, not page URLs; a card without an /anime/<id> address is dropped.
        #expect(items.map { $0["vod_id"] as? String } == ["3525", "77"])
        #expect(items.map { $0["vod_name"] as? String } == ["宇宙骑士BLADE", #"括号{测试}"引号"#])
        #expect(items.first?["vod_remarks"] as? String == "1992")
        #expect(page["pagecount"] as? Int == 2, "a short page is the last one")
        // An unknown category never reaches the site.
        #expect(try list(try await runtime.categoryContent(tid: "../x", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(XifanSite.requests.count == 1)
        #expect(XifanSite.requests.first?.headers["Referer"] == "https://next.xifanacg.com/")
    }

    @Test func readsTheHomeListFromTheEscapedPayload() async throws {
        XifanSite.serve { url, _ in url.absoluteString == "https://next.xifanacg.com" ? (200, home) : nil }
        let items = try list(try await xifan().homeVideoContent())
        #expect(items.map { $0["vod_id"] as? String } == ["3441"])
        #expect(items.first?["vod_name"] as? String == "飙马野郎 JOJO的奇妙冒险 第二&第三赛段")
    }

    @Test func detailListsEveryLineWithItsOwnSourceId() async throws {
        XifanSite.serve { url, _ in path(url) == "/anime/3441" ? (200, detailPage) : nil }
        let runtime = try await xifan()
        let vod = try #require(try list(try await runtime.detailContent(ids: ["3441"])).first)
        #expect(vod["vod_name"] as? String == "飙马野郎 JOJO的奇妙冒险 第二&第三赛段")
        #expect(vod["vod_pic"] as? String == "https://img2.xfmanga.top/pic/cover/l/ab/4f/639938_2JKQ7.jpg")
        #expect(vod["vod_content"] as? String == "1890年的美国。")
        // An empty line is not listed; `#` and `$` never split an episode.
        #expect(vod["vod_play_from"] as? String == "稀饭新番主线-1$$$稀饭备用-1")
        #expect(vod["vod_play_url"] as? String == "1 警长对曼登·提姆的要求$203869@4#2 沙漠 中 诞生$203870@4$$$1$203869@2")
        // The old URL form of an id still opens the same page; anything else never fetches.
        #expect(try list(try await runtime.detailContent(ids: ["https://next.xifanacg.com/anime/3441"])).first?["vod_id"] as? String == "3441")
        #expect(try list(try await runtime.detailContent(ids: ["https://evil.example/x"])).isEmpty)
        #expect(XifanSite.requests.map { path($0.url) } == ["/anime/3441", "/anime/3441"])
    }

    @Test func searchPostsTheRPCWithThePublishableKeyOnly() async throws {
        XifanSite.serve { url, _ in
            path(url) == "/rest/v1/rpc/search_animes"
                ? (200, #"[{"id":2481,"title":"海贼","cover_url":"https://img2.xfmanga.top/c.jpg","release_year":1999,"bangumi_score":8.5},{"id":0,"title":"无"},{"id":9,"title":"没分数","release_year":2026}]"#)
                : nil
        }
        let runtime = try await xifan()
        let items = try list(try await runtime.searchContent(key: "海", quick: false, page: "1"))
        #expect(items.map { $0["vod_id"] as? String } == ["2481", "9"])
        #expect(items.map { $0["vod_remarks"] as? String } == ["1999 · 8.5", "2026"])
        let seen = try #require(XifanSite.requests.first)
        #expect(seen.url.absoluteString == "https://api.xifanacg.com/rest/v1/rpc/search_animes")
        #expect(seen.headers["apikey"] == "sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA")
        #expect(seen.headers["Authorization"] == nil, "no bearer token: anonymous, publishable access only")
        let body = try object(seen.body)
        #expect(body["search_term"] as? String == "海" && body["items_per_page"] as? Int == 24)
        // One page only, as upstream.
        #expect(try list(try await runtime.searchContent(key: "海", quick: false, page: "2")).isEmpty)
        #expect(XifanSite.requests.count == 1)
    }

    @Test func playIssuesTheSignedAddressWithoutAKey() async throws {
        XifanSite.serve { url, body in
            guard path(url) == "/functions/v1/issue-web-playback" else { return nil }
            return body.contains(#""episode_id":203869"#) && body.contains(#""source_id":4"#)
                ? (200, #"{"ok":true,"url":"https://apn.moedot.net/d/wo/2610/JOJO01.mp4?sign=abc%3D%3A1794315600"}"#)
                : (200, #"{"ok":false}"#)
        }
        let runtime = try await xifan()
        let play = try object(try await runtime.playerContent(flag: "稀饭新番主线-1", id: "203869@4", vipFlags: []))
        #expect(play["url"] as? String == "https://apn.moedot.net/d/wo/2610/JOJO01.mp4?sign=abc%3D%3A1794315600")
        #expect(play["parse"] as? Int == 0)
        let seen = try #require(XifanSite.requests.first)
        #expect(seen.headers["apikey"] == nil, "play needs no key")
        #expect(try object(seen.body)["action"] as? String == "fallback")
        #expect(try object(try await runtime.playerContent(flag: "", id: "203869@2", vipFlags: []))["url"] as? String == "")
        #expect(try object(try await runtime.playerContent(flag: "", id: "bad", vipFlags: []))["url"] as? String == "")
    }
}
