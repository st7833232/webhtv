import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-12 (W-103): TingJinxia.js against the pages m.ting15.com served on 2026-10-13 (W-95 gate: front page,
// 武侠玄幻 pages 1 and 2 and its 热门 order, search 三国, the 3977-episode book 2117, its first and last chapter pages
// and their neoplay replies, BOM included) and hand-made edge replies.

/// Answers m.ting15.com by path and query, and remembers every request with its form body.
final class JinxiaSite: URLProtocol, @unchecked Sendable {
    struct Seen { let method: String; let url: URL; let headers: [String: String]; let body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: (status: Int, body: Data)]) { lock.withLock { replies = served; seen = [] } }
    static func serve(_ served: [String: Data]) { serve(served.mapValues { (200, $0) }) }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "m.ting15.com" }
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
        let url = request.url!
        // `URL.path` drops a trailing "/", which this site's category paths end with.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let key = path + (url.query.map { "?" + $0 } ?? "")
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append(Seen(method: request.httpMethod ?? "", url: url, headers: request.allHTTPHeaderFields ?? [:],
                                  body: String(decoding: body, as: UTF8.self)))
            return Self.replies[key] ?? (404, Data())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "text/html; charset=utf-8"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A gate page, raw-deflated and base64-encoded, checked against the SHA-256 the gate recorded.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func home() throws -> Data { try fixture(homePacked, sha256: "b6b8d8a6481094ac085e6b41074800f2d37ba42b6cd63d63cf23ef8ae7f361bf") }
private func categoryOne() throws -> Data { try fixture(categoryOnePacked, sha256: "5bb592518c38b9480c210a78b95f74472befa9a580a48d340d95e06128fb2c89") }
private func categoryTwo() throws -> Data { try fixture(categoryTwoPacked, sha256: "7fd826256449cea55bd08e96f90b7dd798e1ee899a5a81f643b2c701c2b20494") }
private func categoryHits() throws -> Data { try fixture(categoryHitsPacked, sha256: "792d705a00396cbdd56e2ee820e0b61a0c10e21fc2d2188b4c44c57aac2b4684") }
private func search() throws -> Data { try fixture(searchPacked, sha256: "31221715eea2633946404c23c8c759843a873f3c11159be848daa9ca2b4001a4") }
private func detail() throws -> Data { try fixture(detailPacked, sha256: "836e7e337f0dafcd464c810d6d73e95e4a87b6db9918ccec55fc4be186ea1157") }
private func chapterFirst() throws -> Data { try fixture(chapterFirstPacked, sha256: "873ba6d6693827a3a7a8d9f4cf9d3db7e7d990c3d67307c0abe00ab70d489a7c") }
private func chapterLast() throws -> Data { try fixture(chapterLastPacked, sha256: "705c0d77563c4937d69de64bb047e1c5ee72465823dd58c6d2c130bb8f46914f") }
private func neoplayFirst() throws -> Data { try fixture(neoplayFirstPacked, sha256: "29dc80c6d6afe999e6fc5d61bde8f40af9659d9ccf611bea132309d49853a8ee") }
private func neoplayLast() throws -> Data { try fixture(neoplayLastPacked, sha256: "cd3953ab47a1bbd9e0938bf1d65965128aca9255cb09ca582e0962523926b4e9") }

private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
private let poster = "@Referer=https://m.ting15.com/@User-Agent=" + chrome
private let neoplay = "/?s=api-getneoplay"
private let firstChapter = "/wuxiaxuanhuan/2117/0-1.html"
private let lastChapter = "/wuxiaxuanhuan/2117/0-3977.html"
private let audio = "https://oss-links.guoguo.org.cn/uploads/t010/15-%E6%97%A0%E6%95%8C%E5%89%91%E5%9F%9F-%E6%9C%89%E5%A3%B0%E7%9A%84%E7%B4%AB%E8%A5%9F/"

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JinxiaSite.self]
    return URLSession(configuration: configuration)
}

private let suite = "TingJinxia-test"

private func jinxia() async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "TingJinxia", script: try #require(registry.entry(for: "csp_TingJinxia")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: "https://m.ting15.com/")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func header(_ seen: JinxiaSite.Seen, _ name: String) -> String? {
    seen.headers.first { $0.key.lowercased() == name.lowercased() }?.value
}
private func chapter(book: String = "2117", pay: String = "11", page: String = "1", audio: String = "") -> Data {
    Data(("<html><head><meta name=\"_b\" content=\"\(book)\"><meta name=\"_p\" content=\"\(pay)\"><meta name=\"_cp\" content=\"\(page)\">"
          + "<meta name=\"_c\" content=\"x\"></head><body><audio id=\"player\" src=\"\(audio)\"></audio></body></html>").utf8)
}

@Suite(.serialized) struct TingJinxiaSpiderTests {
    @Test func theRegistryDrivesCspTingJinxia() {
        #expect(SpiderRegistry.bundled().entry(for: "csp_TingJinxia") != nil)
    }

    @Test func homeListsNineClassesWithTheOrderFilterAndAsksNothing() async throws {
        JinxiaSite.serve([:] as [String: Data])
        let home = try object(try await jinxia().homeContent(filter: true))
        let classes = try #require(home["class"] as? [[String: String]])
        #expect(classes.map { $0["type_id"]! } == ["wuxiaxuanhuan", "kongbulingyi", "tuilixuanyi", "dushiyanqing", "jiatinglunli",
                                                    "wenxuemingzhu", "jingdianpingshu", "quyixiqu", "xiangshengxiaopin"])
        #expect(classes.first?["type_name"] == "武侠玄幻" && classes.last?["type_name"] == "相声小品")
        let rows = try #require((home["filters"] as? [String: [[String: Any]]])?["quyixiqu"])
        #expect(rows.first?["key"] as? String == "order")
        #expect((rows.first?["value"] as? [[String: String]])?.map { $0["v"]! } == ["", "hits", "addtime"])
        #expect(JinxiaSite.requests.isEmpty)
    }

    // Gate adaptation 1, plus one card per book: the front page lists 22 books in 27 links.
    @Test func theHomeRowListsEachFrontPageBookOnce() async throws {
        JinxiaSite.serve(["/": try home()])
        let items = try #require(try list(try await jinxia().homeVideoContent()) as? [[String: String]])
        try #require(items.count == 22 && Set(items.map { $0["vod_id"]! }).count == 22)
        #expect(items[0] == ["vod_id": "/jiatinglunli/2049.html", "vod_name": "桃园如此多娇",
                             "vod_pic": "https://img-book-oss.guoguo.org.cn/Upload/ting/20250322151049400.jpg" + poster, "vod_remarks": "听书"])
        let request = try #require(JinxiaSite.requests.first)
        #expect(request.url.absoluteString == "https://m.ting15.com/")
        #expect(header(request, "User-Agent") == chrome && header(request, "Referer") == "https://m.ting15.com/")
        #expect(header(request, "Accept") == "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
    }

    // Gate adaptation 2 and the bytecode's page count (a span with '/' is read; jadx shows it inverted).
    @Test func categoriesUseTheSitesOwnLinksAndReadThePageCount() async throws {
        let spider = try await jinxia()
        JinxiaSite.serve(["/wuxiaxuanhuan/": try categoryOne(), "/wuxiaxuanhuan/index2.html": try categoryTwo(),
                          "/wuxiaxuanhuan/index1-order-hits.html": try categoryHits()])
        let one = try object(try await spider.categoryContent(tid: "wuxiaxuanhuan", page: "x", filter: false, extend: [:]))
        let first = try #require((one["list"] as? [[String: String]])?.first)
        #expect(first == ["vod_id": "/wuxiaxuanhuan/2117.html", "vod_name": "无敌剑域",
                          "vod_pic": "https://img-book-oss.guoguo.org.cn/Upload/ting/20260720161400.jpg" + poster, "vod_remarks": "听书"])
        #expect(one["page"] as? Int == 1 && one["pagecount"] as? Int == 34 && one["limit"] as? Int == 8 && one["total"] as? Int == 8)
        #expect(JinxiaSite.requests.last?.url.absoluteString == "https://m.ting15.com/wuxiaxuanhuan/")

        let two = try object(try await spider.categoryContent(tid: "wuxiaxuanhuan", page: "2", filter: false, extend: [:]))
        #expect(JinxiaSite.requests.last?.url.absoluteString == "https://m.ting15.com/wuxiaxuanhuan/index2.html")
        #expect((two["list"] as? [[String: String]])?.first?["vod_name"] == "神印王座" && two["pagecount"] as? Int == 34)

        let hits = try list(try await spider.categoryContent(tid: "wuxiaxuanhuan", page: "1", filter: true, extend: ["order": "hits"]))
        #expect(JinxiaSite.requests.last?.url.path == "/wuxiaxuanhuan/index1-order-hits.html")
        #expect(hits.count == 8 && hits.first?["vod_name"] as? String == "大奉打更人")

        let before = JinxiaSite.requests.count
        for tid in ["../x", "A1", ""] {
            #expect(try list(try await spider.categoryContent(tid: tid, page: "1", filter: false, extend: [:])).isEmpty)
        }
        _ = try await spider.categoryContent(tid: "wuxiaxuanhuan", page: "1", filter: true, extend: ["order": "x/../y"])
        #expect(JinxiaSite.requests.count == before + 1
                && JinxiaSite.requests.last?.url.absoluteString == "https://m.ting15.com/wuxiaxuanhuan/")
    }

    @Test func searchEncodesTheKeywordAsJavaDoes() async throws {
        let spider = try await jinxia()
        JinxiaSite.serve(["/?s=ting-search-wd-%E4%B8%89%E5%9B%BD": try search()])
        let items = try list(try await spider.searchContent(key: " 三国 ", quick: false, page: "1"))
        #expect(items.count == 4 && items.first?["vod_name"] as? String == "贼三国")
        _ = try await spider.searchContent(key: "a b!", quick: false, page: "1")
        #expect(JinxiaSite.requests.last?.url.query == "s=ting-search-wd-a+b%21")
        JinxiaSite.serve([:] as [String: Data])
        #expect(try list(try await spider.searchContent(key: "  ", quick: false, page: "1")).isEmpty && JinxiaSite.requests.isEmpty)
    }

    @Test func theDetailListsAllEpisodesOfTheGateBook() async throws {
        let spider = try await jinxia()
        JinxiaSite.serve(["/wuxiaxuanhuan/2117.html": try detail()])
        let clock = ContinuousClock(), started = clock.now
        let item = try #require(try list(try await spider.detailContent(ids: ["/wuxiaxuanhuan/2117.html"])).first as? [String: String])
        let elapsed = clock.now - started
        #expect(item["vod_id"] == "/wuxiaxuanhuan/2117.html" && item["vod_name"] == "无敌剑域")
        #expect(item["vod_pic"] == "https://img-book-oss.guoguo.org.cn/Upload/ting/20260720161400.jpg" + poster)
        #expect(item["vod_actor"] == "青鸾峰上" && item["vod_director"] == "有声的紫襟" && item["vod_remarks"] == "完本")
        #expect(item["type_name"] == "" && item["vod_content"]?.count == 192 && item["vod_play_from"] == "堇夏")
        let episodes = try #require(item["vod_play_url"]?.components(separatedBy: "#"))
        #expect(episodes.count == 3977 && episodes.first == "1$" + firstChapter && episodes.last == "3977$" + lastChapter)
        #expect(item["vod_play_url"]?.count == 144934)
        // A ceiling against a gross regression only; the measured time goes in the task document.
        print("[W-103] detail of 3977 episodes in \(elapsed)")
        #expect(elapsed < .seconds(2))

        JinxiaSite.serve([:] as [String: Data])
        for id in ["", "/x/../y.html", "https://evil.example/a.html", "/wuxiaxuanhuan/2117", "/a b.html"] {
            #expect(try list(try await spider.detailContent(ids: [id])).isEmpty, "\(id)")
        }
        #expect(JinxiaSite.requests.isEmpty)
    }

    // Gate adaptations 3, 4 and 5, for two episodes as auto-next asks for them.
    @Test func playFetchesTheAudioWithTheRefererEveryTime() async throws {
        let spider = try await jinxia()
        JinxiaSite.serve([firstChapter: try chapterFirst(), lastChapter: try chapterLast(), neoplay: try neoplayFirst()])
        var play = try object(try await spider.playerContent(flag: "堇夏", id: "1$" + firstChapter, vipFlags: []))
        #expect(play["url"] as? String == audio + "0001.m4a" && play["parse"] as? Int == 0)
        #expect(play["header"] as? [String: String] == ["User-Agent": chrome, "Referer": "https://m.ting15.com/"])
        let post = try #require(JinxiaSite.requests.last)
        #expect(post.method == "POST" && post.url.absoluteString == "https://m.ting15.com/?s=api-getneoplay")
        #expect(post.body == "bookId=2117&isPay=11&page=1&xt=94b982cb2394023dd698088b615eccc8")
        #expect(header(post, "Referer") == "https://m.ting15.com" + firstChapter && header(post, "User-Agent") == chrome)

        JinxiaSite.serve([firstChapter: try chapterFirst(), lastChapter: try chapterLast(), neoplay: try neoplayLast()])
        play = try object(try await spider.playerContent(flag: "堇夏", id: String(lastChapter.dropFirst()), vipFlags: []))
        #expect(play["url"] as? String == audio + "3977.m4a")
        #expect(play["header"] as? [String: String] == ["User-Agent": chrome, "Referer": "https://m.ting15.com/"])
        #expect(JinxiaSite.requests.last?.body.contains("page=3977") == true)
    }

    @Test func playReadsTheReplyCarefullyAndFallsBackToThePlayer() async throws {
        let spider = try await jinxia()
        func played(_ reply: String, page: Data = chapter()) async throws -> String {
            JinxiaSite.serve([firstChapter: page, neoplay: Data(reply.utf8)])
            return try #require(try object(try await spider.playerContent(flag: "", id: firstChapter, vipFlags: []))["url"] as? String)
        }
        // No BOM, an escaped address kept as is, ourl when url is empty.
        #expect(try await played(#"{"status":1,"url":"https://a.example/%E4%B8%80/1.m4a"}"#) == "https://a.example/%E4%B8%80/1.m4a")
        #expect(try await played(#"{"status":"1","url":"","ourl":"https://a.example/二/2.m4a"}"#) == "https://a.example/%E4%BA%8C/2.m4a")
        // A refused or broken reply falls back to the page's <audio>, then to nothing (never the chapter page).
        let page = chapter(audio: "https://b.example/3.m4a")
        #expect(try await played(#"{"status":0,"url":"https://a.example/x.m4a"}"#, page: page) == "https://b.example/3.m4a")
        #expect(try await played("not json", page: page) == "https://b.example/3.m4a")
        #expect(try await played(#"{"status":1,"url":"ftp://a.example/x"}"#) == "")
        #expect(try await played(#"{"status":0}"#) == "")
        JinxiaSite.serve([:] as [String: Data])
        #expect(try object(try await spider.playerContent(flag: "", id: "/x/../y.html", vipFlags: []))["url"] as? String == "")
        #expect(JinxiaSite.requests.isEmpty)
    }

    @Test func aServerErrorSaysWhichHostFailed() async throws {
        let spider = try await jinxia()
        JinxiaSite.serve(["/wuxiaxuanhuan/": (500, Data())])
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "m.ting15.com")) {
            _ = try await spider.categoryContent(tid: "wuxiaxuanhuan", page: "1", filter: false, extend: [:])
        }
    }
}

/// `home.html` from the W-95 gate (10489 bytes), raw-deflated.
private let homePacked = """
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
/Zrj/wE=
"""

/// `category-p1.html` from the W-95 gate (7592 bytes), raw-deflated.
private let categoryOnePacked = """
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
"""

/// `category-p2-adapted.html` from the W-95 gate (7535 bytes), raw-deflated.
private let categoryTwoPacked = """
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
"""

/// `category-order-hits-p1.html` from the W-95 gate (7613 bytes), raw-deflated.
private let categoryHitsPacked = """
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
"""

/// `search.html` from the W-95 gate (5204 bytes), raw-deflated.
private let searchPacked = """
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
"""

/// `detail.html` from the W-95 gate (313801 bytes), raw-deflated.
private let detailPacked = """
7N1bs13XeZ/5a+dToHGVVJkE3uMYQ6HY1ZXuq1x0qrq7qvtKBZEQCRsEaAK0pFxJsuXIkmPJjo+xEtvttqOOJUtJZFtnfZeYAMErf4VeILjfP3RKperxZatI
cWOvtcc67PeZa2389pzz77/7w5f+h//5f/1n//v/9S/+l2uvP3zj7sv/6KWn/7l299a91z58/V++/sIr966//I+uvfT67VuvXv577aU3bj+8de2V12+99eD2
ww9ff/vhx17Y16/d0EX3br1x+8PXf/nO7Y+/ef+th9evvXL/3sPb9y5X/fidVx++/uFXb//ynVduv/D+H37+2p17dx7euXX3hQev3Lp7+8P24s2fv/bG5XNv
vP3Gj3zq1id+/FNvP7j91vt/vvXRy6fu3b+6Cw/vPLx7++XHv/8nj3/3Nx79+m89+uM/fvzlX3/0Z9949I0vPvn6Nz/y+Gt/8c4P/uTd3/zVR9/+7kce//bX
nvzVf352+bv/9lff/eZfPvnzP/7I0z9/6avvfv+3XrrxbLEfe2T//PYnP37/rVcfPPfInr+5n/9Zt/3zj778lXe/88PHv/M3l+Wv/8QT9urtB6+8defNh3fu
3/sZKz+/2OV+P/nhN975zq89+ovPPP73X3787z71zne+8863/vXjP/j6O9/6zuXzT/7ss//n33/vN977zJ89+savPf76Xz5d6Fe/+M63f/3vv/dHH3zNN7/7
7uXLfurXPPnhH1wueHq9r333csHffeozl1u4XPToG//p6U199/fe+dZ/fPSNbz3+yn9879P/+r1/9ZuXiy5f/OwKlw8+uMLffvbRf/nGZZ0n3/zzv//ep589
6e/+ytee/Omnnl307p//+3e+/+XLV73zrd+5PCfvfOuy8p/NI37nh3/13r/77Sd/+pdPP/7Wdy/foEff/KMnf/2373z7C0/+9uuXu/Todz//6Ovfvty991f4
7pP/8NuXR/J3n/r8ZZ3Ll7z7ha8++sbn/+5TX3j0xb+53PTlLr37uW9frnm5wuPP/dbluXx2tWdXePIfPvP+Ff72suwH35q7d+794rW3bt/98PVXbt27f+/O
ZdSuX3v9rdsf+/D1Gx9/+xN3bn3i7Vv3Xr/8e8PN1otPm/mRDF5/+PDNF27/0tt3fvnD1//ZrVdev/3CP7t8U9+6f/e57+69+y88fOvWvQcfu//WGz+loaef
vvXwhVdvP7z9yo/NxcPbd2+/+fr9e8+P/vv3+IN7ePfOrXsP79x77cYbb7z4yoPLrL7/SB48/OTd2w9ev3374bOveenGB1W/9NH7r37y2p1XLw/Wr7+/2Kt3
fvn9P3/8rVtvvnn7rfc/+WwjcPut9z9+dpVX7t568OByd+6/efnw9q0PrvejF969/9r9q89fe+nW1V28/vJzpd26+robly/8KWs8zf2yxs9d+7nnlrh24869
V29/4sU3X3/zf3zw4RvvbxJeuTw9l/9cbvPOvQ++KU8fxtPLPvL+J68/v+TVp95/du7d/9j9u3fvf/z6yy89ePPWvZff/cPvPvr+7/7jR1/8+js//HePvvYH
z8p98lffuHz2n7x04/3rPL3nP37Hn//w3q15CM8+fP450lNxdZ3Xr7/83l/83nt/+tfvPyM/99xVfnTkrl97f9N02T48tz2bVZ5+D5+/4Nlizz9zN37x/r3X
Pvr2ZWJe++Sd51b79Jcef+r33v30Xz/63me0Wl9We+6Cn7Law7fv3L3z9M79yGK/+ZV3v/Rrjz/z1Xd/77e02Los9twFP2WxV99+8PqdT96690tPx3dWe+9X
vv/oW5958pVPPf6Vz2q1ujxfz13wU1b7hTu3nnZw9+17d5+7b4/+6m8efedr73zvLy53RKud6y8/f8FPWe3jt+994u3bl1eo1/7l628/v9wfPPryd558+jcu
/6/l7OlyuuCn3rl7r716KfXNy38fPL/gu9/94qPPfuvJ13/1nW//hRbc119+/oJZ8Om/T1d9ttV4fTZTv/T2J+984s4vPbfu4z/6z09+/TuPP/fFywdaN65f
e3/LcHkRuvPgzbu3Pvmhywbv9uUb9dy1n97Yz7qdy2Q+vf+37712+ej+5cE890D+6FvPXrMe/ZtP6wbzZ9zg89f+b93gJ+/c++Tbt597/j///7775T9574//
y3v/93OjZjd/xs08f/UJWN+WX7j1y7eevRZ/6J/Oam/cf+v29Wv3771y984rv/jsj//44et3HvyTp0/TNx/9P//2v/7av5nN2Es3LrE/22LeeG6T+fwG7cFl
Q/DK6x/56P1PXP/JzekHFz7d2v+0DeqDj9y59+bbD7VNff+P1x5+8s3bT18ZPvHw2Tbv2SrXr10e+Su3X79/93I3Pnz9MjePvvSvb1xed5986rM3Lu+ALk/D
09ftv/jMh9776vcefenb7376689eAX98a/z8jXz07YcP72tT+uAjH31479mNXj743z643Rs/vjl87qOnG8/3r//wzpuX7e2zjemzS5691l0t/dH793/xzr2P
3f8pz9LTi37a0/PRO2+89txz88Zr156987xufpmI12/fee31yyuo9dPxeOuVy1xdXqkffOjGjcs1X3i65gv3Hzx48bW371/+efH+W6+9+Mq9G//Hm3fv33r1
xvuvqH7T++bym9aWN2+++Atvvnb92q27/433avNM/MxXt48+9wifvsraj7yBvcyQzWVvvnz1Pfu3P/bG9aUbbz53rWff4Mu1Lu+h3vvWD95/I/b5H73Ku5//
m8ef+vTlKo/+6jcef/mrP3rh49//m/d+/5uXC58+3Bdurhf85jXrD9n6kPWP3dK3vvDk+9+/XHMCunpCP/7xj794+UHh3mtPn7d68ZX7bzxN9tZbrz39weEj
H738hHH5/r30scuUX97Y3L1/mc63br962Qr85x9c+v/gGfzs5d3jt5/dxEs3nl71/Zdc3YOf8bp79fbl7p0HlzdMM6gf/PHq3l/7mS+wT9/T3bj5gj17C3F5
jJ9//NU/vbz6P/rcN9796lftvT/6Nb1nee5/H9yFn7v2E8N65+l7v9kePX0gL3z8/Un80LWPXtL8p9eedvvCrbt3Xrv3oWvP3sT80+s/dgM/8QS/8faDO6+8
+PD+/bsPXnz1/sfvPR3SF968/+Dhi7/wL1958d7thzfMqvuD90E//sw/e1b/p3/xL57/weS5bdj7D+VnPJCrZ//Nl///H0D+oX8A+a+f+p3LP5cr/Fjgz8K/
/PHpCs9tHy4rPPn+V5/8q//4znd+8/Jm+t3vfvnJX//q4+986dFv/8blj4+++IXLRU/+9HIPP//O9/7kcgcurb/7l3/4znc/+/iLX3rnB3/0zvd/88k3v/Lk
6797eQaevRI8+Q+//ugHv//kh3/43q985Sdv69m9ujxvl0gf/eBzj/78+0+f/K//7ePPfOXJN7/2zre/8fhrf/bur3/u2cvr5Wl//F9+99EPvnD5ksd/8JvP
byVu3Lvz9A3jvRsfu/vgjRffvPfaT07ou5/59qN/9d3Hf/zn7375Cz+S/Y+n/sFsPn2Nf5r4jOfr/vKjz/3apdZnw/2PH332P8VZ6/KJyxv4y4U/uSl+8/mv
/7nLnf3g8x+7/t+1obCfulm49t+9jn+wjsN14oN1Aq6TH6yTcJ36YJ2C63ywLXu54Tof/MD+8oLr7A/W2XCd88E6B65jN68G8SZdaUaazrRdDbXRqbarsTY6
13Y12EYn265G2+hs29VwG53uq7+PetnofNvVgBudcLsacaMz7lcz7nTG/WrGHW+3Z8NNZ9yvZtzpjPvVjDudcb+acacz7lcz7nTG/WrGnc64X8240xn3qxl3
OuNxNeNBZzyuZjzojMfVjAd+dzJvT+iMx9WMB53xuJrxoDMeVzMedMbjasaDznhczXjQGY+rGQ8643k140lnPK9mPOmM59WMJ53xvJrxxO/B5004nfG8mvGk
M55XM550xvNqxpPOeF7NeNIZz6sZTzrjdTXjRWe8rma86IzX1YwXnfG6mvGiM15XM174J835UZPOeF3NeNEZr6sZLzrjdTXjRWe8rma86Iz31Yw3nfG+mvGm
M95XM950xvtqxpvOeF/NeNMZ76sZb/z3KfMXKnTG+2rGm854X8140xnvqxlvOuPrasYXnfF1NeOLzvi6mvFFZ3xdzfiiM76uZnzRGV9XM77ojK+rGV/4bw3n
rw3pjK+rGV90xtfVjC864/tqxjed8X0145vO+L6a8U1nfF/N+KYzvq9mfNMZ31czvumM76sZ33TG99WMb/x34/OX43TG99WMbzrj52rGD53xczXjh874uZrx
Q2f8XM34oTN+rmb80Bk/VzN+6Iyfqxk/dMbP1YwfOuPnasYPFqAhIG5AQiCsQDeHgW5iB7o5EHQTS9DNoaCb2IJuDgbdxBp0czjoJvagmwNCN7EI3RwSuolN
6Oag0E2sQjeHhW7iuRd+/gPop/gTz70AlAuoCJQbqBCUK6gYlDuoIJRLqCiUW6gwlGuoOBR7qA2IGhZRGxI15+4v+MdzPyxq2EVtYNSwjNrQqGEbtcFRwzpq
w6OGfdQGSA0LqQ2RGjZSGyQ1rKQ2TGrYSW2g1IL/xot+5QXP/WCpYS214VLDXmoDpobF1IZMDZupDZoaVlMbNjXspjZwalhObejUsJ3a4KlhPbXhU0v+u176
ZS8890Oohg3VBlENK6oNoxp2VBtINSypNpRq2FJtMNWwptpwqmFPtQFVw6JqQ6qGTdUGVa34bznq1xzx3A+sGpZVG1o1bKs2uGpYV2141bCv2gCrYWG1IVbD
xmqDrIaV1YZZDTurDbQallYbarXmv9+rX/DFcz/cathbbcDVsLjakKthc7VBV8PqasOuht3VBl4Ny6sNvRq2Vxt8NayvNvxq2F9tANYW/812/Wo7nvtBWMMK
a8Owhh3WBmINS6wNxRq2WBuMNayxNhxr2GNtQNawyNqQrGGTtUFZwyprw7K2+T4d2qkDz/3QrGGbtcFZwzprw7OGfdYGaA0LrQ3RGjZaG6Q1rLQ2TGvYaW2g
1rDU2lCtYau1wVo7fG8m7c7E92fSDk14j6bxWsde6+O1jr3Wx2sde62P1zr2Wh+vdey1Pl7r2Gt9vNax1/p4rWOv9fFax17r47VufE8+7cqH53681rHX+nit
Y6/18VrHXuvjtY691sdrHXutj9c69lofr3XstT5e63z/Ve3Ayvdg1S6s/wD7sGonVjz32o2V78eqHVn5nqzalZXvy6qdWfnerNqdle/Pqh1a+R6t2qUVe62P
1zr2Wh+vdey1Pl7rwffe1u7beO7Hax17rY/XOvZaH6917LU+XuvYa3281rHX+nitY6/18VrHXuvjtY691sdrHXutj9d68uMW6MAFeO7Hax17rY/XOvZaH691
7LU+XuvYa3281rHX+nitY6/18VrHXuvjtY691sdrHXutj9d68SN26JAdeO7Hax17rY/XOvZaH6917LU+XuvYa3281rHX+nitY6/18VrHXuvjtY691sdrHXut
j9d682PV6GA1eO7Hax17rY/XOvZaH6917LU+XuvYa3281rHX+nitY6/18VrHXuvjtY691sdrHXutj9f64kdp0mGa8NyP1zr2Wh+vdey1Pl7r2Gt9vNax1/p4
rWOv9fFax17r47WOvdbHax17rY/XOvZaH6/1zY9PpgOU4bkfr3XstT5e69hrfbzWsdf6eK1jr/XxWsde6+O1jr3Wx2sde62P1zr2Wh+vdey1Pl7rhx+ZT4fm
48fm08H58NH5xmsDe22M1wb22hivDey1MV4b2GtjvDaw18Z4bWCvjfHawF4b47WBvTbGawN7bYzXhvGjUuqwlHjux2sDe22M1wb22hivDey1MV4b2GtjvDaw
18Z4bWCvjfHawF4b47WBvTbGawN7bYzXhvPjseqArHjux2sDe22M1wb22hivDey1MV4b2GtjvDaw18Z4bWCvjfHa4Mcg1kGI+VGIdRhifhxiHYj4H+BIxDoU
MZ57HYyYH41YhyPmxyPWAYn5EYl1SGJ+TGIdlJgflViHJcZeG+O1gb02xmsDe22M1wb22hivjeTH4NZBuPHcj9cG9toYrw3stTFeG9hrY7w2sNfGeG1gr43x
2sBeG+O1gb02xmsDe22M1wb22hivjeJHn9fh5/Hcj9cG9toYrw3stTFeG9hrY7w2sNfGeG1gr43x2sBeG+O1gb02xmsDe22M1wb22hivjebnXdCJF/Dcj9cG
9toYrw3stTFeG9hrY7w2sNfGeG1gr43x2sBeG+O1gb02xmsDe22M1wb22hivjcXPOKJTjuC5H68N7LUxXhvYa2O8NrDXxnhtYK+N8drAXhvjtYG9NsZrA3tt
jNcG9toYrw3stTFeG5ufa0cn28FzP14b2GtjvDaw18Z4bWCvjfHawF4b47WBvTbGawN7bYzXBvbaGK8N7LUxXhvYa2O8Ng4/y5ROM8XPM6UTTeEzTY3XJvba
HK9N7LU5XpvYa3O8NrHX5nhtYq/N8drEXpvjtYm9NsdrE3ttjtcm9tocr03jZ1jTKdbw3I/XJvbaHK9N7LU5XpvYa3O8NrHX5nhtYq/N8drEXpvjtYm9Nsdr
E3ttjtcm9tocr03n5xbUyQXx3I/XJvbaHK9N7LU5XpvYa3O8NrHX5nhtYq/N8drEXpvjtYm9NsdrE3ttjtcm9tocr83gZ9XUaTXx3I/XJvbaHK9N7LU5XpvY
a3O8NrHX5nhtYq/N8drk55HViWT5mWR1Kll+LlmdTJafTVank/0HOJ+sTiiL516nlOXnlNVJZflZZXVaWX5eWZ1Ylp9ZVqeWxV6b47WJvTbHaxN7bY7XJvba
HK9N7LU5XpvFz6SsUynjuR+vTey1OV6b2GtzvDax1+Z4bWKvzfHaxF6b47WJvTbHaxN7bY7XJvbaHK9N7LU5XpvNzyGuk4jjuR+vTey1OV6b2GtzvDax1+Z4
bWKvzfHaxF6b47WJvTbHaxN7bY7XJvbaHK9N7LU5XpvYa3O8NrHX5nhtYq/N8drEXpvjtYm9NsdrE3ttjtcm9tocr03stTlem9hrc7w2sdfmeG1ir83x2sRe
m+O1ib02x2sTe22O1yb22hyvTey1OV6b2GtzvDax1+Z4bWKvzfHaxF6b47WJvTbHaxN7bY7XJvbaHK9N7LU1XlvYa2u8trDX1nhtYa+t8drCXlvjtYW9tsZr
C3ttjdcW9toary3stTVeW9hra7y2sNfWeG1hr63x2sJeW+O1hb22xmsLe22N1xb22hqvLey1NV5b2GtrvLaw19Z4bWGvrfHawl5b47WFvbbGawt7bY3XFvba
Gq8t7LU1XlvYa2u8trDX1nhtYa+t8drCXlvjtYW9tsZrC3ttjdcW9toary3stTVeW9hra7y2sNfWeG1hr63x2sJeW+O1hb22xmsLe22N1xb22hqvLey1NV5b
2GtrvLaw19Z4bWGvrfHawl5b47WFvbbGawt7bY3XFvbaGq8t7LU1XlvYa2u8trDX1nhtYa+t8drCXlvjtYW9tsZrC3ttjdcW9toary3stTVeW9hra7y2sNfW
eG1hr63x2sJeW+O1hb22xmsLe22N1xb22hqvLey1NV5b2GtrvLaw19Z4bWGvrfHawl5b47WFvbbGawt7bY3XFvbaGq8t7LU1XlvYa2u8trDX1nhtYa+t8drC
XlvjtYW9tsZrC3ttjdcW9toary3stTVeW9hra7y2sNfWeG1hr63x2sJeW+O1hb22xmsLe22N1xb22hqvLey1NV5b2GtrvLaw19Z4bWGvrfHawl5b47WFvbbG
awt7bY3XFvbaGq8t7LU1XlvYa2u8trDX1nhtYa+t8drCXtvjtY29tsdrG3ttj9c29toer23stT1e29hre7y2sdf2eG1jr+3x2sZe2+O1jb22x2sbe22P1zb2
2h6vbey1PV7b2Gt7vLax1/Z4bWOv7fHaxl7b47WNvbbHaxt7bY/XNvbaHq9t7LU9XtvYa3u8trHX9nhtY6/t8drGXtvjtY29tsdrG3ttj9c29toer23stT1e
29hre7y2sdf2eG1jr+3x2sZe2+O1jb22x2sbe22P1zb22h6vbey1PV7b2Gt7vLax1/Z4bWOv7fHaxl7b47WNvbbHaxt7bY/XNvbaHq9t7LU9XtvYa3u8trHX
9nhtY6/t8drGXtvjtY29tsdrG3ttj9c29toer23stT1e29hre7y2sdf2eG1jr+3x2sZe2+O1jb22x2sbe22P1zb22h6vbey1PV7b2Gt7vLax1/Z4bWOv7fHa
xl7b47WNvbbHaxt7bY/XNvbaHq9t7LU9XtvYa3u8trHX9nhtY6/t8drGXtvjtY29tsdrG3ttj9c29toer23stT1e29hre7y2sdf2eG1jr+3x2sZe2+O1jb22
x2sbe22P1zb22h6vbey1PV7b2Gt7vLax1/Z4bWOv7fHaxl7b47WNvbbHaxt7bY/XNvbaHq9t7LU9XtvYa3u8trHX9nhtY6/t8drGXtvjtY29tsdrG3ttj9c2
9toer23stWu8dmGvXeO1C3vtGq9d2GvXeO3CXrvGaxf22jVeu7DXrvHahb12jdcu7LVrvHZhr13jtQt77RqvXdhr13jtwl67xmsX9to1Xruw167x2oW9do3X
Luy1a7x2Ya9d47ULe+0ar13Ya9d47cJeu8ZrF/baNV67sNeu8dqFvXaN1y7stWu8dmGvXeO1C3vtGq9d2GvXeO3CXrvGaxf22jVeu7DXrvHahb12jdcu7LVr
vHZhr13jtQt77RqvXdhr13jtwl67xmsX9to1Xruw167x2oW9do3XLuy1a7x2Ya9d47ULe+0ar13Ya9d47cJeu8ZrF/baNV67sNeu8dqFvXaN1y7stWu8dmGv
XeO1C3vtGq9d2GvXeO3CXrvGaxf22jVeu7DXrvHahb12jdcu7LVrvHZhr13jtQt77RqvXdhr13jtwl67xmsX9to1Xruw167x2oW9do3XLuy1a7x2Ya9d47UL
e+0ar13Ya9d47cJeu8ZrF/baNV67sNeu8dqFvXaN1y7stWu8dmGvXeO1C3vtGq9d2GvXeO3CXrvGaxf22jVeu7DXrvHahb12jdcu7LVrvHZhr13jtQt77Rqv
Xdhr13jtwl67xmsX9to1Xruw167x2oW9do3XLuy1a7x2Ya9d47ULe+0ar13Ya9d47cJeu8ZrF/baNV67sNeu8dqFvXaN1y7stWu8dmGvXeO1C3vtGq9d2GvX
eO3CXrvHazf22j1eu7HX7vHajb12j9du7LV7vHZjr93jtRt77R6v3dhr93jtxl67x2s39to9Xrux1+7x2o29do/Xbuy1e7x2Y6/d47Ube+0er93Ya/d47cZe
u8drN/baPV67sdfu8dqNvXaP127stXu8dmOv3eO1G3vtHq/d2Gv3eO3GXrvHazf22j1eu7HX7vHajb12j9du7LV7vHZjr93jtRt77R6v3dhr93jtxl67x2s3
9to9Xrux1+7x2o29do/Xbuy1e7x2Y6/d47Ube+0er93Ya/d47cZeu8drN/baPV67sdfu8dqNvXaP127stXu8dmOv3eO1G3vtHq/d2Gv3eO3GXrvHazf22j1e
u7HX7vHajb12j9du7LV7vHZjr93jtRt77R6v3dhr93jtxl67x2s39to9Xrux1+7x2o29do/Xbuy1e7x2Y6/d47Ube+0er93Ya/d47cZeu8drN/baPV67sdfu
8dqNvXaP127stXu8dmOv3eO1G3vtHq/d2Gv3eO3GXrvHazf22j1eu7HX7vHajb12j9du7LV7vHZjr93jtRt77R6v3dhr93jtxl67x2s39to9Xrux1+7x2o29
do/Xbuy1e7x2Y6/d47Ube+0er93Ya/d47cZeu8drN/baPV67sdfu8dqNvXaP127stXu8dmOv3eO1G3vtHq/d2Gv3eO3GXrvHazf22j1eu7HX7vHajb12j9du
7LVnvPZgrz3jtQd77RmvPdhrz3jtwV57xmsP9tozXnuw157x2oO99ozXHuy1Z7z2YK8947UHe+0Zrz3Ya8947cFee8ZrD/baM157sNee8dqDvfaM1x7stWe8
9mCvPeO1B3vtGa892GvPeO3BXnvGaw/22jNee7DXnvHag732jNce7LVnvPZgrz3jtQd77RmvPdhrz3jtwV57xmsP9tozXnuw157x2oO99ozXHuy1Z7z2YK89
47UHe+0Zrz3Ya8947cFee8ZrD/baM157sNee8dqDvfaM1x7stWe89mCvPeO1B3vtGa892GvPeO3BXnvGaw/22jNee7DXnvHag732jNce7LVnvPZgrz3jtQd7
7RmvPdhrz3jtwV57xmsP9tozXnuw157x2oO99ozXHuy1Z7z2YK8947UHe+0Zrz3Ya8947cFee8ZrD/baM157sNee8dqDvfaM1x7stWe89mCvPeO1B3vtGa89
2GvPeO3BXnvGaw/22jNee7DXnvHag732jNce7LVnvPZgrz3jtQd77RmvPdhrz3jtwV57xmsP9tozXnuw157x2oO99ozXHuy1Z7z2YK8947UHe+0Zrz3Ya894
7cFee8ZrD/baM157sNee8dqDvfaM1x7stWe89mCvPeO1B3vtGa892GvPeO3BXnvGaw/22jNee7DXnvHag732jNce7LVnvPZgrz3jtQd77RmvPdhrz3jtwV5r
Nwdsn37IVzOtZnw112rOVwutFny11GrJVyutVny11mrNV1tabfHVtlbbfLWj1XgLphaMt2BqwXgLphaMt2BqwXgLphaMt2BqwXgLphaMt2BqwXgLphaMt2Bq
wXgLrhact+BqwXkLrhact+BqwXkLrhact+BqwXkLrhact+BqwXkLrhact+BqwXkLoRaCtxBqIXgLoRaCtxBqIXgLoRaCtxBqIXgLoRaCtxBqIXgLoRaCtxBq
IXgLqRaSt5BqIXkLqRaSt5BqIXkLqRaSt5BqIXkLqRaSt5BqIXkLqRaSt5BqIXkLpRaKt1BqoXgLpRaKt1BqoXgLpRaKt1BqoXgLpRaKt1BqoXgLpRaKt1Bq
oXgLrRaat9BqoXkLrRaat9BqoXkLrRaat9BqoXkLrRaat9BqoXkLrRaat9BqoXkLSy0s3sJSC4u3sNTC4i0stbB4C0stLN7CUguLt7DUwuItLLWweAtLLSze
wlILi7ew1cLmLWy1sHkLWy1s3sJWC5u3sNXC5i1stbB5C1stbN7CVgubt7DVwuYtbLWweQtHLRzewlELh7dw1MLhLRy1cHgLRy0c3sJRC4e3cNTC4S0ctXB4
C0ctHN7CUQvcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNyd
Te5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNyd
Te5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNyd
Te5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNyd
Te5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNyd
Te5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydTe5s3J1N7mzcnU3ubNydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7Nyd
Xe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7Nyd
Xe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7Nyd
Xe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7Nyd
Xe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7Nyd
Xe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7NydXe7s3J1d7uzcnV3u7Nyd
Xe7s3J1d7uzcnV3u7NydXe7s3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNyd
Q+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNyd
Q+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNyd
Q+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNyd
Q+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNyd
Q+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnUPuHNydQ+4c3J1D7hzcnVPunNydU+6c3J1T7pzcnVPunNyd
U+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNyd
U+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNyd
U+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNyd
U+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNyd
U+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNyd
U+6c3J1T7pzcnVPunNydU+6c3J1T7pzcnVPunNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNyd
S+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNyd
S+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNyd
S+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNyd
S+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNyd
S+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1L7lzcnUvuXNydS+5c3J1b7tzcnVvu3Nyd
W+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3Nyd
W+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3Nyd
W+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3Nyd
W+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3Nyd
W+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3Nyd
W+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnVvu3NydW+7c3J1b7tzcnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLn
xd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0X
d+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17c
nZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3
XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15
yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cld17cnZfceXF3XnLnxd15yZ0Xd+cl
d17cnZfceXF3XnLnxd15yZ0Xd+cld17cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfc
eXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLn
zd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503
d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97c
nbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN3
3nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15y503d+ctd97cnbfceXN33nLnzd15
y503d+ctd97cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cj
dz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c
+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLn
w935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0P
d+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7c
nY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7cnY/c+XB3PnLnw935yJ0Pd+cjdz7Ynf3muPPT
D/lqptWMr+ZazflqodWCr5ZaLflqpdWKr9ZarflqS6stvtrWapuvdrQab8HUgvEWTC0Yb8HUgvEWTC0Yb8HUgvEWTC0Yb8HUgvEWTC0Yb8HUgvEWTC0Yb8HV
gvMWXC04b8HVgvMWXC04b8HVgvMWXC04b8HVgvMWXC04b8HVgvMWXC04byHUQvAWQi0EbyHUQvAWQi0EbyHUQvAWQi0EbyHUQvAWQi0EbyHUQvAWQi0EbyHV
QvIWUi0kbyHVQvIWUi0kbyHVQvIWUi0kbyHVQvIWUi0kbyHVQvIWUi0kb6HUQvEWSi0Ub6HUQvEWSi0Ub6HUQvEWSi0Ub6HUQvEWSi0Ub6HUQvEWSi0Ub6HV
QvMWWi00b6HVQvMWWi00b6HVQvMWWi00b6HVQvMWWi00b6HVQvMWWi00b2GphcVbWGph8RaWWli8haUWFm9hqYXFW1hqYfEWllpYvIWlFhZvYamFxVtYamHx
FrZa2LyFrRY2b2Grhc1b2Gph8xa2Wti8ha0WNm9hq4XNW9hqYfMWtlrYvIWtFjZv4aiFw1s4auHwFo5aOLyFoxYOb+GohcNbOGrh8BaOWji8haMWDm/hqIXD
WzhqgbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27
s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27
s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27
s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27
s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27
s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PJnY27s8mdjbuzyZ2Nu7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27
s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27
s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27
s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27
s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27
s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27s8udnbuzy52du7PLnZ27
s8udnbuzy52du7PLnZ27c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7
c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7
c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7
c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7
c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7
c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyJ2Du3PInYO7c8idg7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7
c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7
c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7
c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7
c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7
c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PKnZO7
c8qdk7tzyp2Tu3PKnZO7c8qdk7tzyp2Tu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7
c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7
c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7
c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7
c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7
c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8mdi7tzyZ2Lu3PJnYu7c8udm7tzy52bu3PLnZu7
c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7
c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7
c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7
c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7
c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7
c8udm7tzy52bu3PLnZu7c8udm7tzy52bu3PLnZu7c8udm7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+5
8+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTO
i7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv
7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4
Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+Lu
vOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vzkjsv7s5L7ry4Oy+58+LuvOTOi7vz
kjsv7s5L7ry4Oy+58+LuvOTOi7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b
7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+5
8+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXO
m7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv
7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5
O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+buvOXOm7vzljtv7s5b7ry5O2+58+bu
vOXOm7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vz
kTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H
7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+5
8+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTO
h7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf
7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOh7vzkTsf7s5H7ny4Ox+58+HufOTOB7tz3Bx3fvohX820
mvHVXKs5Xy20WvDVUqslX620WvHVWqs1X21ptcVX21pt89WOVuMtmFow3oKpBeMtmFow3oKpBeMtmFow3oKpBeMtmFow3oKpBeMtmFow3oKpBeMtuFpw3oKr
BectuFpw3oKrBectuFpw3oKrBectuFpw3oKrBectuFpw3oKrBecthFoI3kKoheAthFoI3kKoheAthFoI3kKoheAthFoI3kKoheAthFoI3kKoheAtpFpI3kKq
heQtpFpI3kKqheQtpFpI3kKqheQtpFpI3kKqheQtpFpI3kKqheQtlFoo3kKpheItlFoo3kKpheItlFoo3kKpheItlFoo3kKpheItlFoo3kKpheIttFpo3kKr
heYttFpo3kKrheYttFpo3kKrheYttFpo3kKrheYttFpo3kKrheYtLLWweAtLLSzewlILi7ew1MLiLSy1sHgLSy0s3sJSC4u3sNTC4i0stbB4C0stLN7CVgub
t7DVwuYtbLWweQtbLWzewlYLm7ew1cLmLWy1sHkLWy1s3sJWC5u3sNXC5i0ctXB4C0ctHN7CUQuHt3DUwuEtHLVweAtHLRzewlELh7dw1MLhLRy1cHgLRy1w
dza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNx
dza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNx
dza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNx
dza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNx
dza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNx
dza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3NrmzcXc2ubNxdza5s3F3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNz
d3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNz
d3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNz
d3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNz
d3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNz
d3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNzd3a5s3N3drmzc3d2ubNz
d3a5s3N3drmzc3cOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNw
dw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNw
dw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNw
dw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNw
dw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNw
dw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwdw65c3B3DrlzcHcOuXNwd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNy
d065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNy
d065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNy
d065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNy
d065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNy
d065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNyd065c3J3TrlzcndOuXNy
d065c3J3TrlzcndOuXNyd065c3J3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNx
dy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNx
dy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNx
dy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNx
dy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNx
dy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXcuuXNxdy65c3F3LrlzcXduuXNzd265c3N3brlzc3duuXNz
d265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNz
d265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNz
d265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNz
d265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNz
d265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNz
d265c3N3brlzc3duuXNzd265c3N3brlzc3duuXNzd15y58XdecmdF3fnJXde3J2X3Hlxd15y58XdecmdF3fnJXde3J2X3Hlxd15y58XdecmdF3fnJXde3J2X
3Hlxd15y58XdecmdF3fnJXde3J2X3Hlxd15y58XdecmdF3fnJXde3J2X3Hlxd15y58Xdecmd1/9Xmv31xnFWYQC/rqV8h9XChS11d2NF1XkeJzaEiiLUSEht
uY7Gu2t77PWO2dnECZGlEJLitMRNEEJNcRRoMQQlSo0ggPKvHwbv2rnKV2DGa/tJCpUQz17Mzsz77+i871mt9PPdOeTO4btzyJ3Dd+eQO4fvziF3Dt+dQ+4c
vjuH3Dl8dw65c/juHHLn8N055M7hu3PIncN355A7h+/OIXcO351D7hy+O4fcOXx3Drlz+O4ccufw3TnkzuG7c8idw3fnkDuH784hdw7fnUPuHL47h9w5fHcO
uXP47hxy5/DdOeTO4btzyJ3Dd+eQO4fvziF3Dt+dQ+4cvjuH3Dl8dw65c/juHHLn8N055M7hu3PIncN355A7h+/OIXcO351D7hy+O4fcOXx3Drlz+O4ccufw
3TnkzuG7c8idw3fnkDuH784hdw7fnUPuHL47h9w5fHcOuXP47hxy5/DdOeTO4btzyJ3Dd+eQO4fvziF3Dt+dQ+4cvjuH3Dl8dw65c/juHHLn8N055M7hu3PI
ncN355A7h+/OIXcO351D7hy+O4fcOXx3Drlz+O4ccufw3TnkzuG7c8idw3fnkDuH784hdw7fnUPuHL47h9w5fHcOuXP47hxy5/DdOeTO4btzyJ3Dd+eQO4fv
ziF3Dt+dQ+4cvjuH3Dl8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4M
uTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M
350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dn
yJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn
+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47
Q+4M350hd4bvzpA7w3dnyJ3huzPkzvDdGXJn+O4MuTN8d4bcGb47Q+4M350hd4bvzpA7w3dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ7
03dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ703dnyp3puzPlzvTd
mXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bc
mb47U+5M350pd6bvzpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bv
zpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+5M350pd6bvzpQ703dnyp3puzPlzvTdmXJn+u5MuTN9d6bcmb47U+7Mb3Ln0ZSNVnp+1KjbU4283eyn
WXf0NJdl/XavkvcvdtrT1ZWk1Uq787XZrN/Plqcmjx9fuVCdOTaaopjhMMRR+2FLGftBxNWZ4eb1wc0Hu89ulYEdG3uj/By1L/T7K1ONxurqar1frDP5Vr2Z
LTe+k08vJyu1fCFbraWt2mySts7VOuly2q9NHgpDpdfuTFe72VzW6WSr1Uo/6c23+9PVs7OdpLtUndm9/Xzw+I+Dze3Bb5//3yv38vxg3RP/47Lvvf/+3sPP
X3x6bbSmUn1wv3KY2WbWyXpT35qbm8Xx4yf77Qv9WtJJ57tTzXa32ICTc1m3X8vTn7anJk+UOR9cu7H3ty8GX2wPP914+fSz4eaD3fu39x5dHT6+ObyzVVx3
Hm8USd59svny6S93r68P7/x88OxXg427O8829y5fG16/XGxE0bT38VZxs/P80e5HXw6v3Nv97GrZc/3PZdOX/yim2vnq94NbH+3e3SreDNdv7Tx5MNj+cPf+
x4Mbf915vL7zZGuw/rsXt//wr8tXXlx5uPvwL0UwSWs57X5Xaazs/PMXg/UPh1fv7m1//vLpz4Yb9/Zu3Gwu9LLl9nD9N3kyl/TS4aNP9v60Prh9r4x3604R
y/DXfy9OyvDq9cFX94tRp2Z7lcZMmb+VInvHxk7lzV660q80F5JeXub8xx+8U0O1kramq2dOn337R2fOfP/tD6qVvNcsDl4jby3Viz/BnaSxmNeKh9pKL6sX
cdYX8+pMcej3J5s5mnbmzOl62k3745fS1lT13R/Mn0jOL2Xp0g+Xvnc6f6/6ZnPpv7xdm3hlov2tHpVPWUoHFXYYdf/iSrHr5T43FpPzyejtYbBLRTUv5o3F
n5xr9y7WJuuon/jPUCuVo1jH5s5192u2TEa3OIBF6sfT1sTYpbHyU6l8u54sJhfGLxVjXqn/MoapSrXoX33z9ZZzvU7RUB7/hWKPakUNpLVeu5n1WnmtnPxs
UQzlz005rtJoDG5uDD7ZLga9Pkt+rtls5/lU5Si88VbSTyYql/aLL53bf6z3mlmrPT09OTF6/cZq2m1lq/VO1kzKQfWixLKkNT6x37rW7uTtUcev99sv5P0Z
i0hOjnrvX8tLM+vmWadd9J4fBTE2aijCXBt9vXpdmxhbGzvKdLl7B9s22p9OmnTLNDSWs1779V355r5LX+94qjGbtS4WR6JR/pTM/Bs=
"""

/// `chapter-first.html` from the W-95 gate (8292 bytes), raw-deflated.
private let chapterFirstPacked = """
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
rOp/x0Kfr/wzs/8/Cv4L
"""

/// `chapter-last.html` from the W-95 gate (8215 bytes), raw-deflated.
private let chapterLastPacked = """
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
"""

/// `neoplay-first.json` from the W-95 gate (163 bytes), raw-deflated.
private let neoplayFirstPacked = """
JY5NDoIwEIXvMmtop4Tyd5bZVCporJQwnRXxZC48klewjcnLl/ezed/35wQ5AkxwS2nniTTpyFyH+/ZgtUrMUvFY1byRlj1E55l0QoOkja1JOnvFwnYmsY01
mb1fytDjmMOw5LnvhjbTNxeSYbQLaUQ06tk6qICTS8IwmQri/0ou93Kg2NcP
"""

/// `neoplay-last.json` from the W-95 gate (163 bytes), raw-deflated.
private let neoplayLastPacked = """
JY5NDoIwEIXvMmvoD7YUOMtskFo0VkqYzsp4MhceySvYxuTly/vZvO/78wQ+IkxwzXmnCSXKRNTG23YnsXIqEulYxbKh5D2m2RPKrLRCqW2L3NuLqjQLsu2s
LnQ+1MGpsYQhlNn1gyn03Rl5GG1AeRqdEw8zQwOU58wEk24g/a+Ucq8Hqn39AA==
"""
