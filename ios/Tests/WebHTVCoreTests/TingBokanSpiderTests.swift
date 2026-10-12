import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-9 (W-76): TingBokan.js against the replies the live API returned on 2026-10-12 (W-54 gate: category 1303
// page 1, album 4033132's units) and hand-made edge replies, following the W-63 design (qist-tingbokan-gate-2026-10-12.md D3–D5).

/// Answers api.bookan.com.cn and es.bookan.com.cn by path, and by `page` for album units; remembers every request.
final class BookanSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [(url: URL, headers: [String: String])] = []

    /// Keys are `path`, or `path?page=N` for a reply that only answers that page.
    static func serve(_ served: [String: Data], status: Int = 200) {
        lock.withLock { replies = served.mapValues { (status, $0) }; seen = [] }
    }
    static var requests: [(url: URL, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["api.bookan.com.cn", "es.bookan.com.cn"].contains(request.url?.host ?? "")
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A gate reply, raw-deflated and base64-encoded, checked against the SHA-256 the gate recorded.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func category1303() throws -> Data { try fixture(categoryPacked, sha256: "095a5ca8b4c861f9d46ffa59a2a268e202eab4be39cd674eff693c1b104e3fa3") }
private func units4033132() throws -> Data { try fixture(unitsPacked, sha256: "8f6a4fc12343ba2558cc8e3d076e08484f11709b2764693e8c9234b4bc6b4a27") }

private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
private let firstEpisode = "01.《葵花向太阳》 引子 心中的桥$http://audio.bookan.com.cn/video1/audio/2022120101/aache64_cf3c3a52.m4a"

private func tingBokan() async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BookanSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "TingBokan", script: try #require(registry.entry(for: "csp_TingBokan")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "TingBokan-test", defaults: UserDefaults(suiteName: "TingBokan-test")!),
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

private func query(_ url: URL?) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? [])
        .map { ($0.name, $0.value ?? "") })
}

/// One page of album units: `files` become `title`/`file` pairs.
private func units(_ files: [String], lastPage: Int, code: Int = 0) throws -> Data {
    try json(["code": code, "data": ["last_page": lastPage, "list": files.map { ["title": $0, "file": "http://audio.bookan.com.cn/a/\($0).m4a",
                                                                                "updated_at": "2026-10-12 08:00:00"] }]])
}

@Suite(.serialized) struct TingBokanSpiderTests {
    @Test func homeOffersUpstreamsFirstElevenClassesWithoutTheNetwork() async throws {
        BookanSite.serve([:])
        let home = try object(try await tingBokan().homeContent(filter: false))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } ==
                ["1303故事会", "1304儿童文学", "1305少年读物", "1306文艺少年", "1307青春励志", "1308个人提升",
                 "1309育儿心经", "1310心理哲学", "1311家庭健康", "1312历史小说", "1313科技科普"])
        #expect(home["list"] == nil && BookanSite.requests.isEmpty)
    }

    @Test func aCategoryAsksForItsPageAndMapsTheSavedReply() async throws {
        BookanSite.serve(["/voice/book/list": try category1303()])
        let page = try object(try await tingBokan().categoryContent(tid: "1303", page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.count == 24 && page["pagecount"] as? Int == 22 && page["limit"] as? Int == 24 && page["total"] as? Int == 528)
        #expect(items.first?["vod_id"] as? String == "4033132@葵花向太阳" && items.first?["vod_name"] as? String == "葵花向太阳")
        #expect(items.first?["vod_pic"] as? String == "http://img-qn.bookan.com.cn/video1/audiocover/defaultcover.png")
        let sent = try #require(BookanSite.requests.last)
        #expect(sent.url.absoluteString == "https://api.bookan.com.cn/voice/book/list?instance_id=25304&page=1&category_id=1303&num=24")
        #expect(sent.headers["User-Agent"] == chrome)
    }

    @Test func aBrokenCategoryReplyOrItemIsDroppedAndABadTidSendsNothing() async throws {
        let spider = try await tingBokan()
        BookanSite.serve(["/voice/book/list": try json(["code": 1, "data": ["list": [["id": 1, "name": "a"]]]])])
        #expect(try list(try await spider.categoryContent(tid: "1303", page: "1", filter: false, extend: [:])).isEmpty)
        BookanSite.serve(["/voice/book/list": try json(["code": 0, "data": ["last_page": "x", "list": [
            ["id": 1, "name": "无作者", "extra": "none"],
            ["name": "缺 id"],
            ["id": 2],
            ["id": 3, "name": "有作者", "extra": ["author": "某人"]],
        ] as [Any]]])])
        let page = try object(try await spider.categoryContent(tid: "1303", page: "0", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.map { $0["vod_name"] as? String } == ["无作者", "有作者"])
        #expect(items.map { $0["vod_remarks"] as? String } == ["", "某人"])
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 1)
        #expect(query(BookanSite.requests.last?.url)["page"] == "1")

        BookanSite.serve(["/voice/book/list": try category1303()])
        #expect(try list(try await spider.categoryContent(tid: "x", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(BookanSite.requests.isEmpty)
    }

    @Test func aDetailListsEverySavedEpisode() async throws {
        BookanSite.serve(["/voice/album/units": try units4033132()])
        let vod = try #require(try list(try await tingBokan().detailContent(ids: ["4033132@葵花向太阳"])).first)
        #expect(vod["vod_id"] as? String == "4033132@葵花向太阳" && vod["vod_name"] as? String == "葵花向太阳")
        #expect(vod["vod_play_from"] as? String == "博看听书" && vod["vod_remarks"] as? String == "更新于 2022-12-01 05:30:03")
        let episodes = Episode.parse(try #require(vod["vod_play_url"] as? String))
        #expect(episodes.count == 60)
        #expect((vod["vod_play_url"] as? String)?.hasPrefix(firstEpisode + "#") == true)
        #expect(query(BookanSite.requests.last?.url) == ["album_id": "4033132", "page": "1", "num": "200", "order": "1"])
        #expect(BookanSite.requests.last?.headers["User-Agent"] == chrome)
    }

    @Test func aDetailWalksItsPagesStopsAtAFailedOneAndAtFifty() async throws {
        let spider = try await tingBokan()
        BookanSite.serve(["/voice/album/units?page=1": try units(["a", "b"], lastPage: 3),
                          "/voice/album/units?page=2": try units(["c"], lastPage: 3),
                          "/voice/album/units?page=3": try units(["d"], lastPage: 3)])
        var vod = try #require(try list(try await spider.detailContent(ids: ["7@书"])).first)
        #expect(Episode.parse(try #require(vod["vod_play_url"] as? String)).map(\.name) == ["a", "b", "c", "d"])
        #expect(BookanSite.requests.map { query($0.url)["page"] } == ["1", "2", "3"])

        BookanSite.serve(["/voice/album/units?page=1": try units(["a"], lastPage: 3),
                          "/voice/album/units?page=2": try units(["b"], lastPage: 3, code: 500),
                          "/voice/album/units?page=3": try units(["c"], lastPage: 3)])
        vod = try #require(try list(try await spider.detailContent(ids: ["7@书"])).first)
        #expect(Episode.parse(try #require(vod["vod_play_url"] as? String)).map(\.name) == ["a"])
        #expect(BookanSite.requests.count == 2)

        BookanSite.serve(["/voice/album/units": try units(["a"], lastPage: 999)])
        _ = try await spider.detailContent(ids: ["7@书"])
        #expect(BookanSite.requests.count == 50)
    }

    @Test func aNameWithAnAtSignKeepsItAndOnlyTheNumberIsSent() async throws {
        let spider = try await tingBokan()
        var reply = try JSONSerialization.jsonObject(with: try units(["一$集#二", "", "坏"], lastPage: 1)) as! [String: Any]
        var data = reply["data"] as! [String: Any]
        var rows = data["list"] as! [[String: Any]]
        rows[0]["file"] = "http://audio.bookan.com.cn/a/1.m4a"
        rows[2]["file"] = "http://audio.bookan.com.cn/a#b.m4a"
        data["list"] = rows; reply["data"] = data
        BookanSite.serve(["/voice/album/units": try json(reply)])
        let vod = try #require(try list(try await spider.detailContent(ids: ["7@a@b"])).first)
        #expect(vod["vod_name"] as? String == "a@b" && query(BookanSite.requests.last?.url)["album_id"] == "7")
        #expect(Episode.parse(try #require(vod["vod_play_url"] as? String)).map(\.name) == ["一 集 二", "2"])

        BookanSite.serve([:])
        #expect(try list(try await spider.detailContent(ids: ["abc@书"])).isEmpty)
        #expect(try list(try await spider.detailContent(ids: ["4033132"])).isEmpty)
        #expect(BookanSite.requests.isEmpty)
    }

    @Test func playKeepsTheAudioWithTheUAAndRefusesAnythingElse() async throws {
        let spider = try await tingBokan()
        let audio = "http://audio.bookan.com.cn/video1/audio/2022120101/aache64_cf3c3a52.m4a"
        let played = try object(try await spider.playerContent(flag: "博看听书", id: audio, vipFlags: []))
        #expect(played["url"] as? String == audio && played["parse"] as? Int == 0)
        #expect(played["header"] as? [String: String] == ["User-Agent": chrome])
        for bad in ["http://audio.bookan.com.cn/a#b.m4a", "file:///etc/passwd", ""] {
            #expect(try object(try await spider.playerContent(flag: "", id: bad, vipFlags: []))["url"] as? String == "")
        }
    }

    @Test func searchSendsTheTrimmedKeywordAndFallsBackToThePress() async throws {
        BookanSite.serve(["/api/v3/voice/book": try json(["code": 0, "data": ["list": [
            ["id": 9, "name": "甲", "cover": "c", "extra": ["author": ""], "press": "出版社"],
            ["id": 10, "name": "乙", "extra": ["author": "作者"], "press": "出版社"],
            ["id": 11, "name": "丙", "press": "出版社"],
        ]]])])
        let spider = try await tingBokan()
        let items = try list(try await spider.searchContent(key: " 葵花 ", quick: false, page: "1"))
        #expect(items.map { $0["vod_id"] as? String } == ["9@甲", "10@乙", "11@丙"])
        #expect(items.map { $0["vod_remarks"] as? String } == ["出版社", "作者", ""])
        #expect(BookanSite.requests.last?.url.absoluteString ==
                "https://es.bookan.com.cn/api/v3/voice/book?instanceId=25304&keyword=%E8%91%B5%E8%8A%B1&pageNum=1&limitNum=20")

        BookanSite.serve(["/api/v3/voice/book": try json(["code": 0, "data": ["list": [["id": 1, "name": "x"]]]])])
        #expect(try list(try await spider.searchContent(key: "  ", quick: false, page: "1")).isEmpty)
        #expect(BookanSite.requests.isEmpty)
    }

    @Test func aServerErrorOnACategoryIsReported() async throws {
        let spider = try await tingBokan()
        BookanSite.serve(["/voice/book/list": Data()], status: 500)
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "api.bookan.com.cn")) {
            _ = try await spider.categoryContent(tid: "1303", page: "1", filter: false, extend: [:])
        }
    }
}

/// `category-1303-p1.json` from the W-54 gate (8641 bytes), raw-deflated.
private let categoryPacked = """
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
YS1d//0FIRMT/wc=
"""

/// `units-4033132-p1.json` from the W-54 gate (22569 bytes), raw-deflated.
private let unitsPacked = """
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
1J2676b9s6Oj/wE=
"""
