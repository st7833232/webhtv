import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-17 (W-152): Wwys.js against the pages vip.wwgz.cn:5200 returned on 2026-10-16 (W-148 gate,
// `qist-Wwys-gate-2026-10-16.md`, fixtures `wwys-gate-fixtures/`) and hand-made edge replies. Expected values come
// from those pages through a separate regex parser (task document §3), not from host.js.

/// Answers vip.wwgz.cn by path (plus the query for /index.php) and remembers every request.
final class WwysSite: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Data] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: Data]) { lock.withLock { replies = served; seen = [] } }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vip.wwgz.cn" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let key = url.path + (url.query.map { "?" + $0 } ?? "")
        let body = Self.lock.withLock { () -> Data? in
            Self.seen.append(Seen(url: url, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.replies[key]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                                               headerFields: ["Content-Type": "text/html;Charset=utf-8"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A gate reply, raw-deflated and base64-encoded, checked against the gate's SHA256SUMS.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func home() throws -> Data { try fixture(homePacked, sha256: "8a1a18665c2d75f93414efbffb217145a675fde671652254290a68ffc39a6640") }
private func category1() throws -> Data { try fixture(category1Packed, sha256: "3c83292a23f250655a5d52cf8a056ea2de60c23c6d26baf55fcacb7fab64701d") }
private func category12Page2() throws -> Data { try fixture(category12Page2Packed, sha256: "beca385800e68f749cd6dc719c140ec5137c91c80d93c5aa1f11f2291216362d") }
private func detail96319() throws -> Data { try fixture(detailPacked, sha256: "11f3c0625b5360a6d0028c37b622a4a0c095b574d118c354168f956bd6098034") }
private func play96319() throws -> Data { try fixture(play96319Packed, sha256: "bc821c72e5e3337aa723b65094cbd2db20435662d2f0a84e455bc9030ae81282") }
private func play94741() throws -> Data { try fixture(play94741Packed, sha256: "b0b67b2d241136a43bc97c24e1225d5143c9a4f7a567401005586eccb1d11e51") }
private func searchPage() throws -> Data { try fixture(searchPacked, sha256: "c82e93246264829961209b0ae5b5ec8a1d106d0aa9898e63c736d1284013d862") }

private let ua = "Mozilla/5.0 (Linux; Android 13; SM-A037U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36  uacq"
private let site = "https://vip.wwgz.cn:5200"
private func listPath(_ id: String, _ page: Int) -> String {
    "/vod-list-id-\(id)-pg-\(page)-order--by-time-class-0-year-0-letter--area--lang-.html"
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WwysSite.self]
    return URLSession(configuration: configuration)
}

private let suite = "Wwys-test"

/// The site as both qist configs write it (`ext` "https://vip.wwgz.cn:5200").
private func spider(ext: String = site) async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "Wwys", script: try #require(registry.entry(for: "csp_Wwys")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: ext)
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func strings(_ items: [[String: Any]], _ key: String) -> [String] { items.map { $0[key] as? String ?? "<none>" } }
private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
private var urls: [String] { WwysSite.requests.map(\.url.absoluteString) }

/// A play page with the site's player variables; only what detail reads.
private func playPage(from: String, url: String?) -> Data {
    Data("<script>var mac_name='x',mac_from='\(from)',mac_server='no',mac_note=''\(url.map { ",mac_url='\($0)'" } ?? "");</script>".utf8)
}

@Suite(.serialized) struct WwysSpiderTests {
    @Test func registryDrivesWwys() {
        #expect(SpiderRegistry.bundled(bundle: .repoSpiders).canDrive("csp_Wwys"))
        #expect(SpiderRegistry.ported.contains("Wwys"))
    }

    // The site's categories without 小姐姐 (20, empty and the only questionable one), upstream's 类型 filter on 1 and 2,
    // and no request.
    @Test func homeListsSixCategoriesWithout20() async throws {
        WwysSite.serve([:])
        let home = try object(try await spider().homeContent(filter: true))
        let classes = try #require(home["class"] as? [[String: String]])
        #expect(classes.map { $0["type_id"]! } == ["1", "2", "3", "4", "26", "31"])
        #expect(classes.map { $0["type_name"]! } == ["电影", "连续剧", "综艺", "动漫", "短剧", "音乐"])
        let filters = try #require(home["filters"] as? [String: [[String: Any]]])
        #expect(filters.keys.sorted() == ["1", "2"])
        let types = try #require(filters["2"]?.first)
        #expect(types["key"] as? String == "cateId" && types["name"] as? String == "类型")
        let values = try #require(types["value"] as? [[String: String]])
        #expect(values.map { $0["v"]! } == ["", "12", "13", "14", "15"])
        #expect(values.map { $0["n"]! } == ["全部", "国产剧", "港台泰", "日韩剧", "欧美剧"])
        let films = try #require(filters["1"]?.first?["value"] as? [[String: String]])
        #expect(films.map { $0["v"]! } == ["", "5", "6", "7", "8", "9", "10", "11", "16", "17"])
        #expect(WwysSite.requests.isEmpty)
    }

    // 今日更新: the first .globalPicList's twelve items, posters from data-src of the run-together <img … "<img …> tags.
    @Test func homeVideosAreTodaysUpdates() async throws {
        WwysSite.serve(["/": try home()])
        let items = try list(try await spider().homeVideoContent())
        #expect(items.count == 12)
        #expect(digest(strings(items, "vod_id").joined(separator: "|")) == "4363d953da2036d515e4792a76167aa1de9474244081fb3a03cfc9df84f16747")
        #expect(strings(items, "vod_name").first == "伟大的长征")
        #expect(strings(items, "vod_name").last == "法医秦明之龙番往事")
        #expect(strings(items, "vod_pic").first == "https://laudio-cdn.tencentmusic.com/image/207335/Y26hue52vLpk6h45_1791723630705.jpg")
        #expect(strings(items, "vod_remarks") == ["更新至15集0.0", "更新至14集0.0", "更新至16集0.0", "更新至10集0.0", "30集全0.0", "27集全0.0",
                                                  "24集全0.0", "10集全0.0", "更新至12集0.0", "20集全0.0", "34集全2.0", "24集全0.0"])
        #expect(urls == [site + "/"])
        #expect(WwysSite.requests.first?.headers["User-Agent"] == ua)
    }

    // The configured ext may carry `$$$` flags and a trailing slash; an empty ext means the same host.
    @Test func initKeepsOnlyTheHost() async throws {
        WwysSite.serve(["/": try home()])
        for ext in [site + "/$$$1", "", site + "$$$proxy"] {
            _ = try await spider(ext: ext).homeVideoContent()
        }
        #expect(urls == [site + "/", site + "/", site + "/"])
    }

    // Page 1 of 电影: 30 items and the footer's 共20720条 / 691 pages.
    @Test func categoryPagesWithTheFootersCounts() async throws {
        WwysSite.serve([listPath("1", 1): try category1()])
        let page = try object(try await spider().categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.count == 30)
        #expect(digest(strings(items, "vod_id").joined(separator: "|")) == "4d75da9e66f9fc9ce52f3a63d0a53bcabcc470381d184f0a5309efd4418e988f")
        #expect(digest(strings(items, "vod_name").joined(separator: "|")) == "ee356f15b976b53248e2864606c062c062a4c302edaf8c856dbb1371f3fda9b8")
        #expect(items.first?["vod_pic"] as? String == "https://laudio-cdn.tencentmusic.com/image/207335/HZXB43vSAmR81kpk_1787983534176.jpg")
        #expect(items.last?["vod_pic"] as? String == "https://image-70559.picnjc.qpic.cn/albumpic/b06f2de738f57bc44909bf1f2048d32b.jpg")
        #expect(Set(strings(items, "vod_remarks")) == ["0.0"])
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 691 && page["total"] as? Int == 20720)
        #expect(urls == [site + listPath("1", 1)])
    }

    // The 类型 filter replaces the category id; page 2 of 国产剧 is 2/116.
    @Test func categoryFilterAndSecondPage() async throws {
        WwysSite.serve([listPath("12", 2): try category12Page2()])
        let page = try object(try await spider().categoryContent(tid: "2", page: "2", filter: true, extend: ["cateId": "12"]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(digest(strings(items, "vod_id").joined(separator: "|")) == "8d7bdccd26ee3d886550b6807880b0379c2d812ccec6731401b1e0b5deaf79d8")
        #expect(digest(strings(items, "vod_name").joined(separator: "|")) == "067a1f278292696c6e1b6a80b1f2c98486a732e926b3965c1f0ebf57f7459895")
        #expect(items.first?["vod_remarks"] as? String == "21集全0.0")
        #expect(page["page"] as? Int == 2 && page["pagecount"] as? Int == 116 && page["total"] as? Int == 3459)
        #expect(urls == [site + listPath("12", 2)])
    }

    // A failed page is an empty page, which the runtime reports as the site being unreachable; a tid that is not a
    // number is an empty page without a request.
    @Test func categoryFailureIsEmpty() async throws {
        WwysSite.serve([:])
        let runtime = try await spider()
        await #expect(throws: SiteUnreachable.self) {
            try await runtime.categoryContent(tid: "3", page: "1", filter: false, extend: [:])
        }
        let odd = try object(try await runtime.categoryContent(tid: "../x", page: "1", filter: false, extend: [:]))
        #expect((odd["list"] as? [Any])?.isEmpty == true)
        #expect(urls == [site + listPath("3", 1)])
    }

    // Every field, and only line ② (lzm3u8, standard HLS): line ①'s segments are PNG-disguised and do not play on iOS.
    @Test func detailListsOnlyLine2() async throws {
        WwysSite.serve(["/vod-detail-id-96319.html": try detail96319(), "/vod-play-id-96319-src-1-num-1.html": try play96319()])
        let vod = try #require(try list(try await spider().detailContent(ids: ["96319"])).first)
        #expect(vod["vod_id"] as? String == "96319")
        #expect(vod["vod_name"] as? String == "伟大的长征")
        #expect(vod["vod_pic"] as? String == "https://laudio-cdn.tencentmusic.com/image/207335/Y26hue52vLpk6h45_1791723630705.jpg")
        #expect(vod["vod_remarks"] as? String == "更新至15集")
        #expect(vod["vod_actor"] as? String == "于和伟 王劲松 朱刚日尧 何政军")
        #expect(vod["vod_director"] as? String == "张永新")
        #expect(vod["vod_year"] as? String == "2026")
        let content = try #require(vod["vod_content"] as? String)
        #expect(content.hasPrefix("以中央红军长征为主线") && content.hasSuffix("深刻道理。"))
        #expect(vod["vod_play_from"] as? String == "线路②")
        let episodes = try #require(vod["vod_play_url"] as? String)
        #expect(digest(episodes) == "6d9e5b7e53da48a4a6107db0ab868c60e0657ea1d9cbb3a96d30f712a067e0df")
        #expect(episodes.components(separatedBy: "#").count == 15)
        #expect(episodes.hasPrefix("第01集$https://v.lzcdn27.com/20261009/18602_052ef918/index.m3u8#"))
        #expect(!episodes.contains("123clouddisk") && !episodes.contains("$$$"))
        #expect(urls == [site + "/vod-detail-id-96319.html", site + "/vod-play-id-96319-src-1-num-1.html"])
    }

    // A film: one episode on line ②.
    @Test func detailOfAFilm() async throws {
        WwysSite.serve(["/vod-detail-id-94741.html": try detail96319(), "/vod-play-id-94741-src-1-num-1.html": try play94741()])
        let vod = try #require(try list(try await spider().detailContent(ids: ["94741"])).first)
        #expect(vod["vod_play_from"] as? String == "线路②")
        #expect(vod["vod_play_url"] as? String == "第01集$https://v.lfthirtytwo.com/20260817/9549_253c93dd/index.m3u8")
    }

    // No line ② (only monday), or no mac_url at all: the title's details with no play line, never line ①.
    @Test func detailWithoutLine2HasNoPlayLine() async throws {
        let only1 = playPage(from: "monday", url: "第01集$https://1853039965.cdn.123clouddisk.com/a.m3u8")
        for play in [only1, playPage(from: "monday$$$lzm3u8", url: nil), Data()] {
            WwysSite.serve(["/vod-detail-id-96319.html": try detail96319(), "/vod-play-id-96319-src-1-num-1.html": play])
            let vod = try #require(try list(try await spider().detailContent(ids: ["96319"])).first)
            #expect(vod["vod_name"] as? String == "伟大的长征")
            #expect((vod["vod_play_from"] as? String ?? "") == "")
            #expect((vod["vod_play_url"] as? String ?? "") == "")
        }
        // Line ② first is still line ② (matched by its code, not its position).
        WwysSite.serve(["/vod-detail-id-96319.html": try detail96319(),
                        "/vod-play-id-96319-src-1-num-1.html": playPage(from: "lzm3u8$$$monday", url: "a$https://v.x.com/1.m3u8$$$b$https://c.com/2.m3u8")])
        let vod = try #require(try list(try await spider().detailContent(ids: ["96319"])).first)
        #expect(vod["vod_play_url"] as? String == "a$https://v.x.com/1.m3u8")
    }

    // A failed detail page, or an id that is not a number, gives no title and asks for nothing more.
    @Test func detailFailureIsEmpty() async throws {
        WwysSite.serve([:])
        let runtime = try await spider()
        #expect(try list(try await runtime.detailContent(ids: ["96319"])).isEmpty)
        #expect(try list(try await runtime.detailContent(ids: ["1/../2"])).isEmpty)
        #expect(urls == [site + "/vod-detail-id-96319.html"])
    }

    // 长征: five results, the keyword percent-encoded, the rating as the remark (category pages show the same).
    @Test func searchFindsTheTitles() async throws {
        WwysSite.serve(["/index.php?m=vod-search&wd=%E9%95%BF%E5%BE%81": try searchPage()])
        let items = try list(try await spider().searchContent(key: "长征", quick: false, page: "1"))
        #expect(strings(items, "vod_id") == ["96319", "73999", "73471", "28481", "6443"])
        #expect(strings(items, "vod_name") == ["伟大的长征", "长征先锋", "向着星辰的长征", "长征", "长征1996"])
        #expect(strings(items, "vod_remarks") == ["0.0", "8.0", "6.0", "10.0", "2.0"])
        #expect(items.first?["vod_pic"] as? String == "https://laudio-cdn.tencentmusic.com/image/207335/Y26hue52vLpk6h45_1791723630705.jpg")
        #expect(items.last?["vod_pic"] as? String == "https://img.liangzipic.com/upload/vod/20220424-1/93c71ca0ed424a91fa80223583415cda.jpg")
        #expect(urls == [site + "/index.php?m=vod-search&wd=%E9%95%BF%E5%BE%81"])
        // The site's search has no pages; a later page or an empty keyword asks for nothing.
        WwysSite.serve([:])
        #expect(try list(try await spider().searchContent(key: "长征", quick: false, page: "2")).isEmpty)
        #expect(try list(try await spider().searchContent(key: " ", quick: false, page: "1")).isEmpty)
        #expect(WwysSite.requests.isEmpty)
    }

    // The episode id is the m3u8 itself: upstream's relay chain only echoes it (gate #8, #12, #13), so no request.
    @Test func playReturnsTheM3u8Directly() async throws {
        WwysSite.serve([:])
        let runtime = try await spider()
        let m3u8 = "https://v.lzcdn27.com/20261009/18602_052ef918/index.m3u8"
        let play = try object(try await runtime.playerContent(flag: "线路②", id: m3u8, vipFlags: []))
        #expect(play["url"] as? String == m3u8)
        #expect(play["parse"] as? Int == 0)
        #expect(play["header"] as? [String: String] == ["User-Agent": ua])
        let bad = try object(try await runtime.playerContent(flag: "线路②", id: "javascript:x", vipFlags: []))
        #expect(bad["url"] as? String == "")
        #expect(WwysSite.requests.isEmpty)
    }
}

// MARK: - Gate replies (raw deflate, base64). Sources and SHA-256 in docs/IOS-POC-57B-17-wwys.md §3.

private let homePacked = """
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
"""

private let category1Packed = """
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
"""

private let category12Page2Packed = """
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
2vcXZccqnoOdeFq/BxtUyeb/Aw==
"""

private let detailPacked = """
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
"""

private let play96319Packed = """
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
"""

private let play94741Packed = """
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
"""

private let searchPacked = """
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
bXntn1h5rd/m/h8=
"""
