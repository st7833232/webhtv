import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-19 (W-167): Libvio.js against the pages libvio.host served the W-162/W-165 gates on 2026-10-19
// (artifacts/spider-gate-batch3-2026-10-19.md §4, spider-gate-batch3/): the CDN's SHA-256 proof-of-work in front of
// every page, the old `stui` lists, the new `vod-*` detail page whose lines may all be net-disk, and the play page's
// `player_aaaa`. The five page fixtures are the gate's masked replies, embedded whole; the challenge page and every
// masked media address are synthetic.

/// Answers the libvio mirrors. With a challenge set it behaves as the gate saw the CDN: no `__cdn_verified` cookie is
/// a 403 `js-pow` page, a hand-written `__cdn_pow` cookie is a 302 that sets `__cdn_verified`, the right one is the page.
final class LibvioSite: URLProtocol, @unchecked Sendable {
    struct State {
        var pages: [String: Data] = [:]
        var challenge = Data()           // empty: no gate in front
        var verified = "v1"              // the __cdn_verified value the gate currently accepts
        var acceptPow = true             // false: the 302 sets no cookie
        var unreachable: Set<String> = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()
    nonisolated(unsafe) private static var seen: [(url: URL, headers: [String: String])] = []

    static func serve(_ served: State) { lock.withLock { state = served; seen = [] } }
    static func change(_ edit: (inout State) -> Void) { lock.withLock { edit(&state) } }
    static var requests: [(url: URL, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["libvio.host", "libviobd.com", "www.libvio.to", "libviofabu.com", "mirror.example"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!, headers = request.allHTTPHeaderFields ?? [:]
        let current = Self.lock.withLock { () -> State in Self.seen.append((url, headers)); return Self.state }
        if current.unreachable.contains(url.host ?? "") {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let cookies = (headers["Cookie"] ?? "").components(separatedBy: "; ")
        var status = 200, fields = ["Content-Type": "text/html; charset=utf-8"], body = Data()
        if !current.challenge.isEmpty && !cookies.contains("__cdn_verified=" + current.verified) {
            if cookies.contains(where: { $0.hasPrefix("__cdn_pow=") }) {
                fields["Location"] = url.path
                // URLSession joins the two Set-Cookie lines with ", " (gate N-2).
                if current.acceptPow {
                    fields["Set-Cookie"] = "__cdn_verified=\(current.verified); Path=/; Max-Age=1800; HttpOnly; SameSite=Lax; Secure, "
                        + "__cdn_pow=; Path=/; Max-Age=0"
                }
                // A real redirect, so a spider that follows it comes back here; one that does not is handed the 302.
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: fields)!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            status = 403
            fields["x-cdn-challenge"] = "js-pow"
            fields["x-cdn-challenge-mode"] = "auto"
            body = current.challenge
        } else if let page = current.pages[url.path] {
            body = page
        } else {
            status = 404
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct FixtureMismatch: Error {}

/// A gate reply, raw-deflated and base64-encoded, checked against the SHA-256 the gate recorded (SHA256SUMS).
private func fixture(_ packed: String, sha256: String) throws -> String {
    guard let deflated = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (deflated as NSData).decompressed(using: .zlib) as Data
    guard hex(SHA256.hash(data: data)) == sha256 else { throw FixtureMismatch() }
    return String(decoding: data, as: UTF8.self)
}

private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }

private func homePage() throws -> String { try fixture(homePacked, sha256: "3797948f23eff07cc5de5eaf00f4b95db06a70e84a75c051f0562137197b1ad6") }
private func categoryPage() throws -> String { try fixture(categoryPacked, sha256: "f7b449bb9ab99cf5b17657be941df5a0c006cf8d790963131342372788fc5124") }
private func detailPage() throws -> String { try fixture(detailPacked, sha256: "665bfb963292c1de214eea63ae48ae4e66d06add8b8d12c5568019aa36dc40d2") }
/// /w/714893735-1-1.html: a title whose two lines are both net-disk (夸克, 迅雷); `from` is `kuake`.
private func netDiskPlayPage(url: String = "https://pan.quark.cn/s/4215abcd") throws -> String {
    try fixture(playPacked, sha256: "20658a7149dcb15d30d909182b8ff71b3151489c357d5f47439a5270287cd2df")
        .replacingOccurrences(of: "\"url\":\"http…\"", with: "\"url\":\"\(url)\"")
}
/// /w/714893756-1-1.html: line 1 is the online 「BD5播放」 (`from` vr2, `encrypt` 3); the masked url is replaced.
private func onlinePlayPage(url: String = media, encrypt: Int = 3, from: String = "vr2") throws -> String {
    let page = try fixture(play2Packed, sha256: "a5ce1fb03d02ab993c965dbed9a7f004a3a7fdeb972f72ca577b08a09c41d99a")
    #expect(page.contains("\"encrypt\":3,") && page.contains("\"url\":\"http…\"") && page.contains("\"from\":\"vr2\""))
    return page.replacingOccurrences(of: "\"encrypt\":3,", with: "\"encrypt\":\(encrypt),")
        .replacingOccurrences(of: "\"url\":\"http…\"", with: "\"url\":\"\(url)\"")
        .replacingOccurrences(of: "\"from\":\"vr2\"", with: "\"from\":\"\(from)\"")
}

private let media = "https://v.example.com/2026/a/S01E01.mp4"
private let ua = "Mozilla/5.0 (Linux; Android 11; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"
private let sig = "3f9a1c0d5e7b2468ace013579bdf2468"

/// The CDN's challenge, shaped as the gate's 403 (w165-libvio-cat-challenge.body:156–160) with synthetic values.
private func challenge(ts: String = "1792397975", sig: String = sig, diff: String = "00", expect: Int = 256) -> Data {
    Data("""
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>安全验证</title></head><body>
    <div id="status">正在进行安全验证…</div>
    <script>
    (function () {
      var TS = "\(ts)", SIG = "\(sig)", DIFF = "\(diff)", MODE = "auto";
      var POW = "__cdn_pow";
      var EXPECT = \(expect);        // PoW 期望尝试次数（服务端按难度推导）
      var MAX_ITER = EXPECT * 32;     // 尝试上限：远高于期望，避免正常设备被误判
      if (MODE === "checkbox") buildCheckbox();
      function finish(nonce) { document.cookie = POW + "=" + TS + "_" + MODE + "_" + nonce + "_" + SIG + "; path=/"; }
    })();
    </script></body></html>
    """.utf8)
}

/// The first i whose sha256(sig + i) in hex starts with diff, as the challenge page's own solver finds it.
private func nonce(_ sig: String, _ diff: String, below limit: Int = 1_000_000) -> Int? {
    (0..<limit).first { hex(SHA256.hash(data: Data((sig + String($0)).utf8))).hasPrefix(diff) }
}

private func libvio(_ state: LibvioSite.State = .init(), ext: String = "") async throws -> JavaScriptSpiderRuntime {
    LibvioSite.serve(state)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LibvioSite.self]
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let runtime = try JavaScriptSpiderRuntime(
        name: "Libvio", script: try #require(registry.entry(for: "csp_Libvio")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "Libvio-test", defaults: UserDefaults(suiteName: "Libvio-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: ext)
    return runtime
}

private func pages(_ served: [String: String]) -> [String: Data] { served.mapValues { Data($0.utf8) } }

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

private func paths() -> [String] { LibvioSite.requests.map { $0.url.host! + $0.url.path } }

@Suite(.serialized) struct LibvioSpiderTests {
    // Gate W-165 握手 1–2 and 分類 1, N-2: the 403 page is solved, the answer goes once as a hand-written cookie without
    // following the 302, and the original address is asked again with no hand-written cookie so the jar's
    // __cdn_verified goes instead.
    @Test func theProofOfWorkIsSolvedOnceAndTheJarCarriesTheVerifiedCookie() async throws {
        let solved = try #require(nonce(sig, "00"))
        #expect(solved > 0)
        let runtime = try await libvio(.init(pages: pages(["/show/1--------1---.html": try categoryPage()]), challenge: challenge()))
        #expect(LibvioSite.requests.isEmpty)
        let page = try object(try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        #expect((page["list"] as? [Any])?.count == 12 && page["pagecount"] as? Int == 265)
        let sent = LibvioSite.requests
        #expect(sent.map(\.url.absoluteString) == Array(repeating: "https://libvio.host/show/1--------1---.html", count: 3))
        #expect(sent.map { $0.headers["Cookie"] ?? "-" } ==
                ["-", "__cdn_pow=1792397975_auto_\(solved)_\(sig)", "__cdn_verified=v1"])
        for request in sent {
            #expect(request.headers["User-Agent"] == ua)
            #expect(request.headers["Accept"] == "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
            #expect(request.headers["Accept-Language"] == "zh-CN,zh;q=0.9,en;q=0.8")
        }
        // Inside the half hour the jar alone is enough.
        _ = try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        #expect(LibvioSite.requests.count == 4 && LibvioSite.requests.last?.headers["Cookie"] == "__cdn_verified=v1")

        // The jar ignores Max-Age, so an expired cookie is still sent: the next 403 is solved again, not taken as the page.
        LibvioSite.change { $0.verified = "v2" }
        let again = try object(try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        #expect((again["list"] as? [Any])?.count == 12)
        #expect(LibvioSite.requests.dropFirst(4).map { $0.headers["Cookie"] ?? "-" } ==
                ["__cdn_verified=v1", "__cdn_pow=1792397975_auto_\(solved)_\(sig)", "__cdn_verified=v2"])
    }

    // The search stops at EXPECT * 32 tries: DIFF 0 is first met at try 14, inside 32 for EXPECT 1.
    @Test func theSearchMayRunToThirtyTwoTimesTheExpectedTries() async throws {
        let solved = try #require(nonce(sig, "0"))
        #expect(solved > 1 && solved < 32)
        let runtime = try await libvio(.init(pages: pages(["/show/1--------1---.html": try categoryPage()]),
                                             challenge: challenge(diff: "0", expect: 1)))
        #expect(try list(try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:])).count == 12)
        #expect(LibvioSite.requests[1].headers["Cookie"] == "__cdn_pow=1792397975_auto_\(solved)_\(sig)")
    }

    // A challenge the spider cannot or should not answer costs one request: no cookie is sent, and the 403 is the reason
    // the listing shows.
    @Test func aChallengeThatCannotBeSolvedSendsNoCookie() async throws {
        #expect(nonce(sig, "ffffff", below: 32) == nil)
        for page in [challenge(sig: ""), challenge(diff: "zz"), challenge(diff: ""), challenge(diff: String(repeating: "0", count: 65)),
                     challenge(ts: "1792;Path=/"), challenge(diff: "ffffff", expect: 1)] {
            let runtime = try await libvio(.init(pages: pages(["/show/1--------1---.html": try categoryPage()]), challenge: page))
            await #expect(throws: SiteUnreachable.self) {
                _ = try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
            }
            #expect(LibvioSite.requests.count == 1 && LibvioSite.requests[0].headers["Cookie"] == nil)
        }
    }

    // A 302 that sets no cookie leaves the page challenged: the spider gives up after one answer instead of looping.
    @Test func aChallengeThatOutlivesTheAnswerFailsAfterOneTry() async throws {
        let runtime = try await libvio(.init(pages: pages(["/show/1--------1---.html": try categoryPage()]), challenge: challenge(),
                                             acceptPow: false))
        await #expect(throws: SiteUnreachable.self) {
            _ = try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        }
        #expect(LibvioSite.requests.count == 3)
        #expect(try list(try await runtime.searchContent(key: "蜘蛛", quick: false, page: "1")).isEmpty)
        #expect(LibvioSite.requests.count == 6)
    }

    // W-162 #6: the home page's five /type/<n>.html classes and its 48 titles (60 thumbnails, some titles twice).
    @Test func homeReadsTheFiveTypeClassesAndTheTitles() async throws {
        let runtime = try await libvio(.init(pages: pages(["/": try homePage()])))
        let home = try object(try await runtime.homeContent(filter: false))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } ==
                ["1电影", "2剧集", "4番剧", "15日韩", "16欧美"])
        let titles = try #require(home["list"] as? [[String: Any]])
        #expect(titles.count == 48 && Set(titles.map { $0["vod_id"] as? String }).count == 48)
        let first = try #require(titles.first)
        #expect(first["vod_id"] as? String == "714893756" && first["vod_name"] as? String == "七龙珠超：比鲁斯")
        #expect(first["vod_pic"] as? String == "https://img.meituan.net/content/41502ee484899fda36f9362983dd43eb215434.png")
        #expect(first["vod_remarks"] as? String == "第02集/周日更")
        #expect(paths() == ["libvio.host/"])
        #expect(LibvioSite.requests[0].headers["Cookie"] == nil)
    }

    // W-165 分類 1: show/<tid>--------<pg>---.html, the page count from 「1/265」.
    @Test func aCategoryAsksTheShowRouteAndReadsThePageCount() async throws {
        let runtime = try await libvio(.init(pages: pages(["/show/1--------2---.html": try categoryPage(),
                                                           "/show/1--------1---.html": try categoryPage()])))
        let page = try object(try await runtime.categoryContent(tid: "1", page: "2", filter: false, extend: [:]))
        let titles = try #require(page["list"] as? [[String: Any]])
        #expect(titles.count == 12 && page["page"] as? Int == 2 && page["pagecount"] as? Int == 265)
        #expect(titles.first?["vod_id"] as? String == "714893735" && titles.first?["vod_name"] as? String == "蜘蛛侠：崭新之日")
        #expect(titles.first?["vod_pic"] as? String == "https://img.meituan.net/content/18357781879ac4e95cfd9b6b0e0687b0183504.png")
        #expect(paths() == ["libvio.host/show/1--------2---.html"])
        // A page that is not a number is page 1; a class that is not a number never reaches the site.
        _ = try await runtime.categoryContent(tid: "1", page: "abc", filter: false, extend: [:])
        #expect(paths().last == "libvio.host/show/1--------1---.html")
        for tid in ["1/../x", "type/1", "", "1?x=1"] {
            #expect(try list(try await runtime.categoryContent(tid: tid, page: "1", filter: false, extend: [:])).isEmpty)
        }
        #expect(LibvioSite.requests.count == 2)
    }

    // W-165 詳情 2, 播放頁 3 (N-1): the vod-* selectors; both panels are netdisk-panel, the first play page's tabs are both
    // net-disk too, so the title lists no line.
    @Test func aNetDiskOnlyTitleKeepsItsDetailsAndListsNoLine() async throws {
        let runtime = try await libvio(.init(pages: pages(["/detail/714893735.html": try detailPage(),
                                                           "/w/714893735-1-1.html": try netDiskPlayPage()])))
        let vod = try #require(try list(try await runtime.detailContent(ids: ["714893735"])).first)
        #expect(vod["vod_id"] as? String == "714893735" && vod["vod_name"] as? String == "蜘蛛侠：崭新之日")
        #expect(vod["vod_pic"] as? String == "https://img.meituan.net/content/18357781879ac4e95cfd9b6b0e0687b0183504.png")
        #expect(vod["type_name"] as? String == "动作,科幻,冒险" && vod["vod_area"] as? String == "美国,加拿大,英国,德国")
        #expect(vod["vod_year"] as? String == "2026" && vod["vod_director"] as? String == "德斯汀·丹尼尔·克雷顿")
        #expect((vod["vod_actor"] as? String)?.hasPrefix("汤姆·霍兰德,赞达亚") == true)
        #expect(vod["vod_remarks"] as? String == "7.7")
        let content = try #require(vod["vod_content"] as? String)
        #expect(content.hasPrefix("彼得·帕克（汤姆·霍兰德饰）") && content.hasSuffix("完成破茧重生？"))
        // W-171 (W-167 review N-3): one line that says so, whose episode gives no address without asking the site,
        // so 立即播放 answers 「這一集沒有可播放的網址。」 instead of staying greyed out with no reason.
        #expect(vod["vod_play_from"] as? String == "網盤線路（App 不支援）")
        #expect(vod["vod_play_url"] as? String == "只有網盤資源$netdisk:none")
        let play = try object(try await runtime.playerContent(flag: "網盤線路（App 不支援）", id: "netdisk:none", vipFlags: []))
        #expect(play["url"] as? String == "")
        #expect(paths() == ["libvio.host/detail/714893735.html", "libvio.host/w/714893735-1-1.html"])
        // An id that is not a number never reaches the site.
        for id in ["714893735/../x", "", "1?x=1"] {
            #expect(try list(try await runtime.detailContent(ids: [id])).isEmpty)
        }
        #expect(LibvioSite.requests.count == 2)
    }

    // W-171 (W-167 review N-4): a net-disk line is one named for a net-disk — the brand alone, or 视频下载（brand）, or
    // any 网盘／云盘 — not every name that happens to contain 115 or 移动.
    @Test func netDiskNamesAreWholeNamesNotSubstrings() async throws {
        let online = ["115线路", "移动高清", "BD5播放"], disk = ["视频下载 (夸克)", "视频下载(迅雷)", "UC", "115", "123原画",
                                                                       "百度网盘", "阿里云盘", "夸克", "（天翼）"]
        let panels = (online + disk).enumerated().map { index, name in
            "<div class=\"playlist-panel\"><h3>\(name)</h3><ul><li><a href=\"/w/714893735-\(index + 1)-1.html\">正片</a></li></ul></div>"
        }.joined()
        let detail = try detailPage()
        let anchor = try #require(detail.range(of: "<div class=\"playlist-panel netdisk-panel\">"))
        let runtime = try await libvio(.init(pages: pages(["/detail/714893735.html": detail.replacingCharacters(in: anchor.lowerBound..<anchor.lowerBound, with: panels)])))
        let vod = try #require(try list(try await runtime.detailContent(ids: ["714893735"])).first)
        #expect(vod["vod_play_from"] as? String == online.joined(separator: "$$$"))
    }

    // Upstream's online lines: a playlist-panel that is not netdisk-panel, named by its h3, episodes /w/ or /play/ in page
    // order. A panel named after a net-disk is skipped even without the class. Synthetic: the gate saw none (N-1).
    @Test func anOnlinePanelOnTheDetailPageIsListedWithoutThePlayPage() async throws {
        let panels = """
            <div class="playlist-panel"><div class="panel-head"><h3>BD5播放</h3></div><ul class="stui-play__list">
              <li><a href="/w/714893735-1-1.html">第01集</a></li><li><a href="/play/714893735-1-2.html">第$02#集</a></li>
              <li><a href="javascript:;">报错</a></li><li><a href="/w/714893735-1-3.html">第03集</a></li></ul></div>
            <div class="playlist-panel"><h3>夸克网盘</h3><ul><li><a href="/w/714893735-3-1.html">合集</a></li></ul></div>
            <div class="playlist-panel netdisk-panel"><h3>资源下载</h3><ul><li><a href="/w/714893735-2-1.html">合集</a></li></ul></div>
            <div class="playlist-panel"><h3>HD备用</h3><ul><li><a href="/w/714893735-4-1.html">正片</a></li></ul></div>

        """
        let detail = try detailPage()
        let anchor = try #require(detail.range(of: "<div class=\"playlist-panel netdisk-panel\">"))
        let runtime = try await libvio(.init(pages: pages(["/detail/714893735.html": detail.replacingCharacters(in: anchor.lowerBound..<anchor.lowerBound, with: panels)])))
        let vod = try #require(try list(try await runtime.detailContent(ids: ["714893735"])).first)
        #expect(vod["vod_play_from"] as? String == "BD5播放$$$HD备用")
        #expect(vod["vod_play_url"] as? String == "第01集$714893735-1-1#第 02 集$714893735-1-2#第03集$714893735-1-3$$$正片$714893735-4-1")
        #expect(paths() == ["libvio.host/detail/714893735.html"])
    }

    // W-165 N3: with no online panel on the detail page, the first play page's play-tab names and stui-play__list
    // episodes give the lines, paired in order and still without the net-disk ones (播放頁 4's layout).
    @Test func withoutAnOnlinePanelTheFirstPlayPageGivesTheLines() async throws {
        var runtime = try await libvio(.init(pages: pages(["/detail/714893735.html": try detailPage(),
                                                           "/w/714893735-1-1.html": try onlinePlayPage()])))
        var vod = try #require(try list(try await runtime.detailContent(ids: ["714893735"])).first)
        #expect(vod["vod_play_from"] as? String == "BD5播放")
        #expect(vod["vod_play_url"] as? String == "第01集$714893756-1-1#第02集$714893756-1-2")
        #expect(paths() == ["libvio.host/detail/714893735.html", "libvio.host/w/714893735-1-1.html"])

        // A second online tab after a net-disk one keeps its own episodes.
        let renamed = try onlinePlayPage().replacingOccurrences(of: "<a href=\"javascript:;\">视频下载(迅雷)</a>",
                                                                with: "<a href=\"javascript:;\">HD备用</a>")
        runtime = try await libvio(.init(pages: pages(["/detail/714893735.html": try detailPage(), "/w/714893735-1-1.html": renamed])))
        vod = try #require(try list(try await runtime.detailContent(ids: ["714893735"])).first)
        #expect(vod["vod_play_from"] as? String == "BD5播放$$$HD备用")
        #expect(vod["vod_play_url"] as? String == "第01集$714893756-1-1#第02集$714893756-1-2$$$合集$714893756-3-1")
    }

    // W-165 播放頁 4: `encrypt` 3 is a plain https .mp4, which upstream left to its default branch; 2 is base64 of the
    // URL-encoded address and 1 the URL-encoded address. The player gets the play page as Referer and the site's UA.
    @Test func playReadsPlayerAaaaAndHandsTheAddressWithItsReferer() async throws {
        let encoded = "https%3A%2F%2Fv.example.com%2F2026%2Fa%2FS01E01.mp4"
        for page in [try onlinePlayPage(), try onlinePlayPage(url: Data(encoded.utf8).base64EncodedString(), encrypt: 2),
                     try onlinePlayPage(url: encoded, encrypt: 1)] {
            let runtime = try await libvio(.init(pages: pages(["/w/714893756-1-1.html": page])))
            let play = try object(try await runtime.playerContent(flag: "BD5播放", id: "714893756-1-1", vipFlags: []))
            #expect(play["url"] as? String == media && play["parse"] as? Int == 0)
            #expect(play["header"] as? [String: String] == ["Referer": "https://libvio.host/w/714893756-1-1.html", "User-Agent": ua])
            #expect(paths() == ["libvio.host/w/714893756-1-1.html"])
        }
    }

    // Net-disk lines are never played: by line name (no request), by `from`, or by the address's host. An address that is
    // not plain http(s), or would split the play list, gives nothing either; a bad id never reaches the site.
    @Test func netDiskLinesAndBadAddressesGiveNoAddress() async throws {
        let cases: [(String, String)] = [
            ("视频下载 (夸克)", try onlinePlayPage()),
            ("BD5播放", try netDiskPlayPage()),
            ("BD5播放", try netDiskPlayPage(url: media)),
            ("BD5播放", try onlinePlayPage(url: "https://pan.xunlei.com/s/VP3Babcd")),
            ("BD5播放", try onlinePlayPage(url: "javascript:alert(1)")),
            ("BD5播放", try onlinePlayPage(url: "https://v.example.com/a$b.mp4")),
            ("BD5播放", try onlinePlayPage(url: "", encrypt: 2)),
            ("BD5播放", "<html>no player</html>"),
        ]
        for (flag, page) in cases {
            let runtime = try await libvio(.init(pages: pages(["/w/714893756-1-1.html": page])))
            let play = try object(try await runtime.playerContent(flag: flag, id: "714893756-1-1", vipFlags: []))
            #expect(play["url"] as? String == "", "\(flag)")
            #expect(LibvioSite.requests.count == (flag == "BD5播放" ? 1 : 0))
        }
        let runtime = try await libvio(.init(pages: pages(["/w/714893756-1-1.html": try onlinePlayPage()])))
        for id in ["../714893756-1-1", "714893756/1", "", "714893756-1-1.html?x=1", "a b"] {
            #expect(try object(try await runtime.playerContent(flag: "BD5播放", id: id, vipFlags: []))["url"] as? String == "", "\(id)")
        }
        #expect(LibvioSite.requests.isEmpty)
    }

    // Upstream's search route, one page, the same list parser: poster from data-original, then data-src, then src; the
    // name from title, else the link text; a title listed twice once.
    @Test func searchEncodesTheKeywordAndReadsTheSameList() async throws {
        let results = """
            <ul class="stui-vodlist clearfix">
              <li><a class="stui-vodlist__thumb lazyload" href="/detail/11.html" title="甲" data-original="https://img.example/11.jpg" data-src="https://img.example/11s.jpg"><span class="pic-text">HD</span></a></li>
              <li><a class="stui-vodlist__thumb" href="/detail/12.html" data-src="https://img.example/12.jpg" src="https://img.example/12s.jpg">乙</a></li>
              <li><a class="stui-vodlist__thumb" href="/detail/13.html" title="丙" src="https://img.example/13.jpg"></a></li>
              <li><a class="stui-vodlist__thumb" href="/detail/11.html" title="甲" data-original="https://img.example/dup.jpg"></a></li>
              <li><a class="stui-vodlist__thumb" href="/vod/14.html" title="丁"></a></li>
            </ul>
        """
        let runtime = try await libvio(.init(pages: pages(["/search/-------------.html": results])))
        let found = try list(try await runtime.searchContent(key: " 蜘蛛 &x ", quick: false, page: "1"))
        #expect(found.map { ($0["vod_id"] as? String ?? "") + ($0["vod_name"] as? String ?? "") + ($0["vod_pic"] as? String ?? "") } ==
                ["11甲https://img.example/11.jpg", "12乙https://img.example/12.jpg", "13丙https://img.example/13.jpg"])
        #expect(found.first?["vod_remarks"] as? String == "HD")
        let request = try #require(LibvioSite.requests.first)
        #expect(request.url.absoluteString == "https://libvio.host/search/-------------.html?wd=%E8%9C%98%E8%9B%9B%20%26x")
        #expect(try list(try await runtime.searchContent(key: "蜘蛛", quick: false, page: "2")).isEmpty)
        #expect(try list(try await runtime.searchContent(key: "  ", quick: false, page: "1")).isEmpty)
        #expect(LibvioSite.requests.count == 1)
    }

    // Mirrors: ext `site` entries that are http(s) bases come first, release pages (fabu, libvio.app, github.io) are not
    // asked, then the fixed libvio.host → libviobd.com → www.libvio.to. An unreachable mirror passes to the next, which
    // the session keeps. init asks nothing.
    @Test func anUnreachableMirrorPassesToTheNextAndInitAsksNothing() async throws {
        let ext = #"{"site":["https://libviofabu.com","https://libvio.app","https://mirror.example/","ftp://x.example"],"decrypt":"0"}"#
        let runtime = try await libvio(.init(pages: pages(["/": try homePage(), "/show/1--------1---.html": try categoryPage()]),
                                             unreachable: ["mirror.example", "libvio.host"]), ext: ext)
        #expect(LibvioSite.requests.isEmpty)
        #expect(try list(try await runtime.homeContent(filter: false)).count == 48)
        #expect(paths() == ["mirror.example/", "libvio.host/", "libviobd.com/"])
        _ = try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        #expect(paths().last == "libviobd.com/show/1--------1---.html" && LibvioSite.requests.count == 4)
        // A plain address as ext is a base too.
        let plain = try await libvio(.init(pages: pages(["/": try homePage()])), ext: "https://www.libvio.to/")
        _ = try await plain.homeContent(filter: false)
        #expect(paths() == ["www.libvio.to/"])
    }
}

// libvio-host-home-verified.body, sha256 3797948f23eff07cc5de5eaf00f4b95db06a70e84a75c051f0562137197b1ad6
private let homePacked = """
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
ZflWcf3z8s2zYe/Yz1TLDKVQp5R+0ml64v8A
"""

// w165-libvio-cat.body, sha256 f7b449bb9ab99cf5b17657be941df5a0c006cf8d790963131342372788fc5124
private let categoryPacked = """
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
"""

// w165-libvio-detail.body, sha256 665bfb963292c1de214eea63ae48ae4e66d06add8b8d12c5568019aa36dc40d2
private let detailPacked = """
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
0AkLJONmTv1u5Mj/Aw==
"""

// w165-libvio-play.body, sha256 20658a7149dcb15d30d909182b8ff71b3151489c357d5f47439a5270287cd2df
private let playPacked = """
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
UYLsMG351gXj6xbolwj1/i8=
"""

// w165-libvio-play2.body, sha256 a5ce1fb03d02ab993c965dbed9a7f004a3a7fdeb972f72ca577b08a09c41d99a
private let play2Packed = """
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
"""
