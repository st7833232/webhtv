import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import WebHTVCore

// IOS-POC-57B-7 (W-74): ShortXingya.js against the replies the live API returned on 2026-10-12 (W-51 gate: login,
// category 1, detail 4659; the login reply's token redacted and replaced by a fake one), the gate's login body as a
// golden vector, and hand-made edge replies (W-61 design D5).

/// Answers u.shytkjgs.com and app.whjzjx.cn by path (query ignored) and remembers every request.
final class XingyaSite: URLProtocol, @unchecked Sendable {
    struct Seen { let method: String; let url: URL; let headers: [String: String]; let body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: (status: Int, body: Data)]) { lock.withLock { replies = served; seen = [] } }
    static func serve(_ served: [String: Data]) { serve(served.mapValues { (200, $0) }) }
    static var requests: [Seen] { lock.withLock { seen } }
    static var logins: [Seen] { requests.filter { $0.url.host == "u.shytkjgs.com" } }
    static var calls: [Seen] { requests.filter { $0.url.host == "app.whjzjx.cn" } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["u.shytkjgs.com", "app.whjzjx.cn"].contains(request.url?.host ?? "")
    }
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
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append(Seen(method: request.httpMethod ?? "", url: url, headers: request.allHTTPHeaderFields ?? [:],
                                  body: String(decoding: body, as: UTF8.self)))
            return Self.replies[url.path] ?? (404, Data())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "application/json; charset=utf-8"])!,
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

private func category() throws -> Data { try fixture(categoryPacked, sha256: "3eee1d6db2d3ff3b136161c4451423c8ae82a59cf307f139690c4e5dcbb57f7b") }
private func detail() throws -> Data { try fixture(detailPacked, sha256: "431660c5e90e7a76135fd4f057f68e0d9d619b6aa569c7e13746c130a110f97b") }

private let loginPath = "/user/v3/account/login"
private let homePath = "/v1/theater/home_page"
private let detailPath = "/v2/theater_parent/detail"
private let searchPath = "/v3/search"
/// The gate's `login.redacted.json` shape with a made-up token; no real token is in this file.
private func loginReply(_ token: String) -> Data { Data(#"{"code":"ok","data":{"user_id":99721588,"token":"\#(token)"}}"#.utf8) }
private func ok(_ data: Any) throws -> Data { try JSONSerialization.data(withJSONObject: ["code": "ok", "data": data]) }

private let loginUA = "Mozilla/5.0 (Linux; Android 9; V1938T Build/PQ3A.190705.08211809; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36"
private let playUA = "Linux; Android 12; Pixel 3 XL) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.101 Mobile Safari/537.36"
/// The W-51 gate's login body (`login-body.b64`, sha256 bef0f6ef…): `login-plain.json`, timestamp 1791786562264, AES-128-ECB.
private let gateLoginBody = "jtcKgum+2qE6zzrvBKp/diD5d+UrAt4YNUI721ikdlRymwmEI5QSuTb5won+rFvx1/gxorEnPyWzdSBpAG5VocJl7jspUX+TLd5syC8PkWTGYftIpScSKdaXOT/JhQDPRtHs8Fo16KYwx7l3SINqNlwHeyw65zTq6OqfiO+TCBgZmPTWZPRnpPBjY9czVEOuIE62H1U4FFsnUkjaF+jxWEPvVyscduud3jdGu3OVXl1NpJ7f1+BPo5lOpCi1KUpE+zymTJHqD17pjeqHqRg+hAR6vweWqaRh/Ql1jstu2XFvZzEh/5eRsh1M+2ZksBX42R6FAR8P8XsRp7upTiquKqWI1cCmiTKbrgdiywOT+OI="
private let firstEpisode = "http://qcapp.xingya.com.cn/wz_mp41125ruanruanwuqig1.mp4?sign=5a9e07b9e2ae271b00c173d263ddb5bb&t=6accb685"
private let lastEpisode = "http://qcapp.xingya.com.cn/wz_mp41125ruanruanwuqig79.mp4?sign=181b9435d279af4cd1d6a35742fd1e9f&t=6accb685"

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [XingyaSite.self]
    return URLSession(configuration: configuration)
}

private let suite = "ShortXingya-test"

private func xingya() async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "ShortXingya", script: try #require(registry.entry(for: "csp_ShortXingya")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: "")
    return runtime
}

private func header(_ seen: XingyaSite.Seen, _ name: String) -> String? {
    seen.headers.first { $0.key.lowercased() == name.lowercased() }?.value
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

private func theater(_ fields: [String: Any]) -> [String: Any] {
    ["theater": ["id": 4660, "title": "甲", "cover_url": "https://x/a.jpg", "theme": "都市", "play_amount_str": "1万"].merging(fields) { $1 }]
}

@Suite(.serialized) struct ShortXingyaSpiderTests {
    @Test func theRegistryDrivesCspShortXingya() {
        #expect(SpiderRegistry.bundled(bundle: .repoSpiders).entry(for: "csp_ShortXingya") != nil)
    }

    // D5 test 1, with the clock pinned to the gate's request: the body is the gate's, byte for byte.
    @Test func theLoginSendsTheGatesBodyAsAStringWithUpstreamsHeaders() throws {
        XingyaSite.serve([loginPath: loginReply("fake-token-1"), homePath: try category()])
        let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
        let context = try #require(JSContext())
        CatVodHost.install(into: context, storage: SpiderStorage(siteKey: "ShortXingya-login"), cookies: CookieJar(), session: session())
        context.evaluateScript(registry.prelude)
        context.evaluateScript("var module = { exports: {} };")
        context.evaluateScript(try #require(registry.entry(for: "csp_ShortXingya")?.script))
        context.evaluateScript("__util.now = function () { return 1791786562264; }; module.exports.homeVideoContent();")
        #expect(context.exception == nil)
        let login = try #require(XingyaSite.logins.first)
        #expect(XingyaSite.logins.count == 1 && login.method == "POST")
        #expect(login.url.absoluteString == "https://u.shytkjgs.com/user/v3/account/login")
        #expect(login.body == gateLoginBody && !login.body.contains("device="))
        #expect(header(login, "platform") == "1" && header(login, "user_agent") == loginUA)
        #expect(header(login, "content-type") == "application/json; charset=utf-8")
        let call = try #require(XingyaSite.calls.first)
        #expect(call.url.absoluteString == "https://app.whjzjx.cn/v1/theater/home_page?theater_class_id=1&class2_id=4&page_num=1&page_size=24")
        #expect(header(call, "authorization") == "fake-token-1" && header(call, "platform") == "1" && header(call, "version_name") == "3.8.3.1")
    }

    @Test func homeListsFiveClassesAndRecommendsByPlays() async throws {
        XingyaSite.serve([loginPath: loginReply("fake-token-1"), homePath: try category()])
        let spider = try await xingya()
        let home = try object(try await spider.homeContent(filter: true))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } == ["1剧场", "3新剧", "2热播", "7星选", "5阳光"])
        #expect(XingyaSite.requests.isEmpty)
        let items = try list(try await spider.homeVideoContent())
        #expect(items.count == 24 && items.first?["vod_id"] as? String == "4659" && items.first?["vod_remarks"] as? String == "170.4万")
    }

    // D5 test 2.
    @Test func aCategoryLogsInOnceAndReadsTheGateReply() async throws {
        XingyaSite.serve([loginPath: loginReply("fake-token-1"), homePath: try category()])
        let spider = try await xingya()
        let page = try object(try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.count == 24)
        #expect(items[0]["vod_id"] as? String == "4659" && items[0]["vod_name"] as? String == "阮阮吾妻")
        #expect(items[0]["vod_pic"] as? String == "https://qiniu.rongjuwh.cn/iv2_Fh3tpwxGRR4FsKTfjc9AgTiiYVSU" && items[0]["vod_remarks"] as? String == "民国情缘")
        #expect(items[1]["vod_id"] as? String == "4663" && items[1]["vod_name"] as? String == "清风入梦，书音自来" && items[1]["vod_remarks"] as? String == "现代言情")
        #expect(items[23]["vod_id"] as? String == "4782")
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 2 && page["limit"] as? Int == 90 && page["total"] as? Int == 9999)
        let call = try #require(XingyaSite.calls.first)
        #expect(call.method == "GET" && call.url.absoluteString == "https://app.whjzjx.cn/v1/theater/home_page?theater_class_id=1&page_num=1&page_size=24")
        #expect(header(call, "authorization") == "fake-token-1" && header(call, "platform") == "1" && header(call, "version_name") == "3.8.3.1")
        _ = try await spider.categoryContent(tid: "3", page: "2", filter: false, extend: [:])
        #expect(XingyaSite.logins.count == 1 && XingyaSite.calls.count == 2)
        #expect(XingyaSite.calls.last?.url.query == "theater_class_id=3&page_num=2&page_size=24")
        // The token lives in the spider's memory only.
        let stored = UserDefaults(suiteName: suite)!.dictionaryRepresentation().values.map { "\($0)" }
        #expect(!stored.contains { $0.contains("fake-token") })
    }

    // D5 test 3.
    @Test func aBrokenCategoryAsksNothingOrSkipsTheBadItems() async throws {
        let spider = try await xingya()
        XingyaSite.serve([loginPath: loginReply("t")])
        #expect(try list(try await spider.categoryContent(tid: "x", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(XingyaSite.requests.isEmpty)
        let items: [Any] = [theater(["id": "4661", "theme": ""]), theater(["id": 0]), ["no": "theater"],
                            theater(["id": NSNull()]), theater(["id": "4abc"]), theater([:])]
        XingyaSite.serve([loginPath: loginReply("t"), homePath: try ok(["list": items, "is_end": true])])
        let page = try object(try await spider.categoryContent(tid: "1", page: "3", filter: false, extend: [:]))
        let vods = try #require(page["list"] as? [[String: Any]])
        #expect(vods.map { $0["vod_id"] as? String } == ["4661", "4660"])
        #expect(vods.first?["vod_remarks"] as? String == "1万")
        #expect(page["page"] as? Int == 3 && page["pagecount"] as? Int == 3)
        for pg in ["0", "abc", "2.5"] {
            _ = try await spider.categoryContent(tid: "1", page: pg, filter: false, extend: [:])
            #expect(XingyaSite.calls.last?.url.query == "theater_class_id=1&page_num=1&page_size=24")
        }
        XingyaSite.serve([loginPath: loginReply("t"), homePath: Data(#"{"code":"ok"}"#.utf8)])
        #expect(try list(try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])).isEmpty)
    }

    // D5 test 4.
    @Test func theDetailListsAllSeventyNineEpisodes() async throws {
        XingyaSite.serve([loginPath: loginReply("t"), detailPath: try detail()])
        let vod = try #require(try list(try await xingya().detailContent(ids: ["4659"])).first)
        #expect(XingyaSite.calls.first?.url.absoluteString == "https://app.whjzjx.cn/v2/theater_parent/detail?theater_parent_id=4659")
        #expect(vod["vod_id"] as? String == "4659" && vod["vod_name"] as? String == "阮阮吾妻")
        #expect(vod["vod_pic"] as? String == "https://qiniu.rongjuwh.cn/iv2_Fh3tpwxGRR4FsKTfjc9AgTiiYVSU")
        #expect(vod["vod_remarks"] as? String == "（九州）网微剧备字[2025]第6857号" && vod["vod_area"] as? String == "79集全")
        #expect((vod["vod_content"] as? String)?.hasPrefix("黑道千金阮南笙隐姓埋名嫁入阎家") == true)
        #expect(vod["vod_play_from"] as? String == "星芽")
        let episodes = try #require(vod["vod_play_url"] as? String).components(separatedBy: "#")
        #expect(episodes.count == 79 && episodes.first == "1$" + firstEpisode && episodes.last == "79$" + lastEpisode)
    }

    // D5 test 5.
    @Test func aBrokenDetailFallsBackLikeUpstream() async throws {
        let spider = try await xingya()
        XingyaSite.serve([loginPath: loginReply("t")])
        #expect(try list(try await spider.detailContent(ids: ["abc"])).isEmpty)
        #expect(XingyaSite.requests.isEmpty)
        func detailFor(_ data: [String: Any]) async throws -> [String: Any] {
            XingyaSite.serve([loginPath: loginReply("t"), detailPath: try ok(data)])
            return try #require(try list(try await spider.detailContent(ids: ["7"])).first)
        }
        for data: [String: Any] in [["video_url": "http://x/a.mp4"], ["theaters": [], "video_url": "http://x/a.mp4"]] {
            let vod = try await detailFor(data)
            #expect(vod["vod_play_from"] as? String == "星芽" && vod["vod_play_url"] as? String == "1$http://x/a.mp4")
            #expect(vod["vod_name"] as? String == "7")
        }
        let none = try await detailFor(["title": "无", "video_url": "ftp://x/a.mp4"])
        #expect(none["vod_play_from"] as? String == "无播放源" && none["vod_play_url"] as? String == "")
        let mixed = try await detailFor(["theaters": [
            ["num": 5, "son_video_url": "http://x/5.mp4"], ["num": "第6集", "son_video_url": "https://x/6.mp4"],
            ["num": "a$b#c", "son_video_url": "http://x/7.mp4"], ["num": "", "son_video_url": "http://x/8.mp4"],
            ["num": 9, "son_video_url": "ftp://x/9.mp4"], ["num": 10, "son_video_url": "http://x/10.mp4#t"]]])
        #expect(mixed["vod_play_url"] as? String == "5$http://x/5.mp4#第6集$https://x/6.mp4#a b c$http://x/7.mp4#4$http://x/8.mp4")
    }

    // D5 test 6, and an empty token (P19).
    @Test func aRefusedCallDropsTheTokenAndTheNextOneLogsInAgain() async throws {
        let spider = try await xingya()
        XingyaSite.serve([loginPath: loginReply("fake-token-1"), homePath: Data(#"{"code":"fail","msg":"token"}"#.utf8)])
        #expect(try list(try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(XingyaSite.logins.count == 1 && XingyaSite.calls.count == 1)
        XingyaSite.serve([loginPath: loginReply("fake-token-2"), homePath: try category()])
        #expect(try list(try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])).count == 24)
        #expect(XingyaSite.logins.count == 1 && XingyaSite.calls.first.map { header($0, "authorization") } == "fake-token-2")
        XingyaSite.serve([loginPath: loginReply(""), homePath: try category()])
        let fresh = try await xingya()
        #expect(try list(try await fresh.categoryContent(tid: "1", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(XingyaSite.calls.isEmpty)
        _ = try await fresh.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        #expect(XingyaSite.logins.count == 2)
    }

    // D5 test 7.
    @Test func playKeepsUpstreamsAgentAndSearchSendsJSON() async throws {
        let spider = try await xingya()
        let play = try object(try await spider.playerContent(flag: "星芽", id: firstEpisode, vipFlags: []))
        #expect(play["parse"] as? Int == 0 && play["url"] as? String == firstEpisode)
        #expect(play["header"] as? [String: String] == ["User-Agent": playUA])
        for id in ["ftp://x/a.mp4", ""] {
            #expect(try object(try await spider.playerContent(flag: "星芽", id: id, vipFlags: []))["url"] as? String == "")
        }
        XingyaSite.serve([loginPath: loginReply("t")])
        for key in ["", "   "] { #expect(try list(try await spider.searchContent(key: key, quick: false, page: "1")).isEmpty) }
        #expect(XingyaSite.requests.isEmpty)
        let found: [[String: Any]] = [["id": "123", "title": "甲", "cover_url": "https://x/1.jpg", "score_str": "9.1分"],
                                      ["id": 456, "title": "乙"], ["id": "0"], ["id": ""], ["id": "abc"]]
        XingyaSite.serve([loginPath: loginReply("t"), searchPath: try ok(["theater": ["search_data": found]])])
        let items = try list(try await spider.searchContent(key: " 阮阮吾妻 ", quick: false, page: "1"))
        #expect(items.map { $0["vod_id"] as? String } == ["123", "456"])
        #expect(items.first?["vod_name"] as? String == "甲" && items.first?["vod_pic"] as? String == "https://x/1.jpg" && items.first?["vod_remarks"] as? String == "9.1分")
        let call = try #require(XingyaSite.calls.first)
        #expect(call.method == "POST" && call.url.absoluteString == "https://app.whjzjx.cn/v3/search")
        #expect(call.body == #"{"text":"阮阮吾妻"}"# && header(call, "content-type") == "application/json; charset=utf-8")
        #expect(header(call, "authorization") == "t" && header(call, "version_name") == "3.8.3.1")
    }

    // D5 test 8: the first failed host is the one named.
    @Test func aFailedCallSaysWhichHostFailed() async throws {
        let spider = try await xingya()
        XingyaSite.serve([loginPath: (200, loginReply("t")), homePath: (500, Data())])
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "app.whjzjx.cn")) {
            _ = try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        }
        XingyaSite.serve([loginPath: (500, Data()), homePath: (200, try category())])
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "u.shytkjgs.com")) {
            _ = try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        }
    }
}

/// `category.json` from the W-51 gate (13126 bytes), raw-deflated.
private let categoryPacked = """
5VprU9PaGv4rZ/rZYq4rCTN7zlBpC+V+KVD2OdNJ09IG2rSkSW+OM1UEERXZXkAFNioIgqKgjBYQ/DNdaftp/4WzUlRqJ+xxWucEz5lhmHa9K6sreZ+87/M8
yWWLEPUHLI2W6JjlgsXPK7yl8bIlLMYVS+Pvly1KOqYH+0MBXgnIaIby5ROaJPotjRSgOTQoKmF9WunRG/QH547h+qG+WiAuyGIMBdAXIZoIyF5VDqOvIUWJ
xRsvXhwXJVFtkKNScFRNhhoE6aKYILyOEKnEkilnby/liLf1j4wKXFOwXxQ9A31ufQd8MG5plNRwGH2OKjxakEF7EFRZDkiKV1IjJwMjcjTi1U/IGxeiMtoe
dsEyrvJhUUl7gzJfPmm0XDIgBkNKOfrl3LwxvrySGkNHB9ASYjjtjSu8osbL02JhPu1VE17Gz6dPB/hIVJXQOjiDUQTOfjeKjkZXzIJCDVQ+dwP9algcC5xs
FR0v89KYKAXLn/UteBN8WA183VJE36i28wdcPNImJgufHqHD46Fo0qtffwtgKY4kOEHgWD/lDwBWIHEyQAJfQPDTBEmhyaKkyFG/KihiVDo5ZzHuLa/Ai15R
0AdH+HA8cOXKhR9JOCBPE67lJkurs3DyhfZ8/a9Pt/P766WV98UbW9ryizryPyr1pekBQXVnBn19jMtH2KNDXrtKtWcSxvlnyar86wMm5Z/gWJJmCKP8o1Ct
+S/M7uQPV4svswgC9edf/0Evuo5ePUN6ZssD5fXwr+GTkKUwsa3d29bWl/q7uqlvh5ZBgl+pC0kEhrEVUCo9/Fx8tgAfTmlHb+rAjsiT6YTo6geky84O9zoE
nzOAcbzfp/i+Yef3Lxsof/dK/MkdNr8Db27o1zYqozRyHLqFvyYdR1uQ9c37vbyiJxIjSCvGWQnmHzjViNGNJIsOPMHL6RTaiuFWgtSnUFQjyaEpMVFQVB2L
f3MajnG1KdLRLPXS44o9lVbCLelhOyvgKoWDfyZFvxL6jST+pWIYAUJl7P6Gs5Yr//52M9BY1c2gD5h0MwCOIxmjW4Gp7TYoTRzB3LXCgxVt79DcMkgTxCl2
4Y0DVJ3zuQm4vwfnZvVKmJuGa6/g/e3CclbbvaZN/wHv3YYv3sPrn+Hin3Btrw6Ix4NWWhrqlZxpbDDYkkk0u6SoNZPk28ZsxuWRrG6PpHntkaEBy2CGkKAb
mPNQHOtABU6zWAUqpp+Usll4tI/wAHd2EQBK2Qm4+QSubcCdu3BjDs7dhruTdSBBGZd8Xf5WadjdlSQlW4SKefpQ66RxMWKMBL2ofYcEfcAkJNA0x3AsRhph
AcXY2rAAbx+Wrt6HS6vazVvmVgiGYU6xUHz+Cn7Klh6vnZQHvR7cvYO2qL1/WXqQhZOv4d1cHUBQW2ODPCthTW2jvaxPaBsg3LQrIDi7HJ3GQADVJQGYyJgB
gVqbYZtAoVoZ089tFTUyJhz/qZSJAhQ4xRTqN6XFD4Xj2fzBgba9Wpx5D+/M1tNXehwRT0powwakeLjHycZSoe6kHLFdsradIbuqmQZjHtNgaUACyghDLN0A
aqwl+3uor3xhhSYWkkrFVVp+ql39AOfuaA/3Ss8+F3e3Sgsv60h6WA0C97DM44PxmNgaaaeHBSsqXX1pu+OMykFXVw7atKRzOIEzhg2EwxuI2pJ+ckW17GFx
9aqpeSdproJMFJ7cgIvH2tIWXKtHHkntDCm4WHeSCcrdNJ9oGrI6LrX7UvyQeka6mep0M+apCRJdZmPCgEINZI3Wyp8fCpsHcHYK3n1nasIJgqzw0uDUR21p
WsttltYf15HwaJM64A6PhCK9XUGhRR3KpNJkXLA6ROA8gyJS1RSRMs9LARwgyjzKwExBsVpTXtj8XPwwoy3oiTe3tuPfCYbs41JuBV5dgksvizuzSNDA7dV6
Gvqg0zNq7ezpSThcgZC/n2hRuzuATcbluHHuqeraTplX2xkOMBRuKBS5WoVi/uAdkoj53LzZQhHQbAWPO5zXFeKbp/DFPpx8Udqqp58HXSGph/ELDvt4JDqQ
HEvGFA/FyKC5xXeGd1qtBFgTlQCHYYA4QwqgWK1E7tz0dArg9HeisLj3Gk4eljZflz2jrLa0rNtDK7NIIGrZe9rsbW15As58rgMQCcrV5OuxpbqDEarPreJi
jxwZTDk8Nqvn/Hd8HGcZijWsAihUaxk4Nx2fRLSlgtpnp4rPt/P7twozH+DkBAJCfv9ZHZmPpJUBj9PVy/YNdDuauhzDTpkKM65RbEyotsKZ76zwwvTU91Y4
97dW+InPTZStcNBIn22Fn0zhGokftsKVVPKS6BgblOItw1LnUEcCC6ZtfGa4D/yQFQ6qBSowT6CSOAMwxlCholCtlQ0hBC6tnAdDHFAVla3w4CO8eyt/dF9b
zRYn5uGdq9r82onvpd2dyx9MwempE4OuZuuzOToc73FSHQm1rymRCXrGYq62dG9z/yX6VzArcEw33AzNCvwXN8EpQFYgAX58pz16W3p8u/jxbT53R1s8Lm7c
rIfTtjjdnQQRwolUwKbYxr09RFMsGJcGMnbjvNPVnJY2kdMiSssAQ04Lam1m54fbIP1a8WbA4nEp+xzOLSKVVZzZLUxuFJY+1cNrRyJye5+DCIHRwXjIrVBR
uz8zmO4kWlxn0BiiuvYTJjrcJEWRxjQGkLU63PDNpDa/AN+8Qv/NpTEExlS+BDRbmL0Fswd1ZHu8NzmaGgmJ9mA0SHmaeZpt6egI2YddmdT/CXXhqtsVZ167
onGcohnS8KmtHqvZX/90TVt6W/wwWZw4Mtlix/AKAG8tIJ6SP3gA9/cQZymsH8LNJ/mjp/D+dv4wm9+frh3Y4XjziBiW7XKzn1JFJuF0hDN+gpYzPWHxjPaF
V7cv3DzawmK48ZtNLPurkxaMq0CAtvA0n5spbT+AOzN1VLEYPoj5013duOyOCZ0hPuAZtLVFQNRBp87oWdXeKzDPe0XaFHF6Q5KKQg10jXolt6TN7xdmr8N9
s/UKXtGz4NtDbW+xHpu9zR0bG+phelmplfQ1tQ5m+iIDrWPBMf4MWnqepCkAgMINlSkAtdZ2bXs9f/w0f/gY/Tfv8Tv2cx+/00xlm8hm9Zd5yu9zFJZX4dRi
PnegC9yZR8XJnXocO1vSE77EiGpScQxJnf5Oggz5hrn2sATOv8ShMJIxxhL1v/Dyc6VvX3z+Snv5TLu1kj84KDxY+YKEw+XizXf6m3655cInvY0gSNQBhrHR
fto+bhvJcAk+0jbK2J3jzqi1XSRt7vPfQ3AcwzAaGNu32C9u3lIMW/kK6O6u9u49XDxGGS9cf6ItbBS37tfzoF7t7IoNjPo7RWtXa8gz7u8AbS57i7c1MXr+
GwqFGIJx2imy5obyXykCpwKMoMqzApL/a/CCJRIP6juZnoMzK5ZTYYld+Q8=
"""

/// `detail.json` from the W-51 gate (53217 bytes), raw-deflated.
private let detailPacked = """
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
879vT3XzndWNF04/eO30jTflo9Uzv1p9eP3Wh6/KM69+evPkB0/L3c+Kubr57OqZ92699/V22lvvn7z8zp3v//bWh6/funnz9ne/d+vDX9z5wY9P37jRrv/B
Wyc//MXJ77595/vPnTzz6uqZn6++f1OOS+Wsvv7m6sbzt/7w8q33rq+ef04uvnH3DfZ1fYUPj8LRdrr0yFceefKsu1if9vBaXZeuHF3d+ezRldb2Drbu9Uif
aR3SmW6lj2gH7L3Lf0wFrdHJlw+Ptp4IR+nK1t1rtXauPvbZYUl7u2fHpWmmvZ2dko7u/no1HDy6/vkw7R20LtBfak2lHW4ijOVArNR6Oe7Z9+4dBKR11Hh8
sH76e53N8b7cYrduX97Y3D3e2XloI15u99yTr2z8nfsHQ9gKlcthOtje/4SSrB/x6v5OOSrr5/pYLZ31Rls5bO9c22p1fHy4bkYlHOxst6uc17zbXbeOwmX5
ypc2rL/zhkji5/IAd64/e/vH78gPpy/95tYHP7n98+snTz+z8eV1BT2+vX+3du/1aHV7R/pvefi/fPi8SHH1+x/+5cMXTv/w6uqPN1YvvL366XOrd17/Uusq
v3z6q19JZ2xXL/9+o5meax+1eynXY8dhZ/vo2tblg5BbvX+hvWrpjsvu1uGVvSe2ru7lcvclhW15T492HuDuga39A6krqbq9g486+LvVFY6PrmxsfnVjfa11
GVpt66+tr7c+KNfYTk1MH11Tju+WJ7bOyrZV93aPPvpIvnP1sJX2rAG05/yo3tXX/hc=
"""
