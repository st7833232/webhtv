import CommonCrypto
import Foundation
import Testing
@testable import WebHTVCore

// W-266: spider.jar's first batch (Yidong4K, AnimeHuazi, XingChen, AnimeGiri, AppFox, AnimeBashi, SaoHuo) against
// hand-made replies cut down from what each site returned on 2026-11-09 (docs/W-266-spider-jar-port-7.md §3). Each
// test pins one upstream behaviour or one deliberate difference.

/// Answers every host the seven spiders call through one handler, and remembers each request with its body.
final class W266Site: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let body: String; let headers: [String: String] }
    typealias Handler = @Sendable (URL, String) -> (Int, String)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _, _ in nil }
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ handler: @escaping Handler) { lock.withLock { self.handler = handler; seen = [] } }
    static var requests: [Seen] { lock.withLock { seen } }
    static func forget() { lock.withLock { seen = [] } }

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

private func spider(_ name: String, ext: String = "") async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [W266Site.self]
    let runtime = try JavaScriptSpiderRuntime(
        name: name, script: try #require(registry.entry(for: "csp_" + name)?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "W266-" + name, defaults: UserDefaults(suiteName: "W266-" + name)!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: ext)
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func detail(_ text: String) throws -> [String: Any] { try #require(try list(text).first) }
private func ids(_ text: String) throws -> [String] { try list(text).map { $0["vod_id"] as? String ?? "" } }
private func path(_ url: URL) -> String {
    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path) + (url.query.map { "?" + $0 } ?? "")
}
private var paths: [String] { W266Site.requests.map { path($0.url) } }

/// The 139 share API's dialect: base64(iv ‖ AES-128-CBC-PKCS7(plain)) under the fixed key.
private let shareKey = Data("PVGDwmcvfs1uV3d1".utf8)
private func cbc(_ operation: Int, _ input: Data, iv: Data) -> Data {
    var out = Data(count: input.count + kCCBlockSizeAES128), moved = 0
    let outCount = out.count
    let status = out.withUnsafeMutableBytes { o in input.withUnsafeBytes { i in iv.withUnsafeBytes { v in shareKey.withUnsafeBytes { k in
        CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, k.count,
                v.baseAddress, i.baseAddress, i.count, o.baseAddress, outCount, &moved)
    } } } }
    return status == kCCSuccess ? out.prefix(moved) : Data()
}
private func shareSeal(_ json: String) -> String {
    let iv = Data((0..<16).map { UInt8($0) })
    return (iv + cbc(kCCEncrypt, Data(json.utf8), iv: iv)).base64EncodedString()
}
private func shareOpen(_ base64: String) -> [String: Any] {
    guard let data = Data(base64Encoded: base64), data.count > 16 else { return [:] }
    let plain = cbc(kCCDecrypt, data.dropFirst(16), iv: data.prefix(16))
    return (try? JSONSerialization.jsonObject(with: plain) as? [String: Any]) ?? [:]
}

@Suite(.serialized) struct W266PortSpiderTests {
    @Test func registryDrivesAllSeven() {
        let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
        for name in ["Yidong4K", "AnimeHuazi", "XingChen", "AnimeGiri", "AppFox", "AnimeBashi", "SaoHuo"] {
            #expect(registry.canDrive("csp_" + name), "\(name)")
            #expect(SpiderRegistry.ported.contains(name), "\(name)")
        }
    }

    // MARK: AnimeHuazi

    @Test func huaziListsPagesDetailAndResolvesPlay() async throws {
        W266Site.serve { url, body in
            switch path(url) {
            case "/api/videos?page=2&pageSize=24&typeId=1&sort=time":
                return (200, #"{"list":[{"vodId":8615,"vodName":"轻松熊","vodPic":"https://img/p.jpg","vodRemarks":"31"},{"vodId":null}],"total":3837,"pageSize":24}"#)
            case "/api/videos/8615":
                return (200, #"{"data":{"vodId":8615,"vodName":"轻松熊","vodClass":"TV,日本","vodYear":"2026","vodDirector":"板津匡览","playSources":[{"sourceCode":"D-hz","sourceName":"花子-D线","episodes":[{"name":"第01集","url":"hz1.abc"},{"name":"第$02#集","url":"hz1.def"},{"name":"空","url":""}]},{"sourceCode":"E","sourceName":"空线","episodes":[]}]}}"#)
            case "/api/play/resolve":
                return body == #"{"url":"hz1.abc","sourceCode":"D-hz"}"# ? (200, #"{"ok":true,"playUrl":"https://cdn/x/"}"#) : (200, "{}")
            default: return nil
            }
        }
        let runtime = try await spider("AnimeHuazi")
        let page = try object(try await runtime.categoryContent(tid: "1", page: "2", filter: false, extend: [:]))
        #expect(try ids(try await runtime.categoryContent(tid: "1", page: "2", filter: false, extend: [:])) == ["8615"])
        #expect(page["pagecount"] as? Int == 160 && page["total"] as? Int == 3837 && page["limit"] as? Int == 24)
        let vod = try detail(try await runtime.detailContent(ids: ["8615"]))
        #expect(vod["vod_play_from"] as? String == "花子-D线")
        #expect(vod["vod_play_url"] as? String == "第01集$D-hz|hz1.abc#第 02 集$D-hz|hz1.def")
        #expect(vod["vod_director"] as? String == "板津匡览" && vod["type_name"] as? String == "TV,日本")
        let play = try object(try await runtime.playerContent(flag: "花子-D线", id: "D-hz|hz1.abc", vipFlags: []))
        #expect(play["url"] as? String == "https://cdn/x/" && play["parse"] as? Int == 0)
        #expect(try object(try await runtime.playerContent(flag: "", id: "no-bar", vipFlags: []))["url"] as? String == "")
    }

    // The site asks for a captcha (4001); that is an empty result, never solved. The keyword goes URL-encoded.
    @Test func huaziSearchStopsAtTheCaptcha() async throws {
        W266Site.serve { url, _ in path(url).hasPrefix("/api/search") ? (200, #"{"code":4001,"message":"需要验证码"}"#) : nil }
        let runtime = try await spider("AnimeHuazi")
        #expect(try list(try await runtime.searchContent(key: "海 贼", quick: false, page: "1")).isEmpty)
        #expect(paths == ["/api/search?q=%E6%B5%B7%20%E8%B4%BC&page=1&pageSize=24"])
    }

    // MARK: AnimeGiri

    @Test func giriPagesByOffsetAndFixesDetailPosters() async throws {
        W266Site.serve { url, _ in
            switch path(url) {
            case "/api.php/Vod/get_list?type_id=2&offset=20&limit=20":
                return (200, #"{"code":1,"info":{"offset":20,"limit":20,"total":3149,"rows":[{"vod_id":27202,"vod_name":"魔法★探险家","vod_pic":"https://jpg.girigirilove.com/upload/a.webp","vod_remarks":"更新至07集"}]}}"#)
            case "/api.php/Vod/get_detail?vod_id=27202":
                return (200, #"{"code":1,"info":{"vod_id":27202,"vod_name":"魔法★探险家","vod_pic":"upload/vod/a.webp","vod_play_from":"chs$$$cht","vod_play_url":"01$https://akua/01/playlist.m3u8$$$01$https://akua/c01/playlist.m3u8"}}"#)
            case "/api.php/Vod/get_list?offset=0&limit=24&vod_name=%E6%B5%B7":
                return (200, #"{"code":1,"info":{"rows":[{"vod_id":26661,"vod_name":"怪兽8号"}]}}"#)
            default: return (200, #"{"code":0}"#)
            }
        }
        let runtime = try await spider("AnimeGiri")
        let page = try object(try await runtime.categoryContent(tid: "2", page: "2", filter: false, extend: [:]))
        #expect(page["pagecount"] as? Int == 158)
        let vod = try detail(try await runtime.detailContent(ids: ["27202"]))
        #expect(vod["vod_pic"] as? String == "https://jpg.girigirilove.com/upload/vod/a.webp")
        #expect(vod["vod_play_from"] as? String == "chs$$$cht")
        #expect(try ids(try await runtime.searchContent(key: "海", quick: false, page: "1")) == ["26661"])
        #expect(try list(try await runtime.detailContent(ids: ["404"])).isEmpty)
        let play = try object(try await runtime.playerContent(flag: "chs", id: "https://akua/01/playlist.m3u8", vipFlags: []))
        #expect(play["url"] as? String == "https://akua/01/playlist.m3u8")
        #expect(try object(try await runtime.playerContent(flag: "chs", id: "javascript:x", vipFlags: []))["url"] as? String == "")
    }

    // MARK: XingChen

    @Test func xingChenReadsCarouselCardsDetailAndPlayerJSON() async throws {
        let home = """
        <div class="slide-time-list mySwiper"><div class="slide-time-bj swiper-slide"><a href="/d-174346.html">\
        <div class="slide-time-img3 mask-1" style="background-image: url('https://p/bg.jpg');"></div>\
        <h3 class="slide-info-title hide">打歌2026</h3><div class="slide-info hide"><span class="slide-info-remarks">2026</span>\
        <span class="slide-info-remarks">更新至第20261108期</span></div></a></div></div>
        """
        let cards = """
        <div class="public-list-box public-pic-b"><a class="public-list-exp" href="/d-179702.html" title="打造《绝代艳后》">\
        <img class="lazy gen-movie-img" data-src="/upload/a.jpg" /><span class="public-list-prb hide ft2">HD中字</span></a></div>
        """
        let page = """
        <h3 class="slide-info-title hide">骨髓</h3><div class="detail-pic"><img data-src="https://c/p.jpg" /></div>\
        <span class="slide-info-remarks">更新至高清</span><span class="slide-info-remarks">&nbsp;2026</span>\
        <span class="slide-info-remarks">&nbsp;美国</span>\
        <div class="slide-info"><strong>导演 :</strong><a>Mitch</a></div><div class="slide-info"><strong>演员 :</strong><a>甲</a><a>乙</a></div>\
        <div class="slide-info"><strong>备注 :</strong><a>不收</a></div><div class="slide-info"><strong>类型 :</strong><a>恐怖片</a></div>\
        <div id="height_limit">简介&nbsp;文字</div>\
        <div class="anthology-tab"><a>&nbsp;土星3</a><a>月亮1</a></div>\
        <ul class="anthology-list-play"><li><a class="this-link" href="/p/179624-1-1.html">高清</a></li><li><a class="this-link" href="/p/179624-1-2.html">花絮</a></li></ul>\
        <ul class="anthology-list-play"><li><a class="this-link" href="/p/179624-2-1.html">正片</a></li></ul>
        """
        W266Site.serve { url, _ in
            switch path(url) {
            case "/": return (200, home)
            case "/vs/1--------2---.html", "/s%E6%B5%B7.html": return (200, cards)
            case "/d-179624.html": return (200, page)
            case "/p/179624-1-1.html": return (200, #"<script>var player_aaaa={"url":"https:\/\/v.cdn\/a\/index.m3u8","from":"tx"}</script>"#)
            case "/p/179624-2-1.html": return (444, "")
            default: return nil
            }
        }
        let runtime = try await spider("XingChen")
        let slide = try #require(try list(try await runtime.homeVideoContent()).first)
        #expect(slide["vod_id"] as? String == "174346" && slide["vod_pic"] as? String == "https://p/bg.jpg")
        #expect(slide["vod_remarks"] as? String == "更新至第20261108期")
        let card = try #require(try list(try await runtime.categoryContent(tid: "1", page: "2", filter: false, extend: [:])).first)
        #expect(card["vod_id"] as? String == "179702" && card["vod_pic"] as? String == "https://www.ixcyy.tv/upload/a.jpg")
        #expect(card["vod_remarks"] as? String == "HD中字")
        let vod = try detail(try await runtime.detailContent(ids: ["179624"]))
        #expect(vod["vod_year"] as? String == "2026" && vod["vod_area"] as? String == "美国")
        #expect(vod["vod_actor"] as? String == "甲,乙" && vod["vod_director"] as? String == "Mitch" && vod["type_name"] as? String == "恐怖片")
        #expect(vod["vod_content"] as? String == "简介 文字")
        #expect(vod["vod_play_from"] as? String == "土星$$$月亮")
        #expect(vod["vod_play_url"] as? String == "高清$/p/179624-1-1.html#花絮$/p/179624-1-2.html$$$正片$/p/179624-2-1.html")
        #expect(try object(try await runtime.playerContent(flag: "土星", id: "/p/179624-1-1.html", vipFlags: []))["url"] as? String
                == "https://v.cdn/a/index.m3u8")
        // The site refusing the client (nginx 444) is an empty address, not a retry.
        #expect(try object(try await runtime.playerContent(flag: "月亮", id: "/p/179624-2-1.html", vipFlags: []))["url"] as? String == "")
        #expect(try ids(try await runtime.searchContent(key: "海", quick: false, page: "1")) == ["179702"])
    }

    // MARK: Yidong4K

    @Test func yidongPostsColumnPagesAndPlaysAPublic139Share() async throws {
        W266Site.serve { url, body in
            let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
            switch (url.host ?? "", url.path) {
            case ("vidsite.cloudseekr.com", "/vidsite/vs/qryPageColumnVideo"):
                return (200, #"{"code":"000000","data":{"total":324,"pages":36,"list":[{"id":639,"title":"茫然女王","appCoverUrl":"https://oss/c.jpg"}]}}"#)
            case ("vidsite.cloudseekr.com", "/vidsite/vs/addAccessRecord"):
                return (200, #"{"code":"000000","data":null}"#)
            case ("vidsite.cloudseekr.com", "/vidsite/vs/qryVideoDetail"):
                let link = json["videoId"] as? Int == 639 ? "https://yun.139.com/shareweb/#/w/i/2yA8M6LmVzNwf" : "https://pan.quark.cn/s/abc"
                return (200, #"{"code":"000000","data":{"id":\#(json["videoId"] ?? 0),"title":"茫然女王","resUrl":"\#(link)","remark":"简介","score":7.9,"cateNameList":["2026","剧情"]}}"#)
            case ("share-kd-njs.yun.139.com", "/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6"):
                let request = shareOpen(body)["getOutLinkInfoReq"] as? [String: Any] ?? [:]
                guard request["linkID"] as? String == "2yA8M6LmVzNwf" else { return (200, shareSeal(#"{"resultCode":"9"}"#)) }
                switch request["pCaID"] as? String {
                case "root":
                    return (200, shareSeal(#"{"resultCode":"0","data":{"caLst":[{"caName":"S1","path":"p/s1"},{"caName":"S2","path":"p/s2"}],"coLst":[{"coName":"readme.txt","coID":"T1","coSize":1}]}}"#))
                case "p/s1":
                    return (200, shareSeal(#"{"resultCode":"0","data":{"coLst":[{"coName":"E01.mp4","coID":"Fa_1","coSize":1395864371}]}}"#))
                case "p/s2":
                    return (200, shareSeal(#"{"resultCode":"0","data":{"coLst":[{"coName":"E01.mkv","coID":"Fb-2","coSize":52428800}]}}"#))
                default: return (200, shareSeal(#"{"resultCode":"0","data":{}}"#))
                }
            case ("share-kd-njs.yun.139.com", "/yun-share/richlifeApp/devapp/IOutLink/getContentInfoFromOutLink"):
                let request = json["getContentInfoFromOutLinkReq"] as? [String: Any] ?? [:]
                return request["contentId"] as? String == "Fa_1" && request["linkID"] as? String == "2yA8M6LmVzNwf"
                    ? (200, #"{"data":{"contentInfo":{"presentURL":"https://hls.139.com/v3/hls/1/playlist.m3u8?sign=x"}}}"#) : (200, "{}")
            default: return nil
            }
        }
        let runtime = try await spider("Yidong4K")
        let page = try object(try await runtime.categoryContent(tid: "2", page: "3", filter: false, extend: [:]))
        #expect(page["pagecount"] as? Int == 36 && page["total"] as? Int == 324)
        let column = try object(try #require(W266Site.requests.first?.body))
        #expect(column["columnId"] as? Int == 2 && column["pageIndex"] as? Int == 3 && column["pageSize"] as? Int == 9)

        W266Site.forget()
        let vod = try detail(try await runtime.detailContent(ids: ["639"]))
        #expect(vod["vod_play_from"] as? String == "移动云盘")
        #expect(vod["vod_play_url"] as? String == "[S1]E01 [1.30 GB]$2yA8M6LmVzNwf+Fa_1#[S2]E01 [50.00 MB]$2yA8M6LmVzNwf+Fb-2")
        #expect(vod["type_name"] as? String == "2026,剧情" && vod["vod_remarks"] as? String == "7.9")
        let play = try object(try await runtime.playerContent(flag: "移动云盘", id: "2yA8M6LmVzNwf+Fa_1", vipFlags: []))
        #expect(play["url"] as? String == "https://hls.139.com/v3/hls/1/playlist.m3u8?sign=x" && play["parse"] as? Int == 0)
        // Every detail call carries the session's one fingerprint, and the visit is recorded first.
        let visits = W266Site.requests.filter { $0.url.host == "vidsite.cloudseekr.com" }
        #expect(visits.map(\.url.lastPathComponent) == ["addAccessRecord", "qryVideoDetail"])
        let prints = Set(visits.compactMap { (try? object($0.body))?["fprint"] as? String })
        #expect(prints.count == 1 && prints.first?.count == 32)
        // A share on another drive lists no line.
        let other = try detail(try await runtime.detailContent(ids: ["640"]))
        #expect(other["vod_play_from"] as? String == "" && other["vod_play_url"] as? String == "")
        #expect(try object(try await runtime.playerContent(flag: "", id: "bad id", vipFlags: []))["url"] as? String == "")
    }

    // MARK: AppFox

    @Test func appFoxFindsItsApiAndSendsItsOwnFilters() async throws {
        W266Site.serve { url, _ in
            switch (url.host ?? "", path(url)) {
            case ("cfg.example", "/fox.json"): return (200, #"{"apiDomain":"http://api.example/"}"#)
            case ("api.example", "/api.php/Appfox/init"):
                return (200, #"{"data":{"type_list":[{"type_id":0,"type_name":"全部"},{"type_id":20,"type_name":"日本动画","filter_type_list":[{"name":"class","list":["全部","搞笑"]},{"name":"sort","list":["最新","人气"]},{"name":"lang","list":[]}]},{"type_id":9,"type_name":"QQ群"},{"type_id":8,"type_name":"企鹅群 123"}]}}"#)
            case ("api.example", "/api.php/Appfox/nav"): return (200, #"{"data":[{"navigationId":1}]}"#)
            case ("api.example", "/api.php/Appfox/nav_video?id=1"):
                return (200, #"{"data":[{"banner":[{"vod_id":1,"vod_name":"横幅"}],"categories":[{"videos":[{"vod_id":2,"vod_name":"甲"}]},{"videos":null}]}]}"#)
            case ("api.example", let p) where p.hasPrefix("/api.php/Appfox/vodList"):
                return (200, #"{"data":{"recommend_list":[{"vod_id":66369,"vod_name":"梅比乌斯之尘"}]}}"#)
            default: return nil
            }
        }
        let runtime = try await spider("AppFox", ext: #"{"host":"http://cfg.example/fox.json","ver":"2","ua":{"category":"FoxCat/1","home":"FoxHome/1"}}"#)
        let home = try object(try await runtime.homeContent(filter: true))
        let classes = try #require(home["class"] as? [[String: String]])
        #expect(classes.map { $0["type_id"]! } == ["20", "9"])  // 全部 and 企鹅群 hidden; "QQ群" is not upstream's exact "QQ"
        let filters = try #require((home["filters"] as? [String: [[String: Any]]])?["20"])
        #expect(filters.map { $0["key"] as? String } == ["class", "by"] && filters.map { $0["name"] as? String } == ["类型", "排序"])
        #expect(try ids(try await runtime.homeVideoContent()) == ["1", "2"])
        #expect(W266Site.requests.filter { $0.url.path.hasPrefix("/api.php/Appfox/nav") }.allSatisfy { $0.headers["User-Agent"] == "FoxHome/1" })
        _ = try await runtime.categoryContent(tid: "20", page: "2", filter: true, extend: ["class": "搞笑", "by": "人气"])
        let request = try #require(W266Site.requests.last)
        #expect(path(request.url) == "/api.php/Appfox/vodList?type_id=20&page=2&class=%E6%90%9E%E7%AC%91&area=%E5%85%A8%E9%83%A8"
                + "&lang=%E5%85%A8%E9%83%A8&year=%E5%85%A8%E9%83%A8&sort=%E4%BA%BA%E6%B0%94")
        #expect(request.headers["User-Agent"] == "FoxCat/1")
    }

    @Test func appFoxNamesLinesAndResolvesThroughJiexiParseOrTheApp() async throws {
        W266Site.serve { url, _ in
            switch (url.host ?? "", path(url)) {
            case ("api.example", "/api.php/Appfox/vod?ac=detail&ids=16343"):
                return (200, #"{"list":[{"vod_id":16343,"vod_name":"甲","vod_content":"<p>简介</p>","vod_play_from":"rym3u8$$$qq$$$NICO","vod_play_url":"第01集$https://cdn/1/index.m3u8#坏$$$第01集$https://v.qq.com/x/1.html$$$第01集$nico-1"}]}"#)
            case ("api.example", "/api.php/Appfox/config"):
                return (200, #"{"data":{"playerList":[{"playerCode":"rym3u8","playerName":"花柳斋|R线"},{"playerCode":"NICO","playerName":"NICO"}],"jiexiDataList":[{"playerCode":"qq","url":"https://jx.example/?url="},{"playerCode":"bad","url":"ftp://x"}]}}"#)
            case ("jx.example", "/?url=https://v.qq.com/x/1.html"): return (200, #"{"url":"https://media/qq.m3u8"}"#)
            default: return nil
            }
        }
        let runtime = try await spider("AppFox", ext: #"{"host":"http://api.example","parse":{"NICO":"parse:https://sniff.example/?u="}}"#)
        let vod = try detail(try await runtime.detailContent(ids: ["16343"]))
        #expect(vod["vod_play_from"] as? String == "花柳斋|R线 (rym3u8)$$$qq$$$NICO")
        #expect(vod["vod_play_url"] as? String == "第01集$rym3u8@https://cdn/1/index.m3u8$$$第01集$qq@https://v.qq.com/x/1.html$$$第01集$NICO@nico-1")
        #expect(vod["vod_content"] as? String == "简介")
        let direct = try object(try await runtime.playerContent(flag: "", id: "rym3u8@https://cdn/1/index.m3u8", vipFlags: []))
        #expect(direct["url"] as? String == "https://cdn/1/index.m3u8" && direct["parse"] as? Int == 0)
        #expect((direct["header"] as? [String: String])?["User-Agent"]?.contains("iPhone") == true)
        let jiexi = try object(try await runtime.playerContent(flag: "", id: "qq@https://v.qq.com/x/1.html", vipFlags: []))
        #expect(jiexi["url"] as? String == "https://media/qq.m3u8" && jiexi["parse"] as? Int == 0)
        let sniff = try object(try await runtime.playerContent(flag: "", id: "NICO@nico-1", vipFlags: []))
        #expect(sniff["url"] as? String == "https://sniff.example/?u=nico-1" && sniff["parse"] as? Int == 1)
        let app = try object(try await runtime.playerContent(flag: "", id: "youku@https://v.youku.com/1", vipFlags: []))
        #expect(app["url"] as? String == "https://v.youku.com/1" && app["jx"] as? Int == 1 && app["parse"] as? Int == 0)
        // The player/jiexi config is read once per session.
        #expect(W266Site.requests.filter { $0.url.path == "/api.php/Appfox/config" }.count == 1)
    }

    // MARK: AnimeBashi

    @Test func bashiReadsDetailInOrderAndPlaysThroughHhplayer() async throws {
        let page = """
        <h1 class="v_title"><a href="/v/5396.html" title="末世在线播放">末世钞能力者</a></h1>\
        <p class="v_desc"><span class="desc">第223话</span></p><div class="cover"><img src="http://p.qpic.cn/a/600" /></div>\
        <div id="intro"><p>剧情：重生</p><p>导演：张三</p><p>主演：李四</p></div>\
        <ul class="tab_control play_from"><li class="current">线路1</li></ul>\
        <div class="tab_content" id="play_list"><ul class="play_list current"><li><a href="/p/5396-1-2.html">2</a></li>\
        <li><a href="/p/5396-1-1.html">1</a></li><li><a>无</a></li></ul><ul class="play_list"><li><a href="/p/5396-2-1.html">1</a></li></ul></div>
        """
        W266Site.serve { url, body in
            switch (url.host ?? "", path(url)) {
            case ("dmbus.cc", "/list-1-1.html"):
                return (200, #"<ul class="v_list"><li><div class="item"><a href="/v/5692.html" class="cover lazy" data-bg="/img/a.jpg"></a><a class="title" href="/v/5692.html" title="&#8203;全民转职">x</a><span class="desc">第482话</span></div></li></ul><a href="/list-1-2.html">2</a><a href="/list-1-10.html">尾页</a>"#)
            case ("dmbus.cc", "/list-2-1.html"):
                return (200, #"<ul class="v_list"><li><div class="item"><a class="title" href="/v/9.html" title="单页"></a></div></li></ul>"#)
            case ("dmbus.cc", "/v/5396.html"): return (200, page)
            case ("dmbus.cc", "/p/5396-1-1.html"): return (200, #"<div class="p_box"><iframe src="https://hhjx.hhplayer.com/?url=ABC"></iframe></div>"#)
            case ("hhjx.hhplayer.com", "/?url=ABC"): return (200, #"var config = {"url": "ABC", "t": 1794216384, "key": "k1"}"#)
            case ("hhjx.hhplayer.com", "/api/parse"):
                return body == #"{"url":"ABC","t":1794216384,"key":"k1","client_fallback":false}"# ? (200, #"{"code":200,"url":"http://media.gtimg/a.mp4?v=1"}"#) : (200, "{}")
            default: return nil
            }
        }
        let runtime = try await spider("AnimeBashi")
        let category = try object(try await runtime.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        let card = try #require((category["list"] as? [[String: Any]])?.first)
        #expect(card["vod_id"] as? String == "5692" && card["vod_pic"] as? String == "https://dmbus.cc/img/a.jpg")
        #expect(category["pagecount"] as? Int == 10)
        #expect(try object(try await runtime.categoryContent(tid: "2", page: "1", filter: false, extend: [:]))["pagecount"] as? Int == 1)
        let vod = try detail(try await runtime.detailContent(ids: ["5396"]))
        #expect(vod["vod_name"] as? String == "末世钞能力者" && vod["vod_remarks"] as? String == "第223话")
        #expect(vod["vod_director"] as? String == "张三" && vod["vod_actor"] as? String == "李四" && vod["vod_content"] as? String == "重生")
        #expect(vod["vod_play_from"] as? String == "线路1$$$线路2")
        #expect(vod["vod_play_url"] as? String == "1$/p/5396-1-1.html#2$/p/5396-1-2.html$$$1$/p/5396-2-1.html")
        let play = try object(try await runtime.playerContent(flag: "线路1", id: "/p/5396-1-1.html", vipFlags: []))
        #expect(play["url"] as? String == "https://media.gtimg/a.mp4?v=1")
        #expect(try object(try await runtime.playerContent(flag: "线路2", id: "/p/5396-2-1.html", vipFlags: []))["url"] as? String == "")
    }

    // MARK: SaoHuo

    @Test func saoHuoFollowsTheMirrorAppliesFiltersAndSniffsPlay() async throws {
        let detailPage = """
        <section class="v_info_box"><h1 class="v_title"><a href="/movie/77.html">某片</a></h1><p>7.3分 / 美国 / 2026 / 剧情 / 导演:甲 / 主演:乙,丙<a href="#info_more" class="go_more">剧情介绍</a></p></section>\
        <p class="p_txt show_part">简介<br /><a href="/movie/77.html">某片手机在线观看</a>，由骚火电影友情提供。</p>\
        <div class="play_from"><ul class="from_list"><li>云播</li><li>备用</li></ul></div>\
        <ul id="play_link"><li><a href="/play/1-1-2.html">第2集</a><a href="/play/1-1-1.html">第1集</a></li>\
        <li><a href="https://shdy2.com/play/1-2-1.html">HD</a></li></ul>
        """
        W266Site.serve { url, _ in
            switch (url.host ?? "", path(url)) {
            case ("shapp.us", "/"): return (200, #"<div class="content-top"><ul><li><a href="https://shdy2.com"><i>x</i></a></li></ul></div>"#)
            case ("shdy2.com", "/list/9-2.html"):
                return (200, #"<div class="v_list"><li><div class="v_img"><a href="/movie/77.html" title="某片"><img data-original="https://i/a.jpg"/></a><div class="v_note">HD</div></div></li></div>"#)
            case ("shdy2.com", "/movie/77.html"): return (200, detailPage)
            case ("shdy2.com", "/play/1-1-1.html"): return (200, #"<iframe src="/player/?url=abc"></iframe>"#)
            case ("shdy2.com", "/play/1-1-2.html"): return (200, #"<iframe src="https://hhjx.hhplayer.com/?url=X1"></iframe>"#)
            case ("hhjx.hhplayer.com", "/?url=X1"): return (200, #"{"url": "X1", "t": 5, "key": "k"}"#)
            case ("hhjx.hhplayer.com", "/api/parse"): return (200, #"{"code":200,"url":"http://media/s.m3u8"}"#)
            default: return nil
            }
        }
        let runtime = try await spider("SaoHuo", ext: "https://shdy5.us")
        let home = try object(try await runtime.homeContent(filter: true))
        #expect((home["filters"] as? [String: Any])?.keys.sorted() == ["1", "2", "4"])
        let card = try #require(try list(try await runtime.categoryContent(tid: "1", page: "2", filter: true, extend: ["cateId": "9"])).first)
        #expect(card["vod_id"] as? String == "/movie/77.html" && card["vod_remarks"] as? String == "HD")
        let vod = try detail(try await runtime.detailContent(ids: ["/movie/77.html"]))
        #expect(vod["type_name"] as? String == "7.3分 / 美国 / 2026 / 剧情" && vod["vod_director"] as? String == "甲")
        #expect(vod["vod_actor"] as? String == "乙,丙")
        #expect(vod["vod_content"] as? String == "简介")
        #expect(vod["vod_name"] as? String == "某片")
        #expect(vod["vod_play_from"] as? String == "云播$$$备用")
        #expect(vod["vod_play_url"] as? String == "第1集$/play/1-1-1.html#第2集$/play/1-1-2.html$$$HD$/play/1-2-1.html")
        let play = try object(try await runtime.playerContent(flag: "云播", id: "/play/1-1-1.html", vipFlags: []))
        #expect(play["url"] as? String == "https://shdy2.com/player/?url=abc" && play["parse"] as? Int == 1)
        let parsed = try object(try await runtime.playerContent(flag: "云播", id: "/play/1-1-2.html", vipFlags: []))
        #expect(parsed["url"] as? String == "https://media/s.m3u8" && parsed["parse"] as? Int == 0)
        #expect(try object(try await runtime.playerContent(flag: "备用", id: "/play/1-2-1.html", vipFlags: []))["url"] as? String == "")
    }

    // Without the mirror page the configured host is used.
    @Test func saoHuoFallsBackToTheConfiguredHost() async throws {
        W266Site.serve { url, _ in url.host == "shdy5.us" && url.path == "/" ? (200, #"<div class="v_list"><div class="v_img"><a href="/movie/1.html" title="甲"></a></div></div>"#) : nil }
        let runtime = try await spider("SaoHuo", ext: "https://shdy5.us/")
        #expect(try ids(try await runtime.homeVideoContent()) == ["/movie/1.html"])
    }
}
