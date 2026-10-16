import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-15 (W-41): Ikanbot.js against pages fetched once from www1.ikanbot.com on 2026-10-15 07:04–07:05 UTC
// (Manager #2158 B1: the gate's own copies were lost; getResN and the 404 page are byte-identical to the gate's),
// plus hand-made edge replies. Expected values come from those pages through a separate parser (task document).

/// Answers any host by path and remembers every request.
final class IkanbotSite: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: Data], status: [String: Int] = [:]) {
        lock.withLock { replies = served.mapValues { (200, $0) }.merging(status.mapValues { ($0, Data()) }) { _, new in new }; seen = [] }
    }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append(Seen(url: url, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.replies[url.path] ?? (404, Data())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                               headerFields: ["Content-Type": "text/html"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A fetched page, raw-deflated and base64-encoded, checked against the SHA-256 recorded when it was fetched.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func home() throws -> Data { try fixture(homePacked, sha256: "a2ecf39919181a774b2df9cc4c905f5ea05b97ee178adc970dbe93a82671c7ee") }
private func hotMovie() throws -> Data { try fixture(hotPacked, sha256: "1f0cffece2bbed77f0b4b54103999c371ed024cbdd59c361aa31899dcbdc1738") }
private func kanlist() throws -> Data { try fixture(kanlistPacked, sha256: "e85a5ede0436f5302c8133488cf003348617786976ca6da9f379a6d87eb7e5ac") }
private func article() throws -> Data { try fixture(articlePacked, sha256: "35234a248bc29f3eccbc48bcf8bfcb9dd8db0a8ed46523f6c82bbf92131cb7f0") }
private func search() throws -> Data { try fixture(searchPacked, sha256: "96da3c8171ea47c24e397ec46bb5deb8866d982abb704ae00bdf1374721882e4") }
private func detailPage() throws -> Data { try fixture(detailPacked, sha256: "4043a02b845b5d5bdd58207b2ab07d4b0fdb4b46f057dfd9d1e836f47e9594d0") }
/// The gate's own getResN.json (sha256 1c5bce42…), returned again byte for byte on 2026-10-15.
private func getResN() throws -> Data { try fixture(getResNPacked, sha256: "1c5bce425ed0066246198fc63d5be75f9af10de0faf36b330f67134ef02bc4ea") }

private let site = "https://www1.ikanbot.com"
private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
private func douban(_ url: String) -> String { url + #"@Headers={"User-Agent":"\#(chrome)","Referer":"https://www.douban.com"}"# }

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IkanbotSite.self]
    return URLSession(configuration: configuration)
}

private let suite = "Ikanbot-test"

private func spider(extend: String = "") async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "Ikanbot", script: try #require(registry.entry(for: "csp_Ikanbot")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: extend)
    return runtime
}

private func client() async throws -> SourceClient {
    let site = try JSONDecoder().decode(Site.self, from: Data(#"{"key":"ik","name":"爱看 • 影视","type":3,"api":"csp_Ikanbot"}"#.utf8))
    return .spider(SpiderSession(site: site, runtime: try await spider()), site)
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func strings(_ items: [[String: Any]], _ key: String) -> [String] { items.map { $0[key] as? String ?? "<none>" } }
private var paths: [String] { IkanbotSite.requests.map(\.url.path) }

/// A synthetic detail page carrying just the three fields detail reads.
private func detailPage(id: String, token: String) -> Data {
    Data(#"<html><body><h1>T</h1><input id="current_id" value="\#(id)"><input id="mtype" value="1"><input id="e_token" value="\#(token)"></body></html>"#.utf8)
}
/// A synthetic getResN reply whose lines are (flag, urls).
private func lines(_ rows: [(String, [String])]) throws -> Data {
    let list = try rows.map { flag, urls -> [String: Any] in
        let episodes = urls.map { ["flag": flag, "url": $0] }
        return ["resData": String(decoding: try JSONSerialization.data(withJSONObject: episodes), as: UTF8.self)]
    }
    return try JSONSerialization.data(withJSONObject: ["state": 0, "data": ["list": list]])
}

@Suite(.serialized) struct IkanbotSpiderTests {
    // K1/I28: the registry drives csp_Ikanbot from its own file (RED before this task).
    @Test func registryDrivesIkanbot() {
        let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
        #expect(registry.canDrive("csp_Ikanbot"))
        #expect(SpiderRegistry.aliases["Ikanbot"] == nil)
    }

    // I03/I04: four categories and upstream's filter JSON, unchanged (stray spaces and all), without a request.
    @Test func homeListsFourCategoriesAndUpstreamFilters() async throws {
        IkanbotSite.serve([:])
        let home = try object(try await spider().homeContent(filter: true))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + ":" + $0["type_name"]! }
                == ["hot/index-movie-热门:电影", "hot/index-tv-热门:剧集", "billboard:榜单", "kanlist/全部:片单"])
        let filters = try JSONSerialization.data(withJSONObject: try #require(home["filters"]), options: [.sortedKeys, .withoutEscapingSlashes])
        // sha256 of Ikanbot.java:313's JSON, re-serialised with sorted keys (computed from the Java source).
        #expect(SHA256.hash(data: filters).map { String(format: "%02x", $0) }.joined()
                == "3abebb4c7bfd95884afedfc7e941b7f3aae7f3e52aae62a3e7aec79a8f037631")
        #expect(IkanbotSite.requests.isEmpty)
    }

    // I01/I05: both v-list blocks of the home page (24 items, not 12), canonical ids, d()-wrapped posters, no tag.
    @Test func homeVideosWalkBothListsWithCanonicalIds() async throws {
        IkanbotSite.serve(["": try home(), "/": try home()])
        let items = try list(try await spider().homeVideoContent())
        try #require(items.count == 24)
        #expect(strings(items, "vod_id")[0] == "/play/978607" && strings(items, "vod_id")[12] == "/play/1026022")
        #expect(strings(items, "vod_name")[0] == "希望")
        #expect(strings(items, "vod_pic")[0] == douban("https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2925247432.jpg"))
        #expect(items.allSatisfy { $0["vod_tag"] == nil })
        #expect(IkanbotSite.requests.map(\.url.absoluteString) == [site])
        #expect(IkanbotSite.requests.first?.headers == ["User-Agent": chrome, "Referer": site])
    }

    // I11/K9 (B1: live values), I12: a hot list is 24 `div.item` (48 with `.item`), each a tagged file.
    @Test func aHotCategoryListsTaggedFiles() async throws {
        IkanbotSite.serve(["/hot/index-movie-热门.html": try hotMovie()])
        let page = try object(try await spider().categoryContent(tid: "hot/index-movie-热门", page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.count == 24)
        #expect(items[0]["vod_id"] as? String == "/play/978607" && items[0]["vod_name"] as? String == "希望")
        #expect(items[0]["vod_pic"] as? String == douban("https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2925247432.jpg"))
        #expect(Set(strings(items, "vod_tag")) == ["file"])
        #expect(page["page"] as? Int == 1 && page["limit"] as? Int == 24)
        #expect(paths == ["/hot/index-movie-热门.html"])
        #expect(IkanbotSite.requests.first?.headers == ["User-Agent": chrome, "Referer": site])
        let decoded = try await client().category(id: "hot/index-movie-热门", page: 1, extend: [:])
        #expect(decoded.list.count == 24 && decoded.list.allSatisfy { !$0.isFolder && $0.tag == "file" })
    }

    // I09/K7, I12: 片单 lists 15 folders whose posters are not wrapped, and they decode as folders.
    @Test func kanlistListsFolders() async throws {
        IkanbotSite.serve(["/kanlist/全部-p-1.html": try kanlist()])
        let items = try list(try await spider().categoryContent(tid: "kanlist/全部", page: "1", filter: false, extend: [:]))
        #expect(items.count == 15)
        let first = try #require(items.first as? [String: String])
        #expect(first == ["vod_id": "/article/233", "vod_name": "极度舒适！9部反杀爽片！看完了拍手叫好！",
                          "vod_pic": "https://img1.ikanbot.com/images/e/a2/bfd4515ebee38ad0d53a6590809d3a2e.jpg",
                          "vod_remarks": "", "vod_tag": "folder"])
        #expect(Set(strings(items, "vod_tag")) == ["folder"])
        #expect(paths == ["/kanlist/全部-p-1.html"])
        let decoded = try await client().category(id: "kanlist/全部", page: 1, extend: [:])
        #expect(decoded.list.count == 15 && decoded.list.allSatisfy(\.isFolder))
        // K12: a folder poster is a plain address, so the app loads it as before.
        #expect(ImageRequest.parse(decoded.list[0].picture) == nil)
    }

    // I10/K8, I08b: an article (a folder) lists 9 files from its own path, extend or not; page 2 is empty and asks nothing.
    @Test func anArticleListsFilesAndHasOnePage() async throws {
        IkanbotSite.serve(["/article/233": try article()])
        let runtime = try await spider()
        let items = try list(try await runtime.categoryContent(tid: "/article/233", page: "1", filter: false, extend: ["cateId": "kanlist/剧情"]))
        #expect(items.count == 9)
        #expect(items[0]["vod_id"] as? String == "/play/420851" && items[0]["vod_name"] as? String == "狗镇")
        #expect(items[0]["vod_pic"] as? String == douban("https://img2.doubanio.com/view/photo/s_ratio_poster/public/p2457169802.jpg"))
        #expect(Set(strings(items, "vod_tag")) == ["file"])
        #expect(IkanbotSite.requests.map(\.url.absoluteString) == [site + "/article/233"])
        #expect(try list(try await runtime.categoryContent(tid: "/article/233", page: "2", filter: false, extend: ["cateId": "kanlist/剧情"])).isEmpty)
        #expect(IkanbotSite.requests.count == 1)
    }

    // I06–I08/K6: the address rules, with iOS's filter=false still applying extend.
    @Test func categoryAddressesFollowUpstreamTemplates() async throws {
        IkanbotSite.serve([:])
        let runtime = try await spider()
        func ask(_ tid: String, _ page: String, _ extend: [String: String] = [:]) async throws -> [String] {
            IkanbotSite.serve([:])
            _ = try? await runtime.categoryContent(tid: tid, page: page, filter: false, extend: extend)
            return paths
        }
        #expect(try await ask("kanlist/全部", "1", ["cateId": "kanlist/剧情"]) == ["/kanlist/剧情-p-1.html"])
        #expect(try await ask("kanlist/全部", "1", ["cateId": ""]) == ["/kanlist/全部-p-1.html"])
        #expect(try await ask("kanlist/全部", "2") == ["/kanlist/全部-p-2.html"])
        #expect(try await ask("hot/index-movie-热门", "2") == ["/hot/index-movie-热门-p-2.html"])
        #expect(try await ask("hot/index-movie-热门", "1", ["cateId": "hot/index-movie-最新"]) == ["/hot/index-movie-最新.html"])
        #expect(try await ask("billboard", "1") == ["/billboard.html"])
        #expect(try await ask("billboard", "2") == [])
        #expect(try await ask("/article/233", "2") == [])
    }

    // I13: a failed page is an empty list, which the runtime turns into "site unreachable".
    @Test func aFailedCategoryIsUnreachable() async throws {
        IkanbotSite.serve([:], status: ["/kanlist/全部-p-1.html": 404])
        let runtime = try await spider()
        await #expect(throws: SiteUnreachable.self) {
            _ = try await runtime.categoryContent(tid: "kanlist/全部", page: "1", filter: false, extend: [:])
        }
    }

    // I14–I19, I21/K2–K4, K11: detail page, then getResN with the derived token and exactly four headers; 31 lines.
    @Test func detailReadsThePageThenItsLines() async throws {
        IkanbotSite.serve(["/play/995772": try detailPage(), "/api/getResN": try getResN()])
        let runtime = try await spider()
        let vod = try #require(try list(try await runtime.detailContent(ids: ["/play/995772"])).first)
        #expect(IkanbotSite.requests.map(\.url.absoluteString) == [
            site + "/play/995772",
            site + "/api/getResN?videoId=995772&mtype=1&token=5dba759abf70c447fa65b47936fe3a3e"])
        #expect(IkanbotSite.requests[0].headers == ["User-Agent": chrome, "Referer": site])
        #expect(IkanbotSite.requests[1].headers == ["User-Agent": chrome, "Referer": site + "/play/995772",
                                                    "Accept": "*/*", "X-Requested-With": "XMLHttpRequest"])
        #expect(vod["vod_id"] as? String == "/play/995772" && vod["vod_name"] as? String == "功夫女足")
        #expect(vod["vod_pic"] as? String == douban("https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2933860063.jpg"))
        #expect(vod["vod_year"] as? String == "" && vod["vod_area"] as? String == "" && vod["vod_actor"] as? String == "")
        let from = (vod["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
        let urls = (vod["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
        #expect(from.count == 31 && urls.count == 31)
        #expect(from[0] == "js线路" && from[14] == "ff线路" && from[4] == "db线路" && from[15] == "db线路")
        #expect(from[10] == "1080zyk" && from[28] == "360zy")
        #expect(urls[24] == "HD$https://vod12.wgslsw.com/20261004/PTurtabi7h90/index.m3u8")
        #expect(urls[4] == "正片$https://vodcnd17.ajupf.com/20261003/Qzqulcoh/index.m3u8##")
        // The whole of both fields, as a separate parser derived them from getResN.json.
        func digest(_ key: String) -> String { SHA256.hash(data: Data((vod[key] as? String ?? "").utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(digest("vod_play_from") == "e4619f4d44512435ee484bddeea6ca5d77f615003017378fa35ef01ee2726f26")
        #expect(digest("vod_play_url") == "7179719228f8fa593939dfc3502ffdd33183f12dda69028c913f1c224283f35f")
        // The app splits each line with its usual parser: ff线路 is one episode.
        #expect(Episode.parse(urls[14]).count == 1)
        // An old compound id still opens the same title, under its canonical id.
        IkanbotSite.serve(["/play/995772": try detailPage(), "/api/getResN": try getResN()])
        let old = try #require(try list(try await runtime.detailContent(ids: ["/play/995772$$$功夫女足$$$" + douban("x")])).first)
        #expect(old["vod_id"] as? String == "/play/995772" && paths.first == "/play/995772")
    }

    // K2/I22/I23: no token, no getResN; broken line data costs only that line or the detail.
    @Test func aDetailWithoutATokenOrWithBrokenLinesFailsQuietly() async throws {
        let runtime = try await spider()
        for (id, token) in [("77", String(repeating: "a", count: 42)), ("99a772", String(repeating: "a", count: 42)),
                            ("995772", String(repeating: "a", count: 20))] {
            IkanbotSite.serve(["/play/1": detailPage(id: id, token: token)])
            #expect(try list(try await runtime.detailContent(ids: ["/play/1"])).isEmpty, "\(id)")
            #expect(paths == ["/play/1"], "\(id)")
        }
        let token = String(repeating: "0123456789", count: 5)
        let rows = try JSONSerialization.data(withJSONObject: ["data": ["list": [
            ["resData": ""], ["resData": "not json"], ["resData": #"[{"flag":"okm3u8","url":"第1集$https://a/1.m3u8$okm3u8"}]"#]]]])
        IkanbotSite.serve(["/play/1": detailPage(id: "1000", token: token), "/api/getResN": rows])
        let vod = try #require(try list(try await runtime.detailContent(ids: ["/play/1"])).first)
        #expect(vod["vod_play_from"] as? String == "ok线路" && vod["vod_play_url"] as? String == "第1集$https://a/1.m3u8")
        for reply in [Data(#"{"data":{}}"#.utf8), Data("oops".utf8)] {
            IkanbotSite.serve(["/play/1": detailPage(id: "1000", token: token), "/api/getResN": reply])
            #expect(try list(try await runtime.detailContent(ids: ["/play/1"])).isEmpty)
        }
        IkanbotSite.serve(["/play/1": detailPage(id: "1000", token: token)], status: ["/api/getResN": 500])
        #expect(try list(try await runtime.detailContent(ids: ["/play/1"])).isEmpty)
        IkanbotSite.serve([:])
        #expect(try list(try await runtime.detailContent(ids: ["play/1"])).isEmpty)
        #expect(IkanbotSite.requests.isEmpty)
    }

    // I02/I20/K5 (synthetic, not live), J-02/J-03, J-13: a mirror host and [排序:]; every match moves, once, in key order.
    @Test func sortExtendMovesEveryMatchOnceOnAMirrorHost() async throws {
        let runtime = try await spider(extend: "https://mirror.example.com[排序:ff,ik]")
        let token = String(repeating: "0123456789", count: 5)
        IkanbotSite.serve(["/play/1": detailPage(id: "1000", token: token), "/api/getResN": try lines([
            ("a", ["1$https://a/a"]), ("ff1", ["1$https://a/f1"]), ("ff2", ["1$https://a/f2"]), ("b", ["1$https://a/b"]),
            ("ik1", ["1$https://a/i"]), ("m3u8m3u8", ["第1集$https://a/1.m3u8$m3u8m3u8#", "第2集$https://a/2.m3u8$m3u8m3u8"])])])
        let vod = try #require(try list(try await runtime.detailContent(ids: ["/play/1"])).first)
        let from = (vod["vod_play_from"] as? String ?? "").components(separatedBy: "$$$")
        #expect(from == ["ff1", "ff2", "ik1", "a", "b", "线路线路"])
        #expect(from != ["ff1", "ik1", "a", "ff2", "b", "线路线路"])
        #expect((vod["vod_play_url"] as? String ?? "").components(separatedBy: "$$$")
                == ["1$https://a/f1", "1$https://a/f2", "1$https://a/i", "1$https://a/a", "1$https://a/b",
                    "第1集$https://a/1.m3u8#第2集$https://a/2.m3u8"])
        #expect(IkanbotSite.requests.map { $0.url.host ?? "" } == ["mirror.example.com", "mirror.example.com"])
        #expect(IkanbotSite.requests[0].headers["Referer"] == "https://mirror.example.com")
        // Without the extend the order is upstream's.
        IkanbotSite.serve(["/play/1": detailPage(id: "1000", token: token), "/api/getResN": try lines([("a", ["1$x"]), ("ff1", ["1$y"])])])
        #expect(try list(try await spider().detailContent(ids: ["/play/1"])).first?["vod_play_from"] as? String == "a$$$ff1")
    }

    // I24/K13, I26, K12: search encodes the keyword, trims a trailing year, keeps the label; canonical ids.
    @Test func searchListsCanonicalTitlesWithLabels() async throws {
        IkanbotSite.serve(["/search": try search()])
        let runtime = try await spider()
        let items = try list(try await runtime.searchContent(key: " 功夫女足 ", quick: false, page: "1"))
        #expect(items.count == 10)
        #expect(strings(items, "vod_id").prefix(2) == ["/play/995772", "/play/1001522"])
        #expect(strings(items, "vod_name").prefix(2) == ["功夫女足", "功夫女足之外星人篇"])
        #expect(strings(items, "vod_remarks").prefix(2) == ["[31条线路可播放]", "[10条线路可播放]"])
        let poster = try #require(items.first?["vod_pic"] as? String)
        #expect(poster == douban("https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2933860063.jpg"))
        let image = try #require(ImageRequest.parse(poster))
        #expect(image.url.absoluteString == "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2933860063.jpg")
        #expect(image.headers == ["Referer": "https://www.douban.com", "User-Agent": chrome])
        #expect(IkanbotSite.requests.map(\.url.absoluteString) == [site + "/search?q=%E5%8A%9F%E5%A4%AB%E5%A5%B3%E8%B6%B3"])
        IkanbotSite.serve(["/search": Data("<html><body><p>none</p></body></html>".utf8)])
        #expect(try list(try await runtime.searchContent(key: "a b", quick: false, page: "2")).isEmpty)
        #expect(IkanbotSite.requests.map(\.url.absoluteString) == [site + "/search?q=a%20b&p=2"])
        IkanbotSite.serve([:])
        #expect(try list(try await runtime.searchContent(key: "  ", quick: false, page: "1")).isEmpty)
        #expect(IkanbotSite.requests.isEmpty)
    }

    // FOLDER-04: the compatibility pack never carries Ikanbot; since IOS-POC-61 S5 the official pack must, being the
    // only way it reaches an App (scripts/test_pack_exclusions.py builds both).
    @Test func onlyTheOfficialPackCarriesIkanbot() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-I", "scripts/test_pack_exclusions.py"]
        python.currentDirectoryURL = repo
        python.standardOutput = FileHandle.nullDevice
        try python.run()
        python.waitUntilExit()
        #expect(python.terminationStatus == 0)
    }

    // I25/K10: play directly with exactly one header, User-Agent.
    @Test func playIsDirectWithOnlyTheUserAgent() async throws {
        let play = try object(try await spider().playerContent(flag: "ff线路", id: "https://a/1.m3u8", vipFlags: []))
        #expect(play["parse"] as? Int == 0 && play["url"] as? String == "https://a/1.m3u8")
        #expect(play["header"] as? [String: String] == ["User-Agent": chrome])
    }
}

// MARK: fixtures (raw deflate, base64; fetched 2026-10-15 07:04–07:05 UTC, see docs/IOS-POC-57B-15-ikanbot.md)

private let homePacked = """
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
fPblaCJ/aL8L37MCfWskZNa/s2nw/wA=
"""

private let hotPacked = """
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
"""

private let kanlistPacked = """
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
"""

private let articlePacked = """
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
"""

private let searchPacked = """
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
"""

private let detailPacked = """
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
"""

private let getResNPacked = """
tZjLbttGFIZfpWCytMmZ4Vy1S5M2TVo7TmukAeLAGHJ4k2jqQo5kyvCyaPMELdBll4XRbTZ9myZp36KUnFhDyxwpcbuyLBBH35z/nP8czplTVrKKnB7ccU6i
spRJ89kpdRg2/zg7jpKVdHpnTp6VldN7ceaUWRU9Uk6Pgh0na/4iCBkFyN9xJlH5YPm08+LsyIlzmRw5vSOnX574mh85O0eOnuTLr/75/Ze3r3949+qnz+6m
VTUqe543nbr9rNTzeuqGwxNvlMvak3scsuJe5GWFik7dyzDnL53znRWGT00Mvxsj2Q7DTUqtyxWDekj5bJ8FNgbUZqCdDKf5NgyL33VP8wbD5HhMn34xQMrG
waDJAbs50nRrjjRtp+Mb8fjeycwqCUcfMBCGkKBODBWsYby9+O3dqx9XcgxVWCjIXNnXo3iJgQCiEADfezof6zwcpgbKnTtrMIQbOUGAdMIE8bxew/nqwRVK
HBVJIIfQX1JMMxUNvWRYJLEupnPt+TwIFAwa9RWyauQbPETATp5Z30YzFe5oNJ5MLqWZ9afifWK8JjMHh3pSySBjqQDvSW1yYYOIgu6qUXVV3cD05tc///7j
YkWWjdzFk7tlFLUFwwQycgwkIyDA1obyxQqJMdidpHx+A9Bfry/eXPxstHQeV2k2qepqNmwTQYgQO4bKFwIwbCMipmzM0lqDcI3o8P6KBWJ3oGUWptFltS15
6rr5fkkFWMPkPZ+ffM/vM71/iNiafnfMKoCkIxwxygF/Vwp9Ojs8eHhDuPXcmw0jOOg8KQQczOuBvRpCVbj1fF77aHdpJ630E8h9dOyHmErKrelnyEw/E51Q
pdqU/vF4PCmr2+f9WpxPTzjlLdfuPltab+PaC1lGbqprmefGKP168vRe/q3Vt7ExxjjAuBMkG2zy7SDOBrpYiN8SPHzii/0iGVspzN6HtLv343izGZV6FE3c
uLH23WGRZ0VEr1kS8jk4BiqgCEGrJQlztnIsPmaoGRUY+G6g5nUQI7SaI+VVDSKPSoIYiynyBY4ViRkghGElPCyZaK0hZkFawl6WJJUhaNLJACYIchIToXzo
K+qBWDASW+vT3G4Y6RakLKwTq+mZpmG0qcDHNwszhxVD3TBznSm5yQuWD/1XRnxTsE93BU6MNsCWPeGk2nqJ0tN+laVuWKwaYMYq9rwf+dbSB61p3D0RJvXm
aVwu9oNJvTClRoBWMyIAGDgOcLNFUWDfD1Br4ebd7x5ZUWdFso1vpqoZpYPqVH+caTJhFiTv1qmuN1Xjojv09PaFeC3OLWpQtDyPdZ6tsp6tqutyXs+aMrR5
Hqc8EhEELMY+RTTyQ+4BgALFO45qCWt4nkIxUaHgIcZchkEkUVNoYYy4teS56faUda97w8EmVWspZRDeXtVrcT5dVWQOWN+y79ep1c+HCiJ3lpR5OTP7GLdf
P1Ygdy/jrb+iYd8E8rv9Ra8nmyFwcIWkB/O6wfJdPdBBTNrukkeR3CcJscpu3mlQ0n2ZUBSbZE+SNOsPbi/7tTi3aGZmbHfQcl+TjetNE2W5yuc1pMth3qOk
3Xwfei8UMYoRwBKHIgqjmAbYi3kSNGuHzVGJCYq7QX3avH9sGHzQPZHDmS7TbG0TfXS492ViBWld66Duuix18L/e64jVhYqAQFjul7JEyy1n8GmynMHsKi+7
EOwuqqpZEsFxurcXoeAZ6E/kOD34PHyWrgG+PD//Fw==
"""
