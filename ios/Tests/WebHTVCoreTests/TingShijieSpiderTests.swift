import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-18 (W-153): TingShijie.js (世界听书) against replies shaped as the live API answered the W-148 gate on
// 2026-10-16 (artifacts/qist-TingShijie-gate-2026-10-16.md, tingshijie-gate-fixtures/): JSON with `status`, a `count`
// that is a string, chapters 1000 a page, `status 1 分集地址解析失败` for some chapters, and audio that Cloudflare only
// serves to an okhttp User-Agent.

/// Answers app.365ting.com by path (and `page` for chapters) and the config host 101.43.48.231; remembers every request.
final class ShijieSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [(url: URL, headers: [String: String])] = []

    /// Keys are a path, or `path?page=N` for a reply that only answers that page.
    static func serve(_ served: [String: Data], status: Int = 200) {
        lock.withLock { replies = served.mapValues { (status, $0) }; seen = [] }
    }
    static var requests: [(url: URL, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["app.365ting.com", "101.43.48.231"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append((url, request.allHTTPHeaderFields ?? [:]))
            return Self.replies[url.path + "?page=" + (page ?? "")] ?? Self.replies[url.path] ?? (404, Data())
        }
        // The API labels its JSON text/html (gate #2).
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "text/html"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private let api = "/listen/Apitzg2025/"
private let salt = "J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K"  // TingShijie.java:162

private func tingShijie(_ served: [String: Data] = [:]) async throws -> JavaScriptSpiderRuntime {
    ShijieSite.serve(served)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ShijieSite.self]
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "TingShijie", script: try #require(registry.entry(for: "csp_TingShijie")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "TingShijie-test", defaults: UserDefaults(suiteName: "TingShijie-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: "")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
}

private func apiRequests() -> [(url: URL, headers: [String: String])] {
    ShijieSite.requests.filter { $0.url.host == "app.365ting.com" }
}

private func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

/// A book as `appHomeByCategory` and `appSearch` list it (gate #2, #27): `id` is a number there.
private func book(_ id: Int, _ title: String) -> [String: Any] {
    ["id": id, "bookTitle": title, "bookImage": "https://imagev2.xmcdn.com/\(id).jpg", "bookAnchor": "播音\(id)", "count": 12]
}

private func chapters(_ range: ClosedRange<Int>, title: (Int) -> String) throws -> Data {
    try json(["status": 0, "data": ["list": range.map { ["chapterId": String(23_492_952 + $0), "position": $0, "title": title($0),
                                                       "price": "0", "chapterFree": 0] }]])
}

@Suite(.serialized) struct TingShijieSpiderTests {
    @Test func homeListsUpstreamsElevenClassesWithoutAskingTheApi() async throws {
        let home = try object(try await tingShijie().homeContent(filter: false))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } ==
                ["6玄幻奇幻", "7都市言情", "8宫斗女频", "9官场商战", "10武侠仙侠", "11刑侦推理", "12探险科幻", "13重生穿越", "14恐怖惊悚",
                 "15文学历史", "49两性情感"])
        #expect(home["list"] == nil)
        #expect(apiRequests().isEmpty)
    }

    // Gate condition 2: upstream's config host (101.43.48.231:8090) timed out on both gate tries; the port never asks
    // it, so a session starts without a failed request that would be blamed for every later empty listing.
    @Test func theApiIsAskedOnTheFallbackRootAndTheConfigHostNever() async throws {
        let runtime = try await tingShijie(["/listen/Apitzg2025/appHomeByCategory": try json(["status": 0, "data": []])])
        // An empty class is an empty page, not "unreachable".
        #expect(try list(try await runtime.categoryContent(tid: "6", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(ShijieSite.requests.map(\.url.absoluteString).allSatisfy { $0.hasPrefix("https://app.365ting.com" + api) })
        #expect(ShijieSite.requests.count == 1)
    }

    @Test func aCategoryPageMapsBooksAndOnlyAFullPageOffersAnother() async throws {
        let full = try json(["status": 0, "data": (1...120).map { book($0, "书\($0)") }])
        var runtime = try await tingShijie(["/listen/Apitzg2025/appHomeByCategory": full])
        var page = try object(try await runtime.categoryContent(tid: "6", page: "2", filter: false, extend: [:]))
        let first = try #require((page["list"] as? [[String: Any]])?.first)
        #expect(first["vod_id"] as? String == "1" && first["vod_name"] as? String == "书1")
        #expect(first["vod_pic"] as? String == "https://imagev2.xmcdn.com/1.jpg" && first["vod_remarks"] as? String == "播音1")
        #expect(page["page"] as? Int == 2 && page["pagecount"] as? Int == 3)
        let request = try #require(apiRequests().last)
        #expect(query(request.url) == ["categoryId": "6", "page": "2", "size": "120"])
        #expect(request.headers["User-Agent"] == "TingShiJie/1.8.8 (m.i275.com)")

        runtime = try await tingShijie(["/listen/Apitzg2025/appHomeByCategory": try json(["status": 0, "data": [book(7, "末")]])])
        page = try object(try await runtime.categoryContent(tid: "6", page: "abc", filter: false, extend: [:]))
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 1)

        runtime = try await tingShijie(["/listen/Apitzg2025/appHomeByCategory": try json(["status": 1, "data": [book(7, "末")]])])
        #expect(try list(try await runtime.categoryContent(tid: "6", page: "1", filter: false, extend: [:])).isEmpty)
        // Only a numeric class id reaches the API.
        #expect(try list(try await runtime.categoryContent(tid: "6&x=1", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(apiRequests().count == 1)
    }

    // Gate #3–#5: `count` is a string, chapters come 1000 a page; the episode is named by its title (upstream used
    // the position, which drifts from 「第N集」 once bonus chapters are inserted).
    @Test func aDetailReadsEveryChapterPageAndNamesEpisodesByTitle() async throws {
        let runtime = try await tingShijie([
            "/listen/Apitzg2025/book": try json(["status": 0, "data": ["bookData": ["id": "39413", "bookTitle": "鸣龙", "bookDesc": "简介",
                                                                                   "bookImage": "https://imagev2.xmcdn.com/b.jpg", "count": "1002"]]]),
            "/listen/Apitzg2025/chapter?page=1": try chapters(1...1000) { "鸣龙-第\($0)集" },
            "/listen/Apitzg2025/chapter?page=2": try chapters(1001...1002) { $0 == 1001 ? "加$更#集" : "" },
        ])
        let vod = try #require(try list(try await runtime.detailContent(ids: ["39413"])).first)
        #expect(vod["vod_id"] as? String == "39413" && vod["vod_name"] as? String == "鸣龙")
        #expect(vod["vod_content"] as? String == "简介" && vod["vod_pic"] as? String == "https://imagev2.xmcdn.com/b.jpg")
        #expect(vod["vod_play_from"] as? String == "世界听书")
        let episodes = (vod["vod_play_url"] as? String ?? "").components(separatedBy: "#")
        #expect(episodes.count == 1002)
        #expect(episodes.first == "鸣龙-第1集$39413|23492953")
        #expect(episodes[1000] == "加 更 集$39413|23493953")
        #expect(episodes.last == "1002$39413|23493954")
        #expect(apiRequests().map { query($0.url)["page"] ?? "-" } == ["-", "1", "2"])
        #expect(query(try #require(apiRequests().last).url) == ["size": "1000", "page": "2", "sort": "asc", "bookId": "39413"])
    }

    @Test func aBookWithNoChaptersOrABadIdAsksForNothingMore() async throws {
        let runtime = try await tingShijie([
            "/listen/Apitzg2025/book": try json(["status": 0, "data": ["bookData": ["bookTitle": "空", "bookDesc": "", "bookImage": "",
                                                                                   "count": "0"]]]),
        ])
        let vod = try #require(try list(try await runtime.detailContent(ids: ["5"])).first)
        #expect(vod["vod_play_url"] as? String == "")
        #expect(try list(try await runtime.detailContent(ids: ["5/../x"])).isEmpty)
        #expect(apiRequests().map(\.url.path) == [api + "book"])
    }

    // Gate #6, #12: the signature is md5(md5(ts + salt) + salt) over the millisecond time it sends; the audio is a
    // direct m4a that Cloudflare answers 403 to every User-Agent but okhttp's (#8–#16), so the result carries it.
    @Test func playSignsTheRequestAndHandsTheAudioOkhttpsUserAgent() async throws {
        let src = "http://audio.tingshijie.com/39413/39413_23492953.m4a?auth_key=1792121721-0-0-010a"
        let runtime = try await tingShijie(["/listen/Apitzg2025/AppGetChapterUrl2023": try json(["status": 0, "src": src])])
        let play = try object(try await runtime.playerContent(flag: "世界听书", id: "39413|23492953", vipFlags: []))
        #expect(play["url"] as? String == src && play["parse"] as? Int == 0)
        #expect(play["header"] as? [String: String] == ["User-Agent": "okhttp/4.12.0"])
        let request = try #require(apiRequests().last)
        let sent = query(request.url)
        let ts = try #require(sent["timeStamp"])
        #expect(ts.count == 13 && Int(ts) != nil)
        #expect(sent == ["timeStamp": ts, "uid": "", "chapterId": "23492953", "addItParapet": md5(md5(ts + salt) + salt),
                         "bookId": "39413"])
        #expect(request.headers["User-Agent"] == "TingShiJie/1.8.8 (m.i275.com)")
    }

    // Gate #7, #17–#22: some chapters answer `status 1 分集地址解析失败请重试点击播放` every time. No address goes back,
    // so the app says 「這一集沒有可播放的網址。」 instead of opening a player that would wait on nothing.
    @Test func aChapterTheSiteCannotResolveGivesNoAddress() async throws {
        var runtime = try await tingShijie(["/listen/Apitzg2025/AppGetChapterUrl2023":
                                            try json(["status": 1, "message": "分集地址解析失败请重试点击播放"])])
        var play = try object(try await runtime.playerContent(flag: "世界听书", id: "39413|23594564", vipFlags: []))
        #expect(play["url"] as? String == "")
        // A reply whose src is not a plain web address is no better.
        runtime = try await tingShijie(["/listen/Apitzg2025/AppGetChapterUrl2023": try json(["status": 0, "src": "file:///etc/hosts"])])
        play = try object(try await runtime.playerContent(flag: "世界听书", id: "39413|23492953", vipFlags: []))
        #expect(play["url"] as? String == "")
        // An id that is not <bookId>|<chapterId> never reaches the API.
        for id in ["39413", "39413|", "a|1", "1|2|3&x=1"] {
            play = try object(try await runtime.playerContent(flag: "世界听书", id: id, vipFlags: []))
            #expect(play["url"] as? String == "", "\(id)")
        }
        #expect(apiRequests().count == 1)
    }

    // Gate #27: one page of results; upstream passed the keyword unencoded and let OkHttp encode it.
    @Test func searchEncodesTheKeywordAndHasOnePage() async throws {
        let runtime = try await tingShijie(["/listen/Apitzg2025/appSearch":
                                            try json(["status": 0, "data": ["hostData": [], "bookData": [book(23, "万古第一神")]]])])
        let found = try list(try await runtime.searchContent(key: " 万古&x ", quick: false, page: "1"))
        #expect(found.map { $0["vod_id"] as? String } == ["23"] && found.first?["vod_name"] as? String == "万古第一神")
        let request = try #require(apiRequests().last)
        #expect(request.url.query?.contains("search=%E4%B8%87%E5%8F%A4%26x&") == true)
        #expect(query(request.url) == ["client": "babala-android", "search": "万古&x", "app_token": "abcSEARCH-2025"])
        #expect(try list(try await runtime.searchContent(key: "万古", quick: false, page: "2")).isEmpty)
        #expect(try list(try await runtime.searchContent(key: "  ", quick: false, page: "1")).isEmpty)
        #expect(apiRequests().count == 1)
    }
}
