import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-44A: `WeiguanDJ.js` and `HemaDJ.js` against canned replies shaped like the live APIs'
// (docs/IOS-POC-44-csp-portable-sites.md). Both classes hard-code their host, so the stub answers
// those two hosts — only inside the session these tests build, never process-wide.

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
        ["api.drama.9ddm.com", "freevideo.zqqds.cn"].contains(request.url?.host ?? "")
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
