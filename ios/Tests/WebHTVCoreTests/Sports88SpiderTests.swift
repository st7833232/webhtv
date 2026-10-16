import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-14 (W-105): Sports88.js, which also drives qist 0825's csp_Kanqiu, against the pages and /source
// replies 88kanqiu.la/.tw returned on 2026-10-13 (W-102 gate) and hand-made edge replies (W-105 review-prep N1–N16).

/// Answers both 88kanqiu mirrors by path (query ignored) and remembers every request.
final class Kanqiu88Site: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: (status: Int, body: Data)]) { lock.withLock { replies = served; seen = [] } }
    static func serve(_ served: [String: Data]) { serve(served.mapValues { (200, $0) }) }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["www.88kanqiu.la", "www.88kanqiu.tw"].contains(request.url?.host ?? "")
    }
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

/// A gate reply, raw-deflated and base64-encoded, checked against the SHA-256 the gate recorded.
private func fixture(_ packed: String, sha256: String) throws -> Data {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return data
}

private func homeLa() throws -> Data { try fixture(homeLaPacked, sha256: "1a261f6421321723733fb5c3fd115aff56b963bdac378b2b1f2ccf2f5b189d7f") }
private func categoryTw1() throws -> Data { try fixture(categoryTw1Packed, sha256: "eb9aacacbcffb49d3533b7915e82489f9872f85225a0976d1a1e17ef18cb4185") }
private func categoryLa4() throws -> Data { try fixture(categoryLa4Packed, sha256: "74eab9f72181e81ea3dfc2ffc262c42c50e6ca9ebdd0b5ccc99e38b08e7896ac") }
private func source129230() throws -> Data { try fixture(source129230Packed, sha256: "cba04afcbfdb7380f8f0c93e64ff38fc284bcffe7892d50b92283c8c4596caa7") }
private func source129494() throws -> Data { try fixture(source129494Packed, sha256: "4e94ab336491dac7ad21a9380a05a819aeff2c193afde5465077067b45c88a8f") }
private func sourceTw129230() throws -> Data { try fixture(sourceTw129230Packed, sha256: "9e7c2e127fa58f107850af6abb105247db0541a4a7ecc76564df9167454d84b5") }

private let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
private let poster = "https://www.88kanqiu.la/static/img/default.png?t=1788942357"

/// 129230's ten 88player lines in the gate's order (`links-la-129230.json`); the other nine are third-party pages.
private let lines129230: [(String, String)] = [
    ("腾讯直播5", "https://www.rtmpcdn.com/live/qq5.m3u8"),
    ("线路A2", "https://www.rtmpcdn.com/live/6e2f05b5-4066-480d-b535-c718e7a6d902.m3u8"),
    ("线路Q1", "https://live3.dyrur1.com/live/14488433_8fcdf2711343eea196629e7c9ef96954_1080p.m3u8?auth_key=1791866085-0-0-ccc1d47fcb14cdb7c6a2c7c65774dc1d"),
    ("线路Q3", "https://hello.ooo0ooo.top/live/3925715.m3u8"),
    ("线路A4", "https://live.dyrur1.com/live/14208454_2d9991b64db34215cac3cbecba02419c_1080p.m3u8?auth_key=1791867452-0-0-86aef70da4c89b36a67f4c8152589ca5"),
    ("线路Q1 (2)", "https://live.dyrur1.com/live/14208454_2d9991b64db34215cac3cbecba02419c_1080p.m3u8?auth_key=1791868708-0-0-fb1f3351273394758a17c7f519ee48a1"),
    ("线路A4 (2)", "https://live.dyrur1.com/live/14208454_2d9991b64db34215cac3cbecba02419c_1080p.m3u8?auth_key=1791869263-0-0-46e147f8c75948381b79592c80f576d6"),
    ("线路Q1 (3)", "https://live.dyrur1.com/live/14208454_2d9991b64db34215cac3cbecba02419c_1080p.m3u8?auth_key=1791870335-0-0-0423348016127ab7adfc16cce58844d7"),
    ("线路Q1 (4)", "https://live.dyrur1.com/live/14208454_2d9991b64db34215cac3cbecba02419c_1080p.m3u8?auth_key=1791872323-0-0-b4772b67e381f113b50acdb879644dd0"),
    ("线路Q1 (5)", "https://live.dyrur1.com/live/14208454_2d9991b64db34215cac3cbecba02419c_1080p.m3u8?auth_key=1791874112-0-0-6522fc77856107b5aa1b5205ee6ec608"),
]

/// A /source reply the way the site wraps it: six junk characters, base64 of the JSON, two junk characters.
private func sourceReply(_ links: Any, padded: Bool = true) throws -> Data {
    var encoded = try JSONSerialization.data(withJSONObject: ["shareStatus": 0, "links": links]).base64EncodedString()
    if !padded {
        guard encoded.hasSuffix("=") else { throw FixtureMismatch() }  // the case must really lose its padding
        encoded = encoded.replacingOccurrences(of: "=", with: "")
    }
    return try JSONSerialization.data(withJSONObject: ["data": "abcdef" + encoded + "zz"])
}
private func wrapped(_ query: String, host: String = "https://play.88player.top") -> String { host + "/m3u8.html?" + query }

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Kanqiu88Site.self]
    return URLSession(configuration: configuration)
}

private let suite = "Sports88-test"

private func spider(_ name: String = "Sports88", extend: String = "") async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: name, script: try #require(registry.entry(for: "csp_" + name)?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: extend)
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func header(_ seen: Kanqiu88Site.Seen, _ name: String) -> String? {
    seen.headers.first { $0.key.lowercased() == name.lowercased() }?.value
}
/// The one detail's play fields, and its lines as (name, url) pairs.
private func detail(_ text: String) throws -> (vod: [String: Any], lines: [(String, String)]) {
    let vod = try #require(try list(text).first)
    let url = vod["vod_play_url"] as? String ?? ""
    let lines = url.isEmpty ? [] : url.components(separatedBy: "#").map { pair -> (String, String) in
        let parts = pair.components(separatedBy: "$")
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }
    return (vod, lines)
}
private func same(_ a: [(String, String)], _ b: [(String, String)]) -> Bool { a.map { $0.0 + "$" + $0.1 } == b.map { $0.0 + "$" + $0.1 } }

@Suite(.serialized) struct Sports88SpiderTests {
    // N1: Kanqiu is an alias of Sports88, never a file of its own.
    @Test func csp_KanqiuIsAnAliasOfSports88() throws {
        #expect(SpiderRegistry.ported.isSuperset(of: ["Sports88", "Kanqiu"]))
        #expect(SpiderRegistry.aliases["Kanqiu"] == "Sports88")
        let folder = try #require(Bundle.repoSpiders.url(forResource: "Spiders", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.filter { $0.lowercased().contains("sports88") || $0.lowercased().contains("kanqiu") } == ["Sports88.js"])
        let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
        #expect(registry.entry(for: "csp_Kanqiu")?.script == registry.entry(for: "csp_Sports88")?.script)
    }

    // N7: Kanqiu's four categories and the two filter rows that match them, without a request.
    @Test func homeListsFourCategoriesAndTheirFiltersWithoutAsking() async throws {
        Kanqiu88Site.serve([:] as [String: Data])
        let home = try object(try await spider().homeContent(filter: true))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + ":" + $0["type_name"]! }
                == [":全部直播", "1:篮球直播", "8:足球直播", "21:其他直播"])
        let filters = try #require(home["filters"] as? [String: [[String: Any]]])
        #expect(Set(filters.keys) == ["1", "8"])
        #expect(filters["1"]?.first?["key"] as? String == "cateId")
        #expect((filters["8"]?.first?["value"] as? [[String: String]])?.count == 15)
        #expect(Kanqiu88Site.requests.isEmpty)
    }

    // N5, N6, N8: of the gate home page's 58 matches only the two live ones, ids from their play links.
    @Test func theHomeCategoryListsOnlyTheLiveMatches() async throws {
        Kanqiu88Site.serve(["/": try homeLa()])
        let page = try object(try await spider().categoryContent(tid: "", page: "1", filter: false, extend: [:]))
        let request = try #require(Kanqiu88Site.requests.first)
        #expect(Kanqiu88Site.requests.count == 1)
        #expect(request.url.absoluteString == "https://www.88kanqiu.la/" && header(request, "User-Agent") == agent)
        let items = try #require(page["list"] as? [[String: String]])
        #expect(items == [
            ["vod_id": "129230", "vod_name": "09:00 NBA 爵士 VS 马刺", "vod_pic": poster, "vod_remarks": "直播中"],
            ["vod_id": "129494", "vod_name": "10:00 国际友谊 萨尔瓦多 VS 巴拉圭", "vod_pic": poster, "vod_remarks": "直播中"],
        ])
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 1)
    }

    // N7, R3: csp_Kanqiu runs the same script, on the .la mirror; a filter's cateId replaces the category.
    @Test func kanqiuCategoriesUseTheSameScriptAndCateIdReplacesTheCategory() async throws {
        Kanqiu88Site.serve(["/match/1/live": try categoryTw1(), "/match/4/live": try categoryLa4()])
        let kanqiu = try await spider("Kanqiu")
        let items = try list(try await kanqiu.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        #expect(items.map { $0["vod_id"] as? String } == ["129230"])
        #expect(Kanqiu88Site.requests.map(\.url.absoluteString) == ["https://www.88kanqiu.la/match/1/live"])
        // 篮球综合: an empty category page is no matches, not an error.
        #expect(try list(try await kanqiu.categoryContent(tid: "1", page: "1", filter: true, extend: ["cateId": "4"])).isEmpty)
        #expect(Kanqiu88Site.requests.last?.url.absoluteString == "https://www.88kanqiu.la/match/4/live")
    }

    // N7: a category or filter value that is not a number never reaches a URL; there is only one page.
    @Test func aBadCategoryOrALaterPageAsksNothing() async throws {
        Kanqiu88Site.serve(["/": try homeLa()])
        let s = try await spider()
        for (tid, extend) in [("../x", [:]), ("1?a", [:]), ("1", ["cateId": "8/../1"])] as [(String, [String: String])] {
            #expect(try list(try await s.categoryContent(tid: tid, page: "1", filter: true, extend: extend)).isEmpty)
        }
        #expect(try list(try await s.categoryContent(tid: "", page: "2", filter: false, extend: [:])).isEmpty)
        #expect(Kanqiu88Site.requests.isEmpty)
        // A failed page is an empty list, which the runtime reports as the site being unreachable.
        Kanqiu88Site.serve([:] as [String: Data])
        await #expect(throws: SiteUnreachable.self) {
            try await s.categoryContent(tid: "21", page: "1", filter: false, extend: [:])
        }
    }

    // N5: a match listed twice on one page is one card; a time row is no card.
    @Test func aRepeatedMatchIsOneCard() async throws {
        let item = #"<li class="list-group-item group-game-item"><div class="row d-none">甲 VS 乙 <a class="btn btn-primary" href="/live/7/play">直播中</a></div></li>"#
        Kanqiu88Site.serve(["/": Data((#"<ul><li class="list-group-item live-list-group-time">2026-10-13</li>"# + item + item + "</ul>").utf8)])
        let items = try list(try await spider().categoryContent(tid: "", page: "1", filter: false, extend: [:]))
        #expect(items.map { $0["vod_id"] as? String } == ["7"] && items.first?["vod_name"] as? String == "甲 VS 乙")
    }

    // N2, N3, N12, N13: only the 88player wrappers, unwrapped, in order, duplicate names numbered; the id is the match.
    @Test func aDetailListsOnlyThe88PlayerLinesUnwrapped() async throws {
        Kanqiu88Site.serve(["/live/129230/source": try source129230(), "/live/129494/source": try source129494()])
        let s = try await spider()
        let nba = try detail(try await s.detailContent(ids: ["129230"]))
        #expect(Kanqiu88Site.requests.map(\.url.absoluteString) == ["https://www.88kanqiu.la/live/129230/source"])
        #expect(header(try #require(Kanqiu88Site.requests.first), "User-Agent") == agent)
        #expect(nba.vod["vod_id"] as? String == "129230" && nba.vod["vod_play_from"] as? String == "88看球")
        #expect(same(nba.lines, lines129230))
        let friendly = try detail(try await s.detailContent(ids: ["129494"]))
        #expect(same(friendly.lines, [
            ("线路Q1", "https://live.dyrur1.com/live/14557733_eaeb1ee709569cff09514b9953d4ecff_1080p.m3u8?auth_key=1791872728-0-0-30bf4b24274a2bd6d0e8022c8fb7dfc8"),
            ("线路Q2", "https://hello.ooo0ooo.top/live/4657087.m3u8"),
        ]))
        // The .tw mirror's reply for the same match (other padding characters) decodes to the same lines.
        Kanqiu88Site.serve(["/live/129230/source": try sourceTw129230()])
        #expect(same(try detail(try await spider("Kanqiu").detailContent(ids: ["129230"])).lines, lines129230))
    }

    // N2, N3, N4, N13: the wrapper is recognised by exact host and path, and only its `url` parameter counts.
    @Test func onlyAnExact88PlayerWrapperWithAPlayableUrlBecomesALine() async throws {
        let links: [Any] = [
            ["name": "甲", "url": wrapped("foo=1&url=https%3A%2F%2Fc.example%2Fd.m3u8&t=2")],
            ["name": "乙", "url": wrapped("url=https://e.example/f.m3u8?auth_key=1-0-0-ab")],
            ["name": "丙", "url": wrapped("url=rtmp%3A%2F%2Fr.example%2Flive", host: "http://play.88player.top")],
            ["name": "丁", "url": wrapped("url=rtmps%3A%2F%2Fr.example%2Flive")],
            ["name": "", "url": wrapped("url=https%3A%2F%2Fg.example%2Fh.m3u8")],
            ["name": "线路(Q1", "url": wrapped("url=https%3A%2F%2Fi.example%2Fj.m3u8")],
            ["name": "a$b#c", "url": wrapped("url=https%3A%2F%2Fk.example%2Fl.m3u8")],
            ["name": "戊", "url": wrapped("url=https://m.example/%zz.m3u8")],
            ["name": "x1", "url": wrapped("xurl=https%3A%2F%2Fbad.example%2F1.m3u8")],
            ["name": "x2", "url": wrapped("url=https%3A%2F%2Fbad.example%2F2.m3u8&h=play.88player.top", host: "https://evil.example")],
            ["name": "x3", "url": wrapped("url=https%3A%2F%2Fbad.example%2F3.m3u8", host: "https://play.88player.top.evil.example")],
            ["name": "x4", "url": "https://play.88player.top/other.html?url=https%3A%2F%2Fbad.example%2F4.m3u8"],
            ["name": "x5", "url": wrapped("url=ftp%3A%2F%2Fbad.example%2F5.m3u8")],
            ["name": "x6", "url": wrapped("url=javascript%3Aalert(1)")],
            ["name": "x7", "url": wrapped("url=https%3A%2F%2Fbad.example%2F7.m3u8%23frag")],
            ["name": "x8", "url": "https://embed.st/embed/hotel/x/1"],
            ["name": "x9", "url": 7], 7, NSNull(),
        ]
        Kanqiu88Site.serve(["/live/1/source": try sourceReply(links)])
        let got = try detail(try await spider().detailContent(ids: ["1"])).lines
        #expect(same(got, [
            ("甲", "https://c.example/d.m3u8"),
            ("乙", "https://e.example/f.m3u8?auth_key=1-0-0-ab"),
            ("丙", "rtmp://r.example/live"),
            ("丁", "rtmps://r.example/live"),
            ("线路5", "https://g.example/h.m3u8"),
            ("线路 Q1", "https://i.example/j.m3u8"),
            ("a b c", "https://k.example/l.m3u8"),
            ("戊", "https://m.example/%zz.m3u8"),
        ]))
        #expect(!got.contains { $0.1.contains("bad.example") || $0.1.contains("embed.st") })
    }

    // N10, N11: a reply that does not open is a detail with no lines, never a throw or a placeholder line.
    @Test func aBrokenSourceIsADetailWithoutLines() async throws {
        let line = [["name": "甲a", "url": wrapped("url=https%3A%2F%2Fa.example%2Fb.m3u8")]]
        // An unpadded payload still decodes: the spider pads it.
        Kanqiu88Site.serve(["/live/1/source": try sourceReply(line, padded: false)])
        let s = try await spider()
        #expect(same(try detail(try await s.detailContent(ids: ["1"])).lines, [("甲a", "https://a.example/b.m3u8")]))
        let broken: [Data] = [
            try JSONSerialization.data(withJSONObject: ["data": "abc"]),
            try JSONSerialization.data(withJSONObject: ["data": 12345678]),
            try JSONSerialization.data(withJSONObject: ["data": "abcdef" + Data("not json".utf8).base64EncodedString() + "zz"]),
            try JSONSerialization.data(withJSONObject: ["nothing": true]),
            try sourceReply(["no": "array"]),
            try sourceReply([["name": "x8", "url": "https://embed.st/embed/hotel/x/1"]]),
        ]
        for body in broken {
            Kanqiu88Site.serve(["/live/1/source": body])
            let got = try detail(try await s.detailContent(ids: ["1"]))
            #expect(got.vod["vod_id"] as? String == "1" && got.lines.isEmpty)
            #expect(got.vod["vod_play_from"] as? String == "" && got.vod["vod_play_url"] as? String == "")
            #expect(got.vod["vod_content"] as? String == "暂无可播放线路")
        }
        // A failed request, or an id that is not a match number, is no detail at all.
        Kanqiu88Site.serve(["/live/1/source": (404, Data())])
        #expect(try list(try await s.detailContent(ids: ["1"])).isEmpty)
        Kanqiu88Site.serve([:] as [String: Data])
        #expect(try list(try await s.detailContent(ids: ["https://www.88kanqiu.la"])).isEmpty)
        #expect(try list(try await s.detailContent(ids: ["1/../2"])).isEmpty && Kanqiu88Site.requests.isEmpty)
    }

    // N14: the unwrapped stream plays as is, never through the sniffer, with the site's UA.
    @Test func playIsTheStreamWithoutParsing() async throws {
        let s = try await spider()
        let play = try object(try await s.playerContent(flag: "88看球", id: lines129230[0].1, vipFlags: []))
        #expect(play["parse"] as? Int == 0 && play["url"] as? String == lines129230[0].1)
        #expect((play["header"] as? [String: String])?["User-Agent"] == agent)
        let page = try object(try await s.playerContent(flag: "88看球", id: "javascript:alert(1)", vipFlags: []))
        #expect(page["parse"] as? Int == 0 && page["url"] as? String == "")
    }

    // N9: the original has no search.
    @Test func searchFindsNothingWithoutAsking() async throws {
        Kanqiu88Site.serve([:] as [String: Data])
        #expect(try list(try await spider().searchContent(key: "NBA", quick: false, page: "1")).isEmpty)
        #expect(Kanqiu88Site.requests.isEmpty)
    }

    // N8: an http(s) ext replaces the mirror; anything else keeps the default.
    @Test func anExtThatIsAnAddressReplacesTheMirror() async throws {
        Kanqiu88Site.serve(["/": try homeLa()])
        _ = try await spider(extend: "https://www.88kanqiu.tw/").categoryContent(tid: "", page: "1", filter: false, extend: [:])
        _ = try await spider(extend: "./json/x.json").categoryContent(tid: "", page: "1", filter: false, extend: [:])
        #expect(Kanqiu88Site.requests.map(\.url.absoluteString) == ["https://www.88kanqiu.tw/", "https://www.88kanqiu.la/"])
    }
}

// home-la.html, sha256 1a261f6421321723733fb5c3fd115aff56b963bdac378b2b1f2ccf2f5b189d7f
private let homeLaPacked = """
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
2DfDegPN59v2Pw==
"""

// cat-tw-1.html, sha256 eb9aacacbcffb49d3533b7915e82489f9872f85225a0976d1a1e17ef18cb4185
private let categoryTw1Packed = """
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
Bw==
"""

// cat-la-4.html, sha256 74eab9f72181e81ea3dfc2ffc262c42c50e6ca9ebdd0b5ccc99e38b08e7896ac
private let categoryLa4Packed = """
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
RAC7JFXSq66mvtqTOEmpgJyj/2vifw==
"""

// source-la-129230.json, sha256 cba04afcbfdb7380f8f0c93e64ff38fc284bcffe7892d50b92283c8c4596caa7
private let source129230Packed = """
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
"""

// source-la-129494.json, sha256 4e94ab336491dac7ad21a9380a05a819aeff2c193afde5465077067b45c88a8f
private let source129494Packed = """
VZLbcpswFEXf+xn+gYibGzrTBxtsEEWiYK56A5EGgWS3MVd1+u+FJNNpHvZIc3TOnjNr6/euLvty92VHX1wuw6fFk6VzXkiKQZFHCl3gHlkTo2rTUJHGtXMG
dY7t0knb8uObRyy4hwze4RXfitzjscOHrQeKBtTuUQbscay1WvPbZ71UzwPNuOKLufHV+WctkhHF0MB2B3zteC/y7uHd90eZhSZkE6s2Pw2xgPef4TVdKuuj
N3Xm5umi64G7zXNOmQEq7TBWMVYCy7jVjnL/rq1ztnKr3WiiSyLDS7JEbJV43WEgLl/qHM6+wGN1+VfnqCtmbCcKllQixeRFljKUpRzLg4HjwihUIpDdKSiO
WBCvpxoCkmFB+OOM7OeJWkaPtET3YuwUeQrKs/lC8o4jEM5YdnNg0wVLqPvxoUcWkMjxBHbggm2oYee0FCJUiX3kgX1YkEA6EVAjDmkDa+UtjKbKEhYw/zq8
PNz6vRmhy/85mG9ZueC+5qtQMa293hsDeRvfeQ+B3UyVczZIDofaMSdfBbKOn4fSjfrKNrc5c70D6qJ179PGZBW5kWy+V4sxVurjVKnm6F+jkVof2AHcJtrK
QfPFqyfzLW8oMoXD9saMz78e9v7TmMRwq7/9v2QeC/XOgvZo5peJ1Q7vyWXNu4UTaosebZxinKD4tEftKvs0INlJFK8821B+kwc9aA8TvIKvebj78+kv
"""

// source-tw-sourceroute-129230.json, sha256 9e7c2e127fa58f107850af6abb105247db0541a4a7ecc76564df9167454d84b5
private let sourceTw129230Packed = """
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
"""
