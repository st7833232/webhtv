import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import WebHTVCore

// IOS-POC-57B-5 (W-43): Duboku.js against the replies the live API returned on 2026-10-09 (W-19 gate: home, detail,
// play) and 2026-10-12 (search), JDK golden vectors for the java.util.Random signature (W-25 design §5.1, §5.5),
// and hand-made edge replies.

/// Answers api.dbokutv.com by path (query ignored) and remembers every request's URL and headers.
final class DubokuSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [(url: URL, headers: [String: String])] = []

    static func serve(_ served: [String: Data], status: Int = 200) {
        lock.withLock { replies = served.mapValues { (status, $0) }; seen = [] }
    }
    static var requests: [(url: URL, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.dbokutv.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append((url, request.allHTTPHeaderFields ?? [:]))
            return Self.replies[url.path] ?? (404, Data())
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

private func home() throws -> Data { try fixture(homePacked, sha256: "e116a5644b7240f7006608b06c6d8495d3b042a2fbc3dc2b18b56d71d8cb6e57") }
private func detail() throws -> Data { try fixture(detailPacked, sha256: "95c51e7a8a55c9eb7f752c0352071be316996e4f4ee3e41c096943b2ad493f9c") }
private func play() throws -> Data { try fixture(playPacked, sha256: "9f3b90c34a9a6a2cad0fd14f538a4c6075c6e16a3711f027b9c5aef894272067") }
/// /vodsearch?…&wd=兰香如故, fetched once on 2026-10-12 16:05 CST (sha256 5cb5d384…).
private let searchReply = Data(#"[{"Name":"兰香如故","Rating":8.4,"Tag":"全47集","Actor":"刘学义,谭松韵,牛骏峰,李梦,郑合惠子,郭柯宇","DId":"GdlRGZvZ3L5kDNx8CbpF.MTN","DuId":"GdlRGZvZ3L5kDNx8CbpF.MTN","TnId":"yL6MHc0RHa05SZnFWbp9yZy9mLiRWbwMzdvA3L09FWyVnZr9CMvV1aaFDSNJnM34ES1QVeuole4FFVMpnBna"}]"#.utf8)

private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
private let poster = "https://image.tmdb.org/t/p/w300/kfurXRMH1ZkUoyT5HN72zLTQxzZ.jpg"

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DubokuSite.self]
    return URLSession(configuration: configuration)
}

private func duboku() async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "Duboku", script: try #require(registry.entry(for: "csp_Duboku")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "Duboku-test", defaults: UserDefaults(suiteName: "Duboku-test")!), session: session())
    try await runtime.initialize(extend: "")
    return runtime
}

/// The same script in a bare host context whose clock is pinned to `ms`, so a request carries a known signature.
private func signedRequest(at ms: Int64) throws -> URLComponents {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let context = try #require(JSContext())
    CatVodHost.install(into: context, storage: SpiderStorage(siteKey: "Duboku-sign"), cookies: CookieJar(), session: session())
    context.evaluateScript(registry.prelude)
    context.evaluateScript("var module = { exports: {} };")
    context.evaluateScript(try #require(registry.entry(for: "csp_Duboku")?.script))
    context.evaluateScript("__util.now = function () { return \(ms); }; module.exports.homeVideoContent();")
    #expect(context.exception == nil)
    let url = try #require(DubokuSite.requests.last?.url)
    return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
}

private func query(_ components: URLComponents, _ name: String) -> String? {
    components.queryItems?.first { $0.name == name }?.value
}

/// ssid is base64 of (100000000+r)(900000000-r) interleaved with the 13 ms digits: undo it to read r.
private func randomInSSID(_ ssid: String) throws -> Int {
    let mixed = Array(String(decoding: try #require(Data(base64Encoded: ssid.replacingOccurrences(of: ".", with: "="))), as: UTF8.self))
    let digits = stride(from: 0, to: 26, by: 2).map { mixed[$0] } + mixed[26...]
    return try #require(Int(String(digits.prefix(9)))) - 100000000
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

/// One VodList item shaped like the live replies; `did` is the already-encoded DId.
private func item(_ name: String, did: String = "GdlRGZvZ3L5kDNx8CbpF.MTN", extra: [String: Any] = ["Tag": "全47集"]) -> [String: Any] {
    ["Name": name, "DId": did, "TnId": "yL6MHc0RHa05SZnFWbp9yZy9mLiRWbwMzdvA3L09FWyVnZr9CMvV1aaFDSNJnM34ES1QVeuole4FFVMpnBna"]
        .merging(extra) { $1 }
}

@Suite(.serialized) struct DubokuSpiderTests {
    @Test func theRegistryDrivesCspDuboku() {
        #expect(SpiderRegistry.bundled(bundle: .repoSpiders).entry(for: "csp_Duboku") != nil)
    }

    // JDK 17 `Golden.java` (§5.1): no rejection in nextInt(800000000).
    @Test func theSignatureMatchesTheJDKGoldenVector() throws {
        DubokuSite.serve(["/home": Data("[]".utf8)])
        let sent = try signedRequest(at: 1791500000123)
        #expect(sent.path == "/home")
        #expect(query(sent, "sign") == "ydt77XpBPJ2FrEeycDUIGBE1LrblpBHURjX40A65v5wTh0cuRmpIDrc4Jmhs")
        #expect(query(sent, "ssid") == "MzE1Nzc5MTE0NTEwMTAyMDQwNjA0MTIyODM1ODg3Ng..")
        #expect(query(sent, "token") == "D61qnRFHZVfJOt4FbuYuFb8JnpNebT5FCd9F6V")
        #expect(try randomInSSID(try #require(query(sent, "ssid"))) == 257141124)
        #expect(sent.queryItems?.map(\.name) == ["sign", "ssid", "token"])
        let headers = try #require(DubokuSite.requests.last?.headers)
        #expect(headers["User-Agent"] == chrome && headers["Referer"] == "https://www.duboku.tv/" && headers["Connection"] == nil)
    }

    // JDK 17 `Golden2.java` (DUBOKU-D-01): the first next(31) is rejected once; a naive `next(31) % bound` gives 483559477.
    @Test func theSignatureTakesNextIntsRejectionBranchLikeTheJDK() throws {
        DubokuSite.serve(["/home": Data("[]".utf8)])
        let sent = try signedRequest(at: 1791500288123)
        let ssid = try #require(query(sent, "ssid"))
        #expect(ssid == "MjE0Nzc5MzEyNTMwMzA3Mjc4Nzg1MTIyNjM3NjYyMw..")
        #expect(query(sent, "sign") == "5qNVdQqenCKIU9ZIRu3gGgFlZjAwPcs2jIxWxU0Mu86rNtscmKIsEP6lfBcj")
        #expect(query(sent, "token") == "alofqKGmxOWMhYPPQk83ERb3BhcqyuQN3zHxFf")
        #expect(try randomInSSID(ssid) == 147323377)
        #expect(ssid != "NTE4NzM5NTE1NTkwNDA3Mjc4NDgxMTYyNDM0MDUyMw..")
        #expect(try randomInSSID(ssid) != 483559477)
    }

    @Test func homeOffersTheNineClassesAndUpstreamsFiltersWithoutTheNetwork() async throws {
        DubokuSite.serve([:])
        let home = try object(try await duboku().homeContent(filter: false))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } ==
                ["1电影", "2电视剧", "3综艺", "4动漫", "21短剧", "20港剧", "13陆剧", "15日韩剧", "14台泰剧"])
        // Duboku.java:180's JSON constant, compact with sorted keys, plus W-177's 2026 year (the site serves it).
        // `.sortedKeys` puts "13" after "4", so the reference hash came from the constant written in that same key order.
        let filters = try JSONSerialization.data(withJSONObject: try #require(home["filters"]), options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(SHA256.hash(data: filters).map { String(format: "%02x", $0) }.joined()
                == "31928f2596627cfb8d347a56cb15a42088fe0ea7f662246ea36295e990978615")
        #expect(DubokuSite.requests.isEmpty)
    }

    @Test func homeRecommendsAllEightyOneFromTheNineSections() async throws {
        DubokuSite.serve(["/home": try home()])
        let items = try list(try await duboku().homeVideoContent())
        #expect(items.count == 81)
        #expect(items.first?["vod_id"] as? String == "/voddetail/149953" && items.first?["vod_name"] as? String == "兰香如故")
        #expect(items.first?["vod_pic"] as? String == poster && items.first?["vod_remarks"] as? String == "全47集")
        #expect(items.last?["vod_id"] as? String == "/voddetail/149874" && items.last?["vod_name"] as? String == "灵境行者")
    }

    @Test func aCategoryBuildsUpstreamsPathFromTheFiltersAndAWholePage() async throws {
        let reply = try json(["VodList": [item("兰香如故")]])
        DubokuSite.serve(["/vodshow/2-大陆-人气-古装-国语----3---2024": reply, "/vodshow/13--------1---": reply,
                          "/vodshow/1--------1---": reply])
        let spider = try await duboku()
        let page = try object(try await spider.categoryContent(
            tid: "2", page: "3", filter: true, extend: ["area": "大陆", "year": "2024", "by": "人气", "class": "古装", "lang": "国语"]))
        #expect(DubokuSite.requests.last?.url.path == "/vodshow/2-大陆-人气-古装-国语----3---2024")
        #expect(DubokuSite.requests.last?.url.absoluteString.contains("/vodshow/2-%E5%A4%A7%E9%99%86-") == true)
        #expect(page["page"] as? Int == 3 && page["pagecount"] as? Int == 44739243)
        #expect(page["limit"] as? Int == 48 && page["total"] as? Int == 2147483647)
        #expect((page["list"] as? [[String: Any]])?.first?["vod_id"] as? String == "/voddetail/149953")
        // extend.cateId wins over tid; a page that is not a whole number, or below 1, is page 1.
        _ = try await spider.categoryContent(tid: "2", page: "x", filter: false, extend: ["cateId": "13"])
        #expect(DubokuSite.requests.last?.url.path == "/vodshow/13--------1---")
        _ = try await spider.categoryContent(tid: "1", page: "0", filter: false, extend: [:])
        #expect(DubokuSite.requests.last?.url.path == "/vodshow/1--------1---")
    }

    @Test func listItemsThatDoNotDecodeAreSkippedAndRatingsPrintLikeJava() async throws {
        DubokuSite.serve(["/vodshow/1--------1---": try json(["VodList": [
            item("标签", extra: ["Tag": "HD", "Rating": 9.1]),
            item("整数评分", extra: ["Rating": 8]),
            item("小数评分", extra: ["Rating": 7.5]),
            item("无备注", extra: [:]),
            item("坏DId", did: "!!!!"),
            item("非详情", did: "XYsBHZvZ3L..QMvk"),
            "不是对象",
        ] as [Any]])])
        let items = try list(try await duboku().categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        #expect(items.map { $0["vod_name"] as? String } == ["标签", "整数评分", "小数评分", "无备注"])
        #expect(items.map { $0["vod_remarks"] as? String } == ["HD", "8.0分", "7.5分", ""])
    }

    @Test func detailCarriesTheDesignedFieldsAndFortySevenEpisodesTheAppParses() async throws {
        DubokuSite.serve(["/voddetail/149953": try detail()])
        let vod = try #require(try list(try await duboku().detailContent(ids: ["/voddetail/149953"])).first)
        #expect(vod["vod_id"] as? String == "/voddetail/149953" && vod["vod_name"] as? String == "兰香如故")
        #expect(vod["vod_pic"] as? String == poster && vod["vod_year"] as? String == "2026")
        #expect(vod["vod_actor"] as? String == "刘学义,谭松韵,牛骏峰,李梦,郑合惠子,郭柯宇" && vod["vod_director"] as? String == "未知")
        #expect((vod["vod_content"] as? String)?.hasPrefix("《兰香如故》线上看，共47集") == true)
        #expect(vod["vod_play_from"] as? String == "独播库")
        let episodes = Episode.parse(try #require(vod["vod_play_url"] as? String))
        #expect(episodes.count == 47)
        #expect(episodes.first?.name == "第1集" && episodes.first?.url == "/vodplay/149953-1-1")
        #expect(episodes.last?.name == "第47集" && episodes.last?.url == "/vodplay/149953-1-47")
        #expect(DubokuSite.requests.last?.url.path == "/voddetail/149953")
    }

    @Test func detailSkipsEpisodesThatDoNotDecodeAndKeepsSeparatorsOutOfNames() async throws {
        let base = try #require(try JSONSerialization.jsonObject(with: try detail()) as? [String: Any])
        var edited = base
        edited["Actor"] = "刘学义,谭松韵"
        edited["Playlist"] = [
            ["EpisodeName": "第1$集#上", "VId": "XYsBHZvZ3LzUTO5QTMvk..QMtETL"],
            ["EpisodeName": "坏", "VId": "!!!!"],
            ["EpisodeName": "非播放", "VId": "GdlRGZvZ3L5kDNx8CbpF.MTN"],
            "不是对象",
        ] as [Any]
        DubokuSite.serve(["/voddetail/149953": try json(edited)])
        let vod = try #require(try list(try await duboku().detailContent(ids: ["/voddetail/149953"])).first)
        #expect(vod["vod_actor"] as? String == "")
        #expect(vod["vod_play_url"] as? String == "第1 集 上$/vodplay/149953-1-1")

        edited["Playlist"] = "none"
        DubokuSite.serve(["/voddetail/149953": try json(edited)])
        #expect(try list(try await duboku().detailContent(ids: ["/voddetail/149953"])).isEmpty)
    }

    @Test func playReturnsTheDecodedStreamWithExactlyUpstreamsThreeHeaders() async throws {
        DubokuSite.serve(["/vodplay/149953-1-1": try play()])
        let spider = try await duboku()
        for id in ["/vodplay/149953-1-1", "/vodplay/149953-1-1|兰香如故|第1集"] {
            let result = try object(try await spider.playerContent(flag: "独播库", id: id, vipFlags: []))
            #expect(result["url"] as? String == "https://vid.dbokutv.com/20260911/ppotb62-S71lT2yliZApDBSvkYzBsrmD3fpCJ4nBsHaTcyo5xOy6ejR7XoPoqmCIqmCZarDp4sCpGkRN0q/chunklist.m3u8")
            #expect(result["parse"] as? Int == 0)
            #expect(result["header"] as? [String: String] ==
                    ["User-Agent": chrome, "Origin": "https://w.duboku.io", "Referer": "https://w.duboku.io/"])
            #expect(DubokuSite.requests.last?.url.path == "/vodplay/149953-1-1")
        }
    }

    @Test func idsWithTheWrongPrefixAreRefusedWithoutARequest() async throws {
        DubokuSite.serve(["/voddetail/149953": try detail(), "/vodplay/149953-1-1": try play()])
        let spider = try await duboku()
        #expect(try list(try await spider.detailContent(ids: ["/vodplay/149953-1-1"])).isEmpty)
        #expect(try list(try await spider.detailContent(ids: ["https://evil.example/voddetail/1"])).isEmpty)
        #expect(try object(try await spider.playerContent(flag: "", id: "/voddetail/149953", vipFlags: []))["url"] as? String == "")
        #expect(DubokuSite.requests.isEmpty)
    }

    @Test func aPlayReplyWithoutAUsableStreamIsAnEmptyPlay() async throws {
        let spider = try await duboku()
        for body in [#"{"VodName":"x"}"#, #"{"HId":"!!!!"}"#, #"{"HId":"GdlRGZvZ3L5kDNx8CbpF.MTN"}"#, "<html>"] {
            DubokuSite.serve(["/vodplay/149953-1-1": Data(body.utf8)])
            let result = try object(try await spider.playerContent(flag: "", id: "/vodplay/149953-1-1", vipFlags: []))
            #expect(result["url"] as? String == "" && result["header"] == nil)
        }
    }

    @Test func searchSendsTheKeywordOnceAndMapsTheSavedReply() async throws {
        DubokuSite.serve(["/vodsearch": searchReply])
        let spider = try await duboku()
        let items = try list(try await spider.searchContent(key: "兰香如故", quick: false, page: "2"))
        #expect(items.count == 1 && items.first?["vod_id"] as? String == "/voddetail/149953")
        #expect(items.first?["vod_pic"] as? String == poster && items.first?["vod_remarks"] as? String == "全47集")
        let url = try #require(DubokuSite.requests.last?.url)
        let sent = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(sent.queryItems?.map(\.name) == ["sign", "ssid", "token", "wd"] && query(sent, "wd") == "兰香如故")
        #expect(DubokuSite.requests.last?.url.absoluteString.hasSuffix("&wd=%E5%85%B0%E9%A6%99%E5%A6%82%E6%95%85") == true)

        DubokuSite.serve(["/vodsearch": searchReply])
        #expect(try list(try await spider.searchContent(key: "  ", quick: false, page: "1")).isEmpty)
        #expect(DubokuSite.requests.isEmpty)
    }

    @Test func brokenRepliesAreEmptyAndAFailedListingSaysWhy() async throws {
        let spider = try await duboku()
        DubokuSite.serve(["/home": Data(#"{"VodList":[]}"#.utf8), "/vodsearch": Data("<html>".utf8),
                          "/voddetail/1": Data("[]".utf8)])
        #expect(try list(try await spider.homeVideoContent()).isEmpty)
        #expect(try list(try await spider.searchContent(key: "x", quick: false, page: "1")).isEmpty)
        #expect(try list(try await spider.detailContent(ids: ["/voddetail/1"])).isEmpty)
        DubokuSite.serve(["/vodshow/1--------1---": Data()], status: 500)
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "api.dbokutv.com")) {
            _ = try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        }
    }
}

/// `home.json` from the W-19 gate (23434 bytes), raw-deflated.
private let homePacked = """
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
"""

/// `detail.json` from the W-19 gate (8683 bytes), raw-deflated.
private let detailPacked = """
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
"""

/// `play.json` from the W-19 gate (5385 bytes), raw-deflated.
private let playPacked = """
jdfPcppQGIfhe3GdOAKShuw0gJDxYI4CBjpd8MehAiE2BgxmsulMegdddLrPKoveVNrJXdTYuOmYj9/CGQcO5xE+3oV3LTNunbSErqLI0qFwKLQOWu5VbAWX
s83h54dfL48/nh+//v7+sDmhLebLq3j2dvLP05Pw8vPb5rhdbDeph0fMiDpjI+jIE7/Qp+FCqf1auRzOx9NwxdZx1ZOGHUWf1m7hXyunrHKFINDViXVWMKmr
TQTuzsqrfNbVdZctin4RbHZXt5sP4nw88CtfGsqZat0en4YLvc1s6/X3bhdceMu+sV2wduyRzG1WZe02ZzeaPXzdpWzcpkT2Mf671eps4Jd8GoiKGKbyPO64
UiD3UqvupazqDOKqb0SVZrOlvrZsYc5E84IH+SCUz1T3KBcC0cq51i/8NXfC2iq4ufmU43Si9rWZcDydpWPX8+LU+eJeWrJyMVGFaVT1hXA1zqLPC4Hf6Jlz
HWuRahlW6RpBqkyiVdcOSy5Fi1sxaLd7I+H19s7/PabNN4t6YMnuRs/fnsf2ghK6Ig/qfL68aZ18vHv3XYGGhYzi/mAPIjYjCYQkBCI1IysIWRFItxnpWQjy
tmovIgMzgRBOIEfATCAkIZAPwEwgZEUgx8BMRtBMRu8jCjATCOEEInQalZ6NvMO7VfuV5uY1SNFIpTl6E1JMUmmunkEKI5Xm7DmkcFJp7t6BFIdUmsP3IMUj
lebyI0iJSKU5/QRSElJpbj+DlIxSRKD9FGo/pRSgfUjRSAVoH1JMUgHahxRGKkD7kMJJBWgfUhxSAdqHFI9UgPYhJSIVoH1ISUgFaB9SMkqRgPbXUPtrSgHa
hxSNVID2IcUkFaB9SGGkArQPKZxUgPYhxSEVoH1I8UgFaB9SIlIB2oeUhFSA9iElo5Qu0L6K/EfardqvAO1DikYqQPuQYpIK0D6kMFIB2ocUTipA+5DikArQ
PqR4pAK0Dym7Vfef7v8C
"""
