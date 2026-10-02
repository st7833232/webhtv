import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-44A/44B: the short-drama ports against canned replies shaped like the live APIs'
// (docs/IOS-POC-44-csp-portable-sites.md). Every class hard-codes its hosts, so the stub answers
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
        ["api.drama.9ddm.com", "freevideo.zqqds.cn", "neptune.qmplaylet.com", "api-store.qmplaylet.com",
         "api-read.qmplaylet.com", "sv.baidu.com"].contains(request.url?.host ?? "")
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

private func spider(_ name: String) async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ShortDramaSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: name, script: try #require(registry.entry(for: "csp_\(name)")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "\(name)-test", defaults: UserDefaults(suiteName: "\(name)-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: "")
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
