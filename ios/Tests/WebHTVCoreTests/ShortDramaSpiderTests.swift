import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-44A/44B/44C: the IOS-POC-44 ports against canned replies shaped like the live APIs'
// (docs/IOS-POC-44-csp-portable-sites.md). Most classes hard-code their hosts, so the stub answers
// those hosts — only inside the session these tests build, never process-wide.

/// Answers by host + path (query ignored), one queued reply per call with the last one repeating,
/// and remembers every request with its headers and body.
final class ShortDramaSite: URLProtocol, @unchecked Sendable {
    struct Asked { let url: URL; let headers: [String: String]; let body: String }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [String]] = [:]
    nonisolated(unsafe) private static var asked: [Asked] = []

    static func serve(_ served: [String: [String]]) {
        lock.withLock { served.forEach { replies[$0.key] = $0.value } }
    }

    static func requests(to path: String) -> [Asked] {
        lock.withLock { asked.filter { $0.url.path == path } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host ?? ""
        return host.hasSuffix(".invalid") || ["api.drama.9ddm.com", "freevideo.zqqds.cn", "neptune.qmplaylet.com",
            "api-store.qmplaylet.com", "api-read.qmplaylet.com", "sv.baidu.com", "www.hkybqufgh.com",
            "4kyszx.top", "doh.pub", "app.nyafun.vip", "yzy0916.n0z6fkpuk.com",
            "api.46d5umpk.com", "www.mdzyapi.com"].contains(host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
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
        let key = url.host! + url.path
        let reply = Self.lock.withLock { () -> String? in
            Self.asked.append(Asked(url: url, headers: request.allHTTPHeaderFields ?? [:],
                                    body: String(decoding: body, as: UTF8.self)))
            guard var queue = Self.replies[key], let first = queue.first else { return nil }
            if queue.count > 1 { queue.removeFirst(); Self.replies[key] = queue }
            return first
        }
        let response = HTTPURLResponse(url: url, statusCode: reply == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((reply ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func spider(_ name: String, extend: String = "") async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ShortDramaSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: name, script: try #require(registry.entry(for: "csp_\(name)")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "\(name)-test", defaults: UserDefaults(suiteName: "\(name)-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: extend)
    return runtime
}

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

@Test func weiguanDJListsTagsAndPlaysTheSignedQualityList() async throws {
    let api = "api.drama.9ddm.com/drama/home/"
    ShortDramaSite.serve([
        api + "shortVideoTags": [#"{"code":200,"tags":["逆袭","都市"]}"#],
        api + "search": [#"{"code":200,"data":[{"oneId":"110","title":"替身","horzPoster":"https://p.invalid/h.jpg","episodeCount":30}]}"#],
        api + "shortVideoDetail": [#"""
        {"code":200,"title":"替身","vertPoster":"https://p.invalid/v.jpg","description":"簡介","data":[
          {"playOrder":1,"videoClarityList":[{"name":"1080P","url":"https://v.invalid/1.mp4?sign=a"},
                                             {"name":"720P","url":"https://v.invalid/2.mp4?sign=b"}]}]}
        """#],
    ])
    let weiguan = try await spider("WeiguanDJ")

    let home = try json(try await weiguan.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_id"] ?? "" } == ["逆袭", "都市"])

    let page = try json(try await weiguan.categoryContent(tid: "逆袭", page: "1", filter: false, extend: [:]))
    let item = try #require((page["list"] as? [[String: Any]])?.first)
    #expect(item["vod_id"] as? String == "110")
    #expect(item["vod_remarks"] as? String == "30", "episodeCount is a number in the JSON")
    #expect(page["pagecount"] as? Int == 1, "a short page is the last one")
    let listing = try #require(ShortDramaSite.requests(to: "/drama/home/search").last)
    let body = try json(listing.body)
    #expect(body["subject"] as? String == "逆袭")
    #expect(body["pageSize"] as? Int == 30)
    #expect(listing.url.query?.range(of: #"clientInfo=[0-9a-f]{32}$"#, options: .regularExpression) != nil)

    let detail = try #require((try json(try await weiguan.detailContent(ids: ["110"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "短剧")
    let episode = try #require(detail["vod_play_url"] as? String)
    #expect(episode.hasPrefix("1$"))

    let play = try json(try await weiguan.playerContent(flag: "短剧", id: String(episode.dropFirst(2)), vipFlags: []))
    #expect(play["parse"] as? Int == 0)
    #expect(play["url"] as? [String] ==
            ["1080P", "https://v.invalid/1.mp4?sign=a", "720P", "https://v.invalid/2.mp4?sign=b"])
    #expect((play["header"] as? [String: String])?["User-Agent"] == "okhttp/5.1.0")
    await weiguan.destroy()
}

@Test func hemaDJSpeaksTheAESEnvelopeAndRetriesAnExpiredDeviceProfile() async throws {
    let key = "dzkjgfyxgshylgzm", iv = "apiupdownedcrypt"
    func sealed(_ plain: String) -> String {
        #"{"code":0,"data":""# + CryptoHost.run(algorithm: "aes", encrypt: true, input: plain, key: key,
                                                iv: iv, mode: "CBC", inputEncoding: "base64") + #""}"#
    }
    func opened(_ cipher: String) throws -> [String: Any] {
        try json(CryptoHost.run(algorithm: "aes", encrypt: false, input: cipher, key: key, iv: iv,
                                mode: "CBC", inputEncoding: "base64"))
    }
    let portal = "freevideo.zqqds.cn/free-video-portal/portal/"
    ShortDramaSite.serve([
        portal + "1125": [sealed(#"""
        {"channelGroupData":[{"channelGroupId":0,"channelGroupName":"全部","channelData":[]},
                             {"channelGroupId":180,"channelGroupName":"新剧","channelData":[{"channelId":5,"channelName":"都市"}]}],
         "columnData":[{"videoData":[{"bookId":"B1","bookName":"总裁","coverWap":"https://c.invalid/1.jpg",
                                      "finishStatusCn":"完结","updateNum":70}]}],"hasMore":true}
        """#)],
        portal + "1131": [sealed(#"""
        {"videoInfo":{"bookName":"总裁","coverWap":"https://c.invalid/1.jpg","finishStatusCn":"完结",
                      "introduction":"簡介","protagonist":"甲"},
         "chapterList":[{"chapterName":"第1集","chapterId":"C1"},{"chapterName":"第2集","chapterId":"C2"}]}
        """#)],
        // The first play request meets an expired device profile.
        portal + "1139": [#"{"code":8,"msg":"expired"}"#,
                          sealed(#"{"chapterInfo":[{"content":{"mp4Url":"https://m.invalid/1.mp4?t=1"}}]}"#)],
        portal + "1803": [sealed(#"{"searchVos":[{"bookId":"B2","bookName":"总裁2"}]}"#)],
    ])
    let hema = try await spider("HemaDJ")

    let home = try json(try await hema.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { "\($0["type_id"]!)=\($0["type_name"]!)" } == ["0=推荐", "180=新剧"])
    let channel = try #require(((home["filters"] as? [String: Any])?["180"] as? [[String: Any]])?.first)
    #expect(channel["key"] as? String == "class")
    #expect((channel["value"] as? [[String: String]])?.first == ["n": "都市", "v": "5@都市"])
    #expect((home["list"] as? [[String: Any]])?.first?["vod_remarks"] as? String == "完结/70集")
    let first = try #require(ShortDramaSite.requests(to: "/free-video-portal/portal/1125").first)
    #expect(first.headers["alg"] == "HG45LKBS")
    #expect(try opened(try #require(first.headers["datas"]))["pname"] as? String == "com.dz.hmjc")
    #expect(try opened(first.body)["recSwitch"] as? Bool == true)

    _ = try await hema.categoryContent(tid: "180", page: "2", filter: true, extend: ["class": "5@都市"])
    let category = try opened(try #require(ShortDramaSite.requests(to: "/free-video-portal/portal/1125").last).body)
    #expect(category["channelGroupId"] as? Int == 180)
    #expect(category["channelId"] as? Int == 5)
    #expect(category["pageFlag"] as? String == "1")

    let detail = try #require((try json(try await hema.detailContent(ids: ["B1"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "河马", "one flag, one episode list")
    #expect(detail["vod_play_url"] as? String == "第1集$B1@C1#第2集$B1@C2")

    let play = try json(try await hema.playerContent(flag: "河马", id: "B1@C1", vipFlags: []))
    #expect(play["url"] as? String == "https://m.invalid/1.mp4?t=1")
    #expect((play["header"] as? [String: String])?["User-Agent"]?.hasPrefix("aliplayer(") == true)
    let plays = ShortDramaSite.requests(to: "/free-video-portal/portal/1139")
    #expect(plays.count == 2, "code 8 rebuilds the device profile and retries once")
    #expect(plays[0].headers["datas"] != plays[1].headers["datas"])

    let search = try json(try await hema.searchContent(key: " 总裁 ", quick: false, page: "1"))
    #expect((search["list"] as? [[String: Any]])?.first?["vod_id"] as? String == "B2")
    #expect(try opened(try #require(ShortDramaSite.requests(to: "/free-video-portal/portal/1803").last).body)["keyword"]
            as? String == "总裁")
    await hema.destroy()
}

private func md5(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test func qimaoDJSignsEveryRequestAndStripsTitleMarkup() async throws {
    let salt = "d3dGiJc651gSQ8w1"
    ShortDramaSite.serve([
        "neptune.qmplaylet.com/playlet-domain-android.json":
            [#"{"data":{"bc":"https://api-store.qmplaylet.com/","ks":"https://api-read.qmplaylet.com/"}}"#],
        // Home, then the category: the same endpoint answers both.
        "api-store.qmplaylet.com/api/v1/playlet/index": [
            #"{"data":{"tag_items":[{"tag_id":"0","tag_name":"推荐"},{"tag_id":"12","tag_name":"都市"},{"tag_id":"","tag_name":"空"}]}}"#,
            #"{"data":{"list":[{"playlet_id":"22116","title":"<font color=red>总裁</font>","image":"https://i.invalid/1.jpg","total_episode_num":80}]}}"#,
        ],
        "api-read.qmplaylet.com/player/api/v1/playlet/info": [#"""
        {"data":{"title":"总裁","image_link":"https://i.invalid/1.jpg","intro":"簡介",
                 "play_list":[{"sort":1,"video_url":"https://v.invalid/1.m3u8"},{"sort":2,"video_url":""}]}}
        """#],
        "api-store.qmplaylet.com/api/v1/playlet/search": [#"{"data":{"list":[{"id":"9","title":"<font>总</font>裁"}]}}"#],
    ])
    let qimao = try await spider("QimaoDJ")

    let home = try json(try await qimao.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { "\($0["type_id"]!)=\($0["type_name"]!)" } == ["0=推荐", "12=都市"])
    let asked = try #require(ShortDramaSite.requests(to: "/api/v1/playlet/index").first)
    let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: asked.url, resolvingAgainstBaseURL: false)?
        .queryItems).map { ($0.name, $0.value ?? "") })
    #expect(query["sign"] == md5("operation=1playlet_privacy=1tag_id=0" + salt), "md5 of the sorted k=v pairs plus the salt")
    // `qm-params` is base64 run through the original's table; undo the table and it is the profile.
    let qm = try #require(asked.headers["qm-params"])
    let table = Dictionary(uniqueKeysWithValues: zip("MUlErYWbdJ9saI0oy_HGitgNA8Fk3hfRqC4pmBOuc6Kx5T-2zSZ1VvjQ7DwnLe",
                                                     "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"))
    let restored = String(qm.map { $0 == "P" ? "+" : $0 == "X" ? "/" : table[$0] ?? $0 })
    let profile = try json(String(decoding: try #require(Data(base64Encoded: restored)), as: UTF8.self))
    #expect(profile["AUTHORIZATION"] as? String == "6bcc46919d10d06a")
    #expect(asked.headers["sign"] == md5("AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=va-vivo_lf"
                                         + "is-white=net-env=1platform=androidqm-params=\(qm)reg=" + salt))

    let page = try json(try await qimao.categoryContent(tid: "0", page: "1", filter: false, extend: [:]))
    let item = try #require((page["list"] as? [[String: Any]])?.first)
    #expect(item["vod_name"] as? String == "总裁")
    #expect(item["vod_remarks"] as? String == "80")
    #expect(item["vod_pic"] as? String == "https://i.invalid/1.jpg")

    let detail = try #require((try json(try await qimao.detailContent(ids: ["22116"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "七猫")
    #expect(detail["vod_play_url"] as? String == "第1集$https://v.invalid/1.m3u8", "an episode with no address is dropped")

    let play = try json(try await qimao.playerContent(flag: "七猫", id: "https://v.invalid/1.m3u8", vipFlags: []))
    #expect(play["url"] as? String == "https://v.invalid/1.m3u8")
    #expect((play["header"] as? [String: String])?["User-Agent"] == "webviewversion/0")

    let search = try json(try await qimao.searchContent(key: "总裁", quick: false, page: "1"))
    #expect((search["list"] as? [[String: Any]])?.first?["vod_name"] as? String == "总裁")
    await qimao.destroy()
}

@Test func haokanDJWalksTheTwoHopDetailAndPicksTheBestQuality() async throws {
    let base = "sv.baidu.com/"
    ShortDramaSite.serve([
        base + "haokan/ui-feed/playletShelfFeed":
            [#"{"data":{"playlet_shelf_filter_panel":[{"tag_list":[{"tag_id":"3","name":"都市"},{"tag_id":"5","name":"古装"}]}]}}"#],
        base + "haokan/ui-feed/playletTagsFeed":
            [#"{"data":{"list":[{"playlet_id":"907","playlet_title":"岁月","playlet_poster":"https://p.invalid/1.jpg","episodes_num_text":"70集"}]}}"#],
        // The detail's first hop, then the player's quality list: one endpoint, two form keys.
        base + "appui/api": [
            #"{"video/commonlist":{"data":{"results":[{"content":{"vid":"477"}}]}}}"#,
            #"{"video/relate":{"data":{"cur_video":{"clarityUrl":[{"key":"sd","url":"http://v.invalid/sd.mp4"},{"key":"1080p","url":"http://v.invalid/1080.mp4"}]}}}}"#,
        ],
        base + "haokan/ui-video/playlet/rec/detail":
            [#"{"data":{"playlet_title":"岁月","playlet_poster":"https://p.invalid/1.jpg","description":"簡介","vid_list":["477","478"]}}"#],
        base + "haokan/ui-interact/playlet/search/sugs": [#"{"status":101801001105,"msg":"猜空了","data":[]}"#],
    ])
    let haokan = try await spider("HaokanDJ")

    let home = try json(try await haokan.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { "\($0["type_id"]!)=\($0["type_name"]!)" } == ["3=都市", "5=古装"])
    #expect(ShortDramaSite.requests(to: "/haokan/ui-feed/playletShelfFeed").first?.headers["Cookie"]?
        .hasPrefix("BAIDUCUID=") == true)

    let page = try json(try await haokan.categoryContent(tid: "3", page: "1", filter: false, extend: [:]))
    #expect((page["list"] as? [[String: Any]])?.first?["vod_remarks"] as? String == "70集")
    #expect(page["pagecount"] as? Int == 1, "a short page is the last one")
    // The host's form encoder escapes `_` as well; a server decodes it either way.
    #expect(ShortDramaSite.requests(to: "/haokan/ui-feed/playletTagsFeed").last?.body.removingPercentEncoding == "tag_id=3&rn=9&pn=1")

    let detail = try #require((try json(try await haokan.detailContent(ids: ["907"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_url"] as? String == "第1集$477|||907#第2集$478|||907")
    #expect(ShortDramaSite.requests(to: "/haokan/ui-video/playlet/rec/detail").last?.body.removingPercentEncoding == "vid=477&playlet_id=907")

    let play = try json(try await haokan.playerContent(flag: "短剧", id: "478|||907", vipFlags: []))
    #expect(play["url"] as? String == "http://v.invalid/1080.mp4", "1080p before sc before the first")
    let relate = try #require(ShortDramaSite.requests(to: "/appui/api").last?.body.removingPercentEncoding)
    #expect(relate.contains("video/relate=method=post&vid=478&"))
    #expect(relate.contains("&video_set_id=907&"))

    let search = try json(try await haokan.searchContent(key: "岁月", quick: false, page: "1"))
    #expect((search["list"] as? [[String: Any]])?.isEmpty == true)
    await haokan.destroy()
}

@Test func jpysTakesTheFirstMirrorThatAnswersAndJysFallsBackToTheDefaultHost() async throws {
    let key = "cb808529bae6b6be45ecfab29a4889bc", api = "/api/mw-movie/anonymous/"
    func signed(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(md5(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    let hot = #"{"code":200,"data":[{"vodId":1,"vodName":"热","vodPic":"https://p.invalid/1.jpg","vodVersion":"HD"}]}"#
    ShortDramaSite.serve([
        "j2.invalid" + api + "home/hotSearch": [hot],
        "j2.invalid" + api + "video/list":
            [#"{"code":200,"data":{"totalPage":209,"list":[{"vodId":146870,"vodName":"醉胆追凶","vodPic":"https://p.invalid/2.jpg","vodVersion":"HD"}]}}"#],
        "j2.invalid" + api + "video/detail": [#"""
        {"code":200,"data":{"vodName":"醉胆追凶","vodPic":"https://p.invalid/2.jpg","vodYear":2026,"vodBlurb":"簡介",
                            "episodeList":[{"name":"第1集","nid":1317757},{"name":"第2集","nid":1317758}]}}
        """#],
        "j2.invalid" + api + "v2/video/episode/url":
            [#"{"code":200,"data":{"list":[{"url":"https://v.invalid/1080/index.m3u8"},{"url":"https://v.invalid/720/index.m3u8"}]}}"#],
        "j2.invalid" + api + "video/searchByWord":
            [#"{"code":200,"data":{"result":{"list":[{"vodId":7,"vodName":"甲","vodClass":"伦理"},{"vodId":8,"vodName":"乙","vodClass":"剧情","vodRemarks":"更新至3集"}]}}}"#],
        "www.hkybqufgh.com" + api + "home/hotSearch": [hot],
    ])
    // j1 answers nothing (404), so the mirror after it is the one used; the trailing `/` is dropped.
    let jpys = try await spider("Jpys", extend: "https://j1.invalid, https://j2.invalid/")
    func asked(_ path: String) -> [ShortDramaSite.Asked] {
        ShortDramaSite.requests(to: api + path).filter { $0.url.host == "j2.invalid" }
    }

    let home = try json(try await jpys.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_id"] ?? "" } == ["1", "2", "4", "3"])
    let years = (((home["filters"] as? [String: Any])?["3"] as? [[String: Any]])?.last?["value"] as? [[String: String]])
    #expect(years?.map { $0["n"] ?? "" } == ["全部", "2026", "2025", "2024", "2023", "2022", "2021", "2020", "更早"])
    #expect((home["list"] as? [[String: Any]])?.first?["vod_remarks"] as? String == "HD")
    let hotSearch = try #require(asked("home/hotSearch").last)
    #expect(hotSearch.headers["sign"] == signed("key=\(key)&t=\(hotSearch.headers["T"] ?? "")"))

    let page = try json(try await jpys.categoryContent(tid: "1", page: "1", filter: true,
                                                       extend: ["area": "中国大陆", "year": "全部"]))
    #expect(page["pagecount"] as? Int == 209)
    let list = try #require(asked("video/list").last)
    let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: list.url, resolvingAgainstBaseURL: false)?
        .queryItems).map { ($0.name, $0.value ?? "") })
    #expect(query == ["type1": "1", "pageNum": "1", "area": "中国大陆", "year": ""])
    #expect(list.headers["sign"] == signed("area=中国大陆&pageNum=1&type1=1&year=&key=\(key)&t=\(list.headers["T"] ?? "")"),
            "signed over the raw values in the original's own order")

    let detail = try #require((try json(try await jpys.detailContent(ids: ["146870"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "在线播放")
    #expect(detail["vod_play_url"] as? String == "第1集$146870@1317757#第2集$146870@1317758")
    #expect(detail["vod_year"] as? String == "2026")

    let play = try json(try await jpys.playerContent(flag: "在线播放", id: "146870@1317757", vipFlags: []))
    #expect(play["url"] as? String == "https://v.invalid/1080/index.m3u8")
    #expect((play["header"] as? [String: String])?["Origin"] == "https://j2.invalid")

    let search = try json(try await jpys.searchContent(key: "乙", quick: false, page: "1"))
    #expect((search["list"] as? [[String: Any]])?.map { $0["vod_id"] as? String ?? "" } == ["8"], "伦理 is dropped")
    await jpys.destroy()

    // Jys's only mirror is dead here (its certificate expired), so it runs on the class default.
    let jys = try await spider("Jys", extend: "https://dead.invalid/")
    #expect((try json(try await jys.homeContent(filter: false))["list"] as? [[String: Any]])?.count == 1)
    #expect(ShortDramaSite.requests(to: api + "home/hotSearch").contains { $0.url.host == "www.hkybqufgh.com" })
    await jys.destroy()
}

private func hmacSHA256(_ text: String, key: String) -> String {
    Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8))))
        .map { String(format: "%02x", $0) }.joined()
}

@Test func feiyuSignsEveryRequestWithTheDerivedSecretAndOrdersLinesByQuality() async throws {
    let api = "4kyszx.top/api/app/"
    ShortDramaSite.serve([
        api + "categories": [#"{"code":200,"data":[{"id":1,"name":"连续剧"},{"id":2,"name":"电影"}]}"#],
        api + "ranking/list": [#"{"code":200,"data":[{"id":7,"title":"排行","cover":"https://p.invalid/7.jpg","subtitle":"已完结"}]}"#],
        api + "categories/2/videos": [#"""
        {"code":200,"data":{"list":[{"id":243253,"name":"蜘蛛侠","pic":"https://p.invalid/1.jpg","subTitle":"别名"}],
                            "page":1,"pageSize":20,"total":82057}}
        """#],
        api + "videos/243253": [#"""
        {"code":200,"data":{"id":243253,"name":"蜘蛛侠","pic":"https://p.invalid/1.jpg","categoryName":"电影","year":"2026",
          "area":"美国","actor":"甲","director":"乙","content":"簡介","remarks":"HD中字","playGroups":[
          {"name":"极速资源站jsm3u8","code":"jsm3u8","parseApi":"","playUrls":[{"name":"高清版","url":"https://a.invalid/1.m3u8"}]},
          {"name":"高清qq","code":"qq","parseApi":"https://jx.invalid/api/?url=","playUrls":[{"name":"第1集","url":"https://v.qq.com/x/1.html"}]},
          {"name":"暴风资源","code":"bfzym3u8","parseApi":"","playUrls":[{"name":"第1集","url":"https://b.invalid/1.m3u8"},
                                                                    {"name":"第2集","url":"https://b.invalid/2.m3u8"}]},
          {"code":"lzm3u8","parseApi":"","playUrls":[{"name":"TC","url":"https://l.invalid/1.m3u8"}]}]}}
        """#],
        api + "videos/search": [#"{"code":200,"data":{"list":[{"id":5,"title":"甲","cover":"https://p.invalid/5.jpg","remarks":"HD"}],"page":2,"pageSize":20,"total":109}}"#],
        "jx.invalid/api": [#"{"url":"https://real.invalid/x.m3u8"}"#, #"{"code":"403","url":"/mizhicdn/video/error.mp4"}"#],
    ])
    let feiyu = try await spider("Feiyu")
    // `init`'s secret, then one signature per request over the original's six-line payload.
    let secret = hmacSHA256("f45a775875e2e004adbcea78e3312218", key: "cms_device_salt_v1_2024cms_app_sign_key_v1_2024_secure")
    func signed(_ asked: ShortDramaSite.Asked, path: String, query: String) -> Bool {
        let stamp = asked.headers["x-timestamp"] ?? "", nonce = asked.headers["x-nonce"] ?? ""
        let random = String(decoding: Data(base64Encoded: nonce) ?? Data(), as: UTF8.self)
        return random.range(of: "^[A-Za-z0-9]{16}$", options: .regularExpression) != nil
            && asked.headers["x-signature"] == hmacSHA256(["GET", path, query, stamp, nonce, "2.6.8+1"].joined(separator: "\n"), key: secret)
    }

    let home = try json(try await feiyu.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_name"] ?? "" } == ["连续剧", "电影"])
    #expect(signed(try #require(ShortDramaSite.requests(to: "/api/app/categories").last), path: "/api/app/categories", query: ""))

    let hot = try json(try await feiyu.homeVideoContent())
    #expect((hot["list"] as? [[String: Any]])?.first?["vod_name"] as? String == "排行")
    #expect(signed(try #require(ShortDramaSite.requests(to: "/api/app/ranking/list").last), path: "/api/app/ranking/list", query: "category=1"))

    let page = try json(try await feiyu.categoryContent(tid: "2", page: "1", filter: false, extend: [:]))
    let item = try #require((page["list"] as? [[String: Any]])?.first)
    #expect(item["vod_id"] as? String == "243253")
    #expect(item["vod_remarks"] as? String == "别名", "subTitle when remarks is absent")
    #expect(page["pagecount"] as? Int == 4103, "the API's own total, 20 a page")
    #expect(signed(try #require(ShortDramaSite.requests(to: "/api/app/categories/2/videos").last),
                   path: "/api/app/categories/2/videos", query: "page=1&page_size=20"))

    let detail = try #require((try json(try await feiyu.detailContent(ids: ["243253"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "高清qq$$$暴风资源$$$极速资源站jsm3u8$$$lzm3u8",
            "best quality first; equal ranks keep the API's order; a nameless line shows its code")
    #expect(detail["vod_play_url"] as? String == "第1集$https://jx.invalid/api/?url=||https://v.qq.com/x/1.html"
            + "$$$第1集$||https://b.invalid/1.m3u8#第2集$||https://b.invalid/2.m3u8$$$高清版$||https://a.invalid/1.m3u8$$$TC$||https://l.invalid/1.m3u8")
    #expect(detail["type_name"] as? String == "电影")
    #expect(detail["vod_director"] as? String == "乙")

    let direct = try json(try await feiyu.playerContent(flag: "暴风资源", id: "||https://b.invalid/1.m3u8", vipFlags: []))
    #expect(direct["parse"] as? Int == 0)
    #expect(direct["url"] as? String == "https://b.invalid/1.m3u8")
    #expect((direct["header"] as? [String: String])?["User-Agent"] == "Dart/3.10 (dart:io)")
    let parsed = try json(try await feiyu.playerContent(flag: "高清qq", id: "https://jx.invalid/api/?url=||https://v.qq.com/x/1.html", vipFlags: []))
    #expect(parsed["parse"] as? Int == 0)
    #expect(parsed["url"] as? String == "https://real.invalid/x.m3u8")
    #expect(ShortDramaSite.requests(to: "/api").last?.headers["User-Agent"] == "Mozilla/5.0")
    // An expired parse account answers a relative error clip: not an address, so the sniffer gets the page.
    let expired = try json(try await feiyu.playerContent(flag: "高清qq", id: "https://jx.invalid/api/?url=||https://v.qq.com/x/1.html", vipFlags: []))
    #expect(expired["parse"] as? Int == 1)
    #expect(expired["url"] as? String == "https://jx.invalid/api/?url=https://v.qq.com/x/1.html")

    let search = try json(try await feiyu.searchContent(key: "蜘蛛侠", quick: false, page: "2"))
    #expect((search["list"] as? [[String: Any]])?.first?["vod_name"] as? String == "甲")
    #expect(search["pagecount"] as? Int == 6)
    let asked = try #require(ShortDramaSite.requests(to: "/api/app/videos/search").last)
    #expect(asked.url.absoluteString.contains("keyword=%E8%9C%98%E8%9B%9B%E4%BE%A0"), "the URL carries the keyword encoded")
    #expect(signed(asked, path: "/api/app/videos/search", query: "keyword=蜘蛛侠&page=2&page_size=20"),
            "while the signature is over the raw value")
    await feiyu.destroy()
}

@Test func miaoWuFindsItsHostOverDoHDecryptsRepliesAndParsesMwvodFiles() async throws {
    let key = "c55c019c59a9fbe196ef9fc7d2a0b351"
    func sealed(_ plain: String) -> String {
        #"{"code":1,"data":""# + CryptoHost.run(algorithm: "aes", encrypt: true, input: plain, key: key, iv: "",
                                                mode: "ECB", inputEncoding: "base64") + #""}"#
    }
    let api = "app.nyafun.vip/app/api/"
    ShortDramaSite.serve([
        // The TXT record as `doh.pub` served it on 2026-10-06: AES-256-ECB of `http://app.nyafun.vip`.
        "doh.pub/resolve": [#"{"Status":0,"Answer":[{"name":"doh.catw.moe.","type":16,"data":"\"cRpC1XpSNFAKsda+MqmZfwJgfYG9/auk+4NBUjyREIc=\""}]}"#],
        api + "config": [sealed(#"""
        {"ac_vod_type":[{"type_id":1,"type_name":"番剧","type_extend":{"class":"搞笑, 运动,","year":"2026,2025"}},
                        {"type_id":22,"type_name":"连载新番","type_extend":{"class":"","year":""}},
                        {"type_id":26,"type_name":"4K专区","type_extend":{"class":"","year":"PC请使用谷歌内核的浏览器(如Edge)观看"}}]}
        """#)],
        api + "content/filter": [sealed(#"""
        {"filter_vods":[{"id":33942,"vod_name":"殿下","vod_pic":"https://p.invalid/1.jpg","vod_remarks":"更新至第04集"},
                        {"id":null,"vod_name":"无编号"},{"id":5,"vod_name":"  "}]}
        """#)],
        api + "vod/33942": [sealed(#"""
        {"vod_name":"殿下","vod_pic":"https://p.invalid/1.jpg","vod_year":2026,"vod_content":"<p>簡介</p>","vod_author":"甲",
         "vod_class":"日漫","vod_remarks":"更新至第04集","playerData":[
          {"name":"请移步牛番","player":"dyttm3u8","vids":["第01集$https://d.invalid/1/index.m3u8","https://d.invalid/2/index.m3u8"]},
          {"name":"请移步牛番","player":"R2","vids":["第01集$https://anime.mwvod.xyz:65534/4k/a/08.mp4"]},
          {"name":"","player":"x","vids":[]}]}
        """#)],
        api + "vod/parse": [sealed(#"{"play_url":"https://r2.invalid/08.mp4?X-Amz-Signature=1"}"#)],
        api + "search/full": [sealed(#"{"search_full":[{"id":11942,"vod_name":"斗罗大陆","vod_pic":"https://p.invalid/2.jpg"}]}"#)],
    ])
    // A configured host is replaced by the one DoH publishes, as in the original `init`.
    let miaowu = try await spider("MiaoWu", extend: "https://ext.invalid")

    let home = try json(try await miaowu.homeContent(filter: true))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_id"] ?? "" } == ["1", "22", "26"])
    let rows = try #require((home["filters"] as? [String: Any])?["1"] as? [[String: Any]])
    #expect(rows.map { $0["key"] as? String ?? "" } == ["class", "year"])
    #expect((rows[0]["value"] as? [[String: String]])?.map { $0["n"] ?? "" } == ["全部", "搞笑", "运动"])
    #expect((home["filters"] as? [String: Any])?["26"] == nil, "a notice in a filter slot is not a filter")
    let config = try #require(ShortDramaSite.requests(to: "/app/api/config").last)
    #expect(config.url.absoluteString == "http://app.nyafun.vip/app/api/config?platform=android", "the host came from DoH")
    #expect(config.headers["User-Agent"] == "Dart/3.5 (dart:io)")

    let page = try json(try await miaowu.categoryContent(tid: "1", page: "1", filter: true, extend: ["class": "搞笑", "year": "2026"]))
    #expect((page["list"] as? [[String: Any]])?.map { $0["vod_id"] as? String ?? "" } == ["33942"], "no id or no name: skipped")
    #expect(page["pagecount"] as? Int == 1, "a page short of 12 is the last")
    let listing = try #require(ShortDramaSite.requests(to: "/app/api/content/filter").last)
    let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: listing.url, resolvingAgainstBaseURL: false)?
        .queryItems).map { ($0.name, $0.value ?? "") })
    #expect(query == ["page": "1", "sort": "0", "type": "1", "class": "搞笑", "year": "2026"])

    let detail = try #require((try json(try await miaowu.detailContent(ids: ["33942"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "请移步牛番$$$请移步牛番 R2", "a repeated line name gets its player code")
    #expect(detail["vod_play_url"] as? String == "第01集$https://d.invalid/1/index.m3u8|||dyttm3u8#第2集$https://d.invalid/2/index.m3u8|||dyttm3u8"
            + "$$$第01集$https://anime.mwvod.xyz:65534/4k/a/08.mp4|||R2")
    #expect(detail["vod_actor"] as? String == "甲")
    #expect(detail["vod_year"] as? String == "2026")

    let direct = try json(try await miaowu.playerContent(flag: "请移步牛番", id: "https://d.invalid/1/index.m3u8|||dyttm3u8", vipFlags: []))
    #expect(direct["url"] as? String == "https://d.invalid/1/index.m3u8")
    #expect((direct["header"] as? [String: String])?["User-Agent"] == "Dart/3.5 (dart:io)")
    #expect(ShortDramaSite.requests(to: "/app/api/vod/parse").isEmpty, "a plain file address needs no parse")

    let parsed = try json(try await miaowu.playerContent(flag: "请移步牛番 R2", id: "https://anime.mwvod.xyz:65534/4k/a/08.mp4|||R2", vipFlags: []))
    #expect(parsed["parse"] as? Int == 0)
    #expect(parsed["url"] as? String == "https://r2.invalid/08.mp4?X-Amz-Signature=1")
    let parse = try #require(ShortDramaSite.requests(to: "/app/api/vod/parse").last)
    #expect(try json(parse.body) as NSDictionary == ["vid": "https://anime.mwvod.xyz:65534/4k/a/08.mp4", "player": "R2"])

    let search = try json(try await miaowu.searchContent(key: "斗罗", quick: false, page: "1"))
    #expect((search["list"] as? [[String: Any]])?.first?["vod_id"] as? String == "11942")
    #expect(ShortDramaSite.requests(to: "/resolve").count >= 1)
    await miaowu.destroy()
}

@Test func appYQKSignsEveryPostAndOffersOnlyTheQualitiesTheWebAPIServes() async throws {
    let api = "yzy0916.n0z6fkpuk.com"
    func ok(_ data: String) -> String { #"{"result":true,"msg":"","data":"# + data + "}" }
    ShortDramaSite.serve([
        api + "/v2/api/home/header": [ok(#"{"channeList":[{"channelId":50,"channelName":"短剧"},{"channelId":2,"channelName":"电影"},{"channelId":5,"channelName":"体育"}]}"#)],
        api + "/v2/api/channel/topicListView": [ok(#"""
        {"topicList":[{"topicName":"院线","vodList":[{"vodId":1,"vodName":"甲","coverImg":"https://p.invalid/1.jpg","remark":"已完结"},
                                                     {"vodId":2,"vodName":"乙","coverImg":"https://p.invalid/2.jpg","remark":null}]},
                      {"topicName":"高分","vodList":[{"vodId":1,"vodName":"甲","coverImg":"https://p.invalid/1.jpg","remark":"已完结"}]}]}
        """#)],
        api + "/v2/api/vodInfo/index": [ok(#"""
        {"vodName":"甲-8月31日-HD高清","areaName":"大陆","year":"2026","updateRemark":"已完结","coverImg":"https://p.invalid/1.jpg",
         "intro":"簡介","tagList":["剧情","战争"],"actorList":[{"vodWorkerName":"沈腾"},{"vodWorkerName":"蒋奇明"}],
         "directorList":[{"vodWorkerName":"文牧野"}],"playerList":[
          {"playerName":"一起看APP","totalEpCount":"1","epList":[{"epId":27069484,"epName":"HD"}]},
          {"playerName":"SD","totalEpCount":"2","epList":[{"epId":11,"epName":"第1集"},{"epId":12,"epName":"第2集"}]}]}
        """#)],
        api + "/v2/api/vodInfo/epDetail": [ok(#"""
        [{"showName":"超清","vodResolution":3,"canPlay":false,"iconRemark":"APP独享"},
         {"showName":"标清","vodResolution":2,"canPlay":true,"iconRemark":""}]
        """#)],
        api + "/v2/api/vodInfo/playUrl": [ok(#"{"playUrl":"https://m.invalid/720/master.m3u8?sign=1"}"#)],
        api + "/v1/api/search/search": [
            ok(#"{"hasNext":true,"nextVal":"[1,2,3]","items":[{"vodId":7,"vodName":"蜘蛛侠","coverImg":"https://p.invalid/7.jpg","flags":"2021 / 动作片"},{"vodId":8,"vodName":"短","flags":"2025 / 短剧"}]}"#),
            ok(#"{"hasNext":false,"nextVal":"","items":[{"vodId":9,"vodName":"蜘蛛侠2","coverImg":"https://p.invalid/9.jpg","flags":"2004 / 动作片"}]}"#)],
    ])
    let yqk = try await spider("AppYQK")
    /// The body's fields in order, minus `sign`, then `appKey`, md5'd — and the order must be the original's.
    func signedBody(_ path: String) throws -> [String: Any] {
        let asked = try #require(ShortDramaSite.requests(to: path).last)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(asked.body.utf8)) as? [String: Any])
        let keys = fields.keys.filter { $0 != "sign" }.sorted()
        let text = keys.map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: "&") + "&appKey=3359de478f8d45638125e446a10ec541"
        #expect(fields["sign"] as? String == md5(text), "\(path) is signed over its sorted fields")
        #expect(asked.body.range(of: #""sign":"[0-9a-f]{32}"\}$"#, options: .regularExpression) != nil, "sign comes last")
        #expect(asked.headers["Referer"] == "https://yqk1.app/")
        #expect((fields["udid"] as? String)?.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
        #expect((fields["requestId"] as? String)?.range(of: "^[0-9A-Za-z]{32}$", options: .regularExpression) != nil)
        return fields
    }

    let home = try json(try await yqk.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_name"] ?? "" } == ["电影"], "短剧 and 体育 are skipped")
    _ = try signedBody("/v2/api/home/header")

    let page = try json(try await yqk.categoryContent(tid: "2", page: "1", filter: false, extend: [:]))
    #expect((page["list"] as? [[String: Any]])?.map { $0["vod_id"] as? String ?? "" } == ["1", "2"], "a title in two topics shows once")
    #expect((page["list"] as? [[String: Any]])?.last?["vod_remarks"] as? String == "")
    #expect(page["pagecount"] as? Int == 1)
    #expect(try signedBody("/v2/api/channel/topicListView")["channelId"] as? String == "2")

    let detail = try #require((try json(try await yqk.detailContent(ids: ["441826"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "一起看APP$$$SD", "no episode count in the label")
    #expect(detail["vod_play_url"] as? String == "HD$27069484$$$第1集$11#第2集$12")
    #expect(detail["vod_actor"] as? String == "沈腾 蒋奇明")
    #expect(detail["vod_director"] as? String == "文牧野")
    #expect(detail["type_name"] as? String == "剧情,战争")

    let play = try json(try await yqk.playerContent(flag: "一起看APP", id: "27069484", vipFlags: []))
    #expect(play["parse"] as? Int == 0)
    #expect(play["url"] as? [String] == ["标清", "https://m.invalid/720/master.m3u8?sign=1"], "超清 is APP-only and never requested")
    #expect((play["header"] as? [String: String])?["Origin"] == "https://yqk1.app")
    #expect(ShortDramaSite.requests(to: "/v2/api/vodInfo/playUrl").count == 1)
    let quality = try signedBody("/v2/api/vodInfo/playUrl")
    #expect(quality["epId"] as? String == "27069484")
    #expect(quality["vodResolution"] as? String == "2")

    let first = try json(try await yqk.searchContent(key: "蜘蛛侠", quick: false, page: "1"))
    #expect((first["list"] as? [[String: Any]])?.map { $0["vod_id"] as? String ?? "" } == ["7"], "短剧 results are dropped")
    #expect(first["pagecount"] as? Int == 2)
    #expect(try signedBody("/v1/api/search/search")["nextVal"] == nil)
    let second = try json(try await yqk.searchContent(key: "蜘蛛侠", quick: false, page: "2"))
    #expect((second["list"] as? [[String: Any]])?.first?["vod_id"] as? String == "9")
    #expect(try signedBody("/v1/api/search/search")["nextVal"] as? String == "[1,2,3]", "page 2 sends page 1's cursor")
    await yqk.destroy()
}

@Test func appYsV2SpeaksTheVodDialectFiltersAndHandsPagesToTheSniffer() async throws {
    let api = "nn.invalid/api.php/v1.vod"
    ShortDramaSite.serve([
        api + "/types": [#"""
        {"code":1,"data":{"list":[{"type_id":22,"type_name":"电影","type_extend":{"class":"喜剧, 爱情,伦理,","area":"大陆,香港","star":"甲","year":"2026"}},
                                  {"type_id":9,"type_name":"伦理","type_extend":{}}]}}
        """#],
        api: [#"{"code":1,"data":{"total":37,"page":1,"limit":18,"list":[{"vod_id":112442,"vod_name":"蜘蛛侠","vod_pic":"https://p.invalid/1.jpg","vod_remarks":"HD"}]}}"#],
        api + "/vodPhbAll": [#"{"code":1,"data":[{"name":"热","vod_list":[{"vod_id":1,"vod_name":"甲"},{"vod_id":2,"vod_name":"乙"}]},{"name":"新","vod_list":[{"vod_id":1,"vod_name":"甲"}]}]}"#],
        api + "/detail": [#"""
        {"code":1,"data":{"vod_id":112442,"vod_name":"蜘蛛侠","vod_pic":"https://p.invalid/1.jpg","vod_class":"动作","vod_year":"2026",
          "vod_area":"美国","vod_remarks":"HD","vod_actor":"甲","vod_director":"乙","vod_content":"簡介",
          "vod_url_with_player":[{"code":"wrong","url":"x$y"}],
          "vod_play_list":[{"player_info":{"from":"jazsjzlp_1080p","show":"SRBJ","parse":""},"url":"蓝光$https://jaz.invalid/vod/play/1?quality=1080"},
                           {"player_info":{"from":"","show":"DT","parse":""},"url":"HD$https://d.invalid/1/index.m3u8#TC$https://d.invalid/2/index.m3u8"}]}}
        """#],
    ])
    let nunu = try await spider("AppYsV2", extend: "https://nn.invalid/api.php/v1.vod")

    let home = try json(try await nunu.homeContent(filter: true))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_name"] ?? "" } == ["电影"], "伦理 is hidden")
    let rows = try #require((home["filters"] as? [String: Any])?["22"] as? [[String: Any]])
    #expect(rows.map { $0["key"] as? String ?? "" } == ["class", "area", "year", "排序"], "the type's own order; star is not a filter")
    #expect((rows[0]["value"] as? [[String: String]])?.map { $0["n"] ?? "" } == ["全部", "喜剧", "爱情"], "trimmed, 伦理 and the trailing empty dropped")
    #expect((rows[3]["value"] as? [[String: String]])?.map { $0["v"] ?? "" } == ["", "time", "hits", "score"])
    #expect((try json(try await nunu.homeVideoContent())["list"] as? [[String: Any]])?.map { $0["vod_id"] as? String ?? "" } == ["1", "2"])

    let page = try json(try await nunu.categoryContent(tid: "22", page: "1", filter: true, extend: ["class": "喜剧", "year": "2026", "排序": "hits"]))
    #expect(page["pagecount"] as? Int == 3, "data.total over data.limit")
    let listing = try #require(ShortDramaSite.requests(to: "/api.php/v1.vod").last)
    let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: listing.url, resolvingAgainstBaseURL: false)?
        .queryItems).map { ($0.name, $0.value ?? "") })
    #expect(query == ["type": "22", "class": "喜剧", "area": "", "lang": "", "year": "2026", "by": "hits", "limit": "18", "page": "1"])
    #expect(listing.headers["User-Agent"] == "okhttp/4.1.0")

    let detail = try #require((try json(try await nunu.detailContent(ids: ["112442"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "jazsjzlp_1080p$$$DT", "`from`, else `show`; never the api.php/app fields")
    #expect(detail["vod_play_url"] as? String == "蓝光$https://jaz.invalid/vod/play/1?quality=1080$$$HD$https://d.invalid/1/index.m3u8#TC$https://d.invalid/2/index.m3u8")
    #expect(detail["type_name"] as? String == "动作")

    let direct = try json(try await nunu.playerContent(flag: "DT", id: "https://d.invalid/1/index.m3u8", vipFlags: []))
    #expect(direct["parse"] as? Int == 0)
    #expect((direct["header"] as? [String: String])?["User-Agent"] == "okhttp/4.1.0")
    let pageLine = try json(try await nunu.playerContent(flag: "jazsjzlp_1080p", id: "https://jaz.invalid/vod/play/1?quality=1080", vipFlags: []))
    #expect(pageLine["parse"] as? Int == 1, "a play page goes to the sniffer")

    _ = try await nunu.searchContent(key: "蜘蛛侠", quick: false, page: "1")
    let search = try #require(ShortDramaSite.requests(to: "/api.php/v1.vod").last?.url.query)
    #expect(search.hasPrefix("wd=") && search.hasSuffix("&page=1"))
    await nunu.destroy()

    // Only the `.vod` dialect is ported: any other `ext` answers nothing rather than guessing.
    let other = try await spider("AppYsV2", extend: "https://x.invalid/api.php/app/")
    #expect((try json(try await other.homeContent(filter: true))["class"] as? [Any])?.isEmpty == true)
    await other.destroy()
}

@Test func guaziTYKeepsLiveAndUpcomingMatchesAndTellsAnEmptyDayFromABrokenReply() async throws {
    let key = "KANGEQIU@8868!~.", iv = "0200010900030207"
    func sealed(_ plain: String) -> String {
        #"{"code":200,"name":"操作成功","data":""# + CryptoHost.run(algorithm: "aes", encrypt: true, input: plain, key: key,
                                                               iv: iv, mode: "CBC", inputEncoding: "base64") + #""}"#
    }
    let now = Int(Date().timeIntervalSince1970)
    func match(_ mid: Int, _ start: Int, _ status: Int, _ info: String, _ home: Int, _ away: Int) -> String {
        #"{"mid":\#(mid),"match_time":\#(start),"m_status":\#(status),"match_status_info":"\#(info)","event_name":"NBA","#
            + #""home":{"name":"国王","logo":"https://l.invalid/h.png","score":\#(home)},"visiting":{"name":"湖人","score":\#(away)}}"#
    }
    let api = "api.46d5umpk.com/gz/live/"
    ShortDramaSite.serve([
        api + "sports": [
            sealed("[" + [match(1, now - 600, 1, "第二节", 28, 40), match(2, now + 3600, 0, "未开赛", 0, 0),
                          match(3, now - 7200, 2, "完", 99, 98), match(4, now - 90_000, 1, "第四节", 1, 1)].joined(separator: ",") + "]"),
            sealed("[]"),
            #"{"code":200,"data":"not a cipher at all"}"#],
        api + "detail": [sealed(#"""
        {"mid":1,"match_status_info":"第二节","home":{"name":"国王","logo":"https://l.invalid/h.png","score":28},"visiting":{"name":"湖人","score":40},
         "live_line":[{"name":"中文解说","m3u8":"https://live.invalid/zh.m3u8?auth_key=1"},{"name":"赛场原声","m3u8":"https://live.invalid/sd.m3u8?auth_key=2"}]}
        """#)],
    ])
    let guazi = try await spider("GuaziTY")

    let home = try json(try await guazi.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_id"] ?? "" } == ["hot", "nba", "football", "basketball"])

    let page = try json(try await guazi.categoryContent(tid: "nba", page: "1", filter: false, extend: [:]))
    let list = try #require(page["list"] as? [[String: Any]])
    #expect(list.map { $0["vod_id"] as? String ?? "" } == ["1", "2"], "finished, and older than a day, are dropped")
    #expect(page["pagecount"] as? Int == 1)
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    #expect(list[0]["vod_remarks"] as? String == "NBA \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(now - 600)))) 第二节 比分28-40")
    #expect(list[1]["vod_remarks"] as? String == "NBA \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(now + 3600)))) 未开赛")
    #expect(list[0]["vod_name"] as? String == "国王 vs 湖人")
    // The form's `parameter` is the cipher Java's AES/CBC/PKCS5Padding gives — computed with openssl.
    func parameter(_ asked: ShortDramaSite.Asked) -> String? {
        URLComponents(string: "?" + asked.body)?.queryItems?.first(where: { $0.name == "parameter" })?.value
    }
    let asked = try #require(ShortDramaSite.requests(to: "/gz/live/sports").last)
    #expect(parameter(asked) == "LJ6JyZxcMKdqnJ7tXLMN9LMWgliVRIP+YHbzq0tOCT810RC0vVQlohKlwvOhUkzk", "the nba query")
    #expect(asked.headers["client-version"] == "3.0.1.1")

    // A day with no match is an empty list; a reply that does not decrypt is an error, not "no matches".
    let quiet = try json(try await guazi.categoryContent(tid: "hot", page: "1", filter: false, extend: [:]))
    #expect((quiet["list"] as? [Any])?.isEmpty == true)
    await #expect(throws: (any Error).self) {
        _ = try await guazi.categoryContent(tid: "football", page: "1", filter: false, extend: [:])
    }
    let second = try json(try await guazi.categoryContent(tid: "nba", page: "2", filter: false, extend: [:]))
    #expect((second["list"] as? [Any])?.isEmpty == true, "the API has no second page")

    let detail = try #require((try json(try await guazi.detailContent(ids: ["1"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == " 瓜子 ")
    #expect(detail["vod_play_url"] as? String == "中文解说$https://live.invalid/zh.m3u8?auth_key=1#赛场原声$https://live.invalid/sd.m3u8?auth_key=2")
    #expect(detail["vod_remarks"] as? String == "第二节 比分28-40")
    #expect(parameter(try #require(ShortDramaSite.requests(to: "/gz/live/detail").last)) == "rpOBIqfI2rVCw3Hz/cpn6Q==",
            #"AES-CBC of {"mid":"1"}"#)

    let play = try json(try await guazi.playerContent(flag: " 瓜子 ", id: "https://live.invalid/zh.m3u8?auth_key=1", vipFlags: []))
    #expect(play["parse"] as? Int == 0)
    #expect((play["header"] as? [String: String])?["User-Agent"] == "Lavf/57.83.100")
    #expect((play["header"] as? [String: String])?["Referer"] == "http://WJiZxLXA2.com/")
    #expect((try json(try await guazi.searchContent(key: "湖人", quick: false, page: "1"))["list"] as? [Any])?.isEmpty == true)
    await guazi.destroy()
}

@Test func moDuReadsTheCMSListingsWithTheOriginalsPagingFloors() async throws {
    let api = "www.mdzyapi.com/api.php/provide/vod"
    ShortDramaSite.serve([
        api: [#"""
        {"code":1,"page":"1","pagecount":130,"limit":"20","total":2599,"list":[
          {"vod_id":8692,"vod_name":" 吞噬星空 ","vod_pic":"https://p.invalid/1.jpg","vod_remarks":"更新至244集"},
          {"vod_id":"","vod_name":"无编号"},{"vod_id":5,"vod_name":"  "}]}
        """#, #"""
        {"code":1,"list":[{"vod_id":8692,"vod_name":"吞噬星空","vod_pic":"https://p.invalid/1.jpg","vod_year":"2020","vod_area":"大陆",
          "vod_actor":"赵乾景","vod_director":"沈乐平","vod_content":"<p>簡介</p>","vod_remarks":"更新至244集","type_name":"国产动漫",
          "vod_play_from":"","vod_play_url":"第01集$https://m.invalid/1/index.m3u8#第02集$https://m.invalid/2/index.m3u8"}]}
        """#, #"{"code":1,"list":[{"vod_id":7656,"vod_name":"斗罗大陆"}]}"#],
    ])
    let modu = try await spider("MoDu")

    let home = try json(try await modu.homeContent(filter: false))
    #expect((home["class"] as? [[String: String]])?.map { $0["type_name"] ?? "" } == ["国产动漫", "日韩动漫", "欧美动漫", "港台动漫", "动漫电影"])

    let page = try json(try await modu.categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
    #expect((page["list"] as? [[String: Any]])?.map { $0["vod_name"] as? String ?? "" } == ["吞噬星空"], "trimmed; no id or no name is skipped")
    #expect(page["pagecount"] as? Int == 130)
    #expect(page["limit"] as? Int == 20, "a numeric string, as org.json's optInt reads it")
    #expect(page["total"] as? Int == 2599)
    #expect(ShortDramaSite.requests(to: "/api.php/provide/vod").last?.url.query == "ac=detail&t=1&pg=1")

    let detail = try #require((try json(try await modu.detailContent(ids: ["8692"]))["list"] as? [[String: Any]])?.first)
    #expect(detail["vod_play_from"] as? String == "播放", "an unnamed line is named 播放")
    #expect(detail["vod_play_url"] as? String == "第01集$https://m.invalid/1/index.m3u8#第02集$https://m.invalid/2/index.m3u8")
    #expect(detail["vod_director"] as? String == "沈乐平")
    #expect(detail["type_name"] as? String == "国产动漫")

    let search = try json(try await modu.searchContent(key: "斗罗", quick: false, page: "1"))
    #expect((search["list"] as? [[String: Any]])?.first?["vod_id"] as? String == "7656")
    #expect(search["pagecount"] as? Int == 10, "the original's search fallback when the API sends none")
    #expect(ShortDramaSite.requests(to: "/api.php/provide/vod").last?.url.query?.hasPrefix("ac=detail&pg=1&wd=") == true)

    let play = try json(try await modu.playerContent(flag: "modum3u8", id: " https://m.invalid/1/index.m3u8 ", vipFlags: []))
    #expect(play["url"] as? String == "https://m.invalid/1/index.m3u8")
    #expect((play["header"] as? [String: String])?["User-Agent"]?.hasPrefix("Mozilla/5.0") == true)
    await modu.destroy()
}
