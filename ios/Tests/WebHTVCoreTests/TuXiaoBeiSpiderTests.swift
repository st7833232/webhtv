import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

/// Answers only the exact URLs a test routes, so a wrong query never gets a fixture (TXB-07).
final class TuXiaoBeiMockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (Data, Int)] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
        recorded.removeAll()
    }

    static func route(_ url: String, _ body: String, status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        routes[url] = (Data(body.utf8), status)
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.tuxiaobei.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let matched = Self.routes[request.url?.absoluteString ?? ""]
        Self.lock.unlock()
        guard let (data, status) = matched else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let base = "https://www.tuxiaobei.com/"
private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
private let referer = "https://www.tuxiaobei.com/"
private func listURL(_ type: String, _ page: Int) -> String { "\(base)list/mip-data?typeId=\(type)&page=\(page)&callback=jsonp" }

private struct FixtureMismatch: Error {}

/// Live pages saved on 2026-10-08 (docs/IOS-POC-57B-2-tu-xiao-bei.md), stored raw-deflated and
/// base64-encoded; the SHA-256 of the inflated bytes is the one recorded when they were fetched.
private func fixture(_ sha256: String, _ base64: String) throws -> String {
    guard let packed = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { throw FixtureMismatch() }
    let data = try (packed as NSData).decompressed(using: .zlib) as Data
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw FixtureMismatch() }
    return String(decoding: data, as: UTF8.self)
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

/// The JAR's constants (TuXiaoBei.java:21, :24), in order.
private let categories = [("2", "大类·儿歌"), ("3", "大类·故事"), ("4", "大类·国学"), ("25", "大类·启蒙")]
private let subjects = [
    ("17", "兔小贝原创儿歌"), ("16", "睡前儿歌"), ("1", "Everybody动起来"), ("2", "爸爸妈妈小时候的儿歌"), ("3", "宝宝吃饭香"),
    ("4", "乖宝宝不哭闹"), ("5", "好宝宝爱上学"), ("6", "欢快儿歌"), ("9", "经典儿歌"), ("10", "快乐的节日"),
    ("11", "快乐的童年"), ("12", "流行儿歌"), ("13", "美丽四季"), ("14", "男孩最爱"), ("15", "女孩最爱"),
    ("19", "我爱爸爸妈妈"), ("20", "我的动物朋友"), ("21", "我的祖国和我"), ("22", "舞蹈音乐"), ("23", "英文儿歌"),
    ("24", "粤语儿歌"), ("25", "早教好习惯"), ("56", "放暑假啦"), ("57", "我能照顾好自己"), ("58", "画一个梦"),
    ("59", "哆啦A梦的神奇口袋"), ("60", "你是我的小天使"), ("61", "最动听的笑声"), ("62", "许个愿吧"), ("63", "阳光下的我们"),
    ("89", "智慧成语故事"), ("90", "名人成语故事"), ("88", "励志成语故事"), ("87", "神话成语故事"), ("39", "古诗启蒙"),
    ("43", "三字经"), ("46", "弟子规"), ("48", "千字文"), ("54", "十万个为什么"), ("55", "神奇的大自然"),
    ("50", "英语宝典"), ("51", "数学课堂"), ("53", "动物奇缘"), ("84", "安全教育"),
]

@Suite(.serialized)
struct TuXiaoBeiSpiderTests {
    private func runtime() async throws -> JavaScriptSpiderRuntime {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TuXiaoBeiMockProtocol.self]
        let registry = SpiderRegistry.bundled(bundle: .repoSpiders)
        let entry = try #require(registry.entry(for: "csp_TuXiaoBei"))
        let runtime = try JavaScriptSpiderRuntime(
            name: "TuXiaoBei", script: entry.script, prelude: registry.prelude,
            storage: SpiderStorage(siteKey: "TuXiaoBei-test", defaults: UserDefaults(suiteName: "TuXiaoBei-test")!),
            session: URLSession(configuration: config))
        try await runtime.initialize(extend: "")
        return runtime
    }

    private func category(_ spider: JavaScriptSpiderRuntime, _ tid: String, _ page: String) async throws -> [String: Any] {
        try object(try await spider.categoryContent(tid: tid, page: page, filter: false, extend: [:]))
    }

    /// Every request carries the mobile UA and the site's Referer, word for word (TXB-04).
    private func expectMobileHeaders() {
        for request in TuXiaoBeiMockProtocol.requests() {
            #expect(request.value(forHTTPHeaderField: "User-Agent") == mobileUA)
            #expect(request.value(forHTTPHeaderField: "Referer") == referer)
        }
    }

    @Test func theRegistryDrivesTuXiaoBei() {
        #expect(SpiderRegistry.bundled(bundle: .repoSpiders).canDrive("csp_TuXiaoBei"))
    }

    @Test func homeDeclaresTheFourCategoriesAndFortyFourSubjects() async throws {
        TuXiaoBeiMockProtocol.reset()
        let classes = try #require(try object(try await runtime().homeContent(filter: false))["class"] as? [[String: String]])
        let expected = categories.map { ["type_id": "api_\($0.0)", "type_name": $0.1] }
            + subjects.map { ["type_id": "sub_\($0.0)", "type_name": $0.1] }
        #expect(classes.count == 48)
        #expect(classes == expected)
        #expect(TuXiaoBeiMockProtocol.requests().isEmpty)
    }

    @Test func aCategoryReadsTheJSONPListWithAnIntegerPage() async throws {
        TuXiaoBeiMockProtocol.reset()
        let api2 = try fixture("8e99a1722c835dd1c98c1f2441faee57596fb009786dd76b2e966579a12a39a4", api2Page1)
        TuXiaoBeiMockProtocol.route(listURL("2", 1), api2)
        TuXiaoBeiMockProtocol.route(listURL("2", 2), api2)
        let spider = try await runtime()

        let first = try await category(spider, "api_2", "1")
        let items = try #require(first["list"] as? [[String: Any]])
        #expect(items.count == 30)
        // list-api2-p1.jsonp.expected.json, with the canonical id in place of upstream's `id|||api_2` (TXB-09).
        let head: [[String: String]] = [
            ["vod_id": "3693", "vod_name": "我们的校车", "vod_pic": "https://resource-cdn.tuxiaobei.com/video/FpUVhp9nz91Ae0gIxfI2ZuUbGqHv.jpg", "vod_remarks": "02:51"],
            ["vod_id": "1037", "vod_name": "数鸭子", "vod_pic": "https://resource-cdn.tuxiaobei.com/video/FrDDFCLCctl4rqDMmkEJz8sNOYts.png", "vod_remarks": "01:22"],
            ["vod_id": "1725", "vod_name": "我上幼儿园", "vod_pic": "https://resource-cdn.tuxiaobei.com/video/Fk5hDxNnpXV1Oy4Hujc90Jmp6OVT.png", "vod_remarks": "02:14"],
        ]
        #expect(items.prefix(3).compactMap { $0 as? [String: String] } == head)
        #expect(first["page"] as? Int == 1 && first["pagecount"] as? Int == 2)

        // "2" is a string from the runtime; the URL and the result use the same integer.
        let second = try await category(spider, "api_2", "2")
        #expect(second["page"] as? Int == 2 && second["pagecount"] as? Int == 3)
        _ = try await category(spider, "api_2", "x")
        #expect(TuXiaoBeiMockProtocol.requests().map { $0.url?.absoluteString } == [listURL("2", 1), listURL("2", 2), listURL("2", 1)])
        expectMobileHeaders()
    }

    @Test func aBrokenOrEmptyListGivesNothingAndSkipsBadItems() async throws {
        TuXiaoBeiMockProtocol.reset()
        let spider = try await runtime()
        // Synthetic, not live: a name holding ");", odd ids, a numeric remark and a protocol-relative image.
        TuXiaoBeiMockProtocol.route(listURL("3", 1), #"""
        jsonp({"status":0,"data":{"items":[
          {"video_id":11,"name":"唱歌);跳舞","image":"//cdn.example/a.jpg","duration_string":"01:00"},
          null, 5, {"video_id":0,"name":"zero"}, {"video_id":"abc","name":"bad"}, {"video_id":-3,"name":"neg"},
          {"name":"no id"}, {"video_id":"12","name":"文字 id","duration_string":"","play_num":34567}
        ]}});
        """#)
        let edge = try await category(spider, "api_3", "1")
        let items = try #require(edge["list"] as? [[String: String]])
        #expect(items == [
            ["vod_id": "11", "vod_name": "唱歌);跳舞", "vod_pic": "https://cdn.example/a.jpg", "vod_remarks": "01:00"],
            ["vod_id": "12", "vod_name": "文字 id", "vod_pic": "", "vod_remarks": "34567"],
        ])

        // Synthetic: each of these is an empty page that stops paging.
        let empties: [(String, String)] = [
            ("4", ""), ("25", "jsonp({broken"), ("4", #"jsonp({"data":null});"#),
            ("25", #"jsonp({"data":{"items":null}})"#), ("4", #"jsonp({"data":{"items":{}}})"#),
        ]
        for (type, body) in empties {
            TuXiaoBeiMockProtocol.route(listURL(type, 1), body)
            let page = try await category(spider, "api_\(type)", "1")
            #expect((page["list"] as? [Any])?.isEmpty == true, "\(body)")
            #expect(page["pagecount"] as? Int == 1)
        }
        // An error page is not read: the adapter answers nothing and the runtime reports the 404.
        TuXiaoBeiMockProtocol.route(listURL("2", 1), #"jsonp({"data":{"items":[{"video_id":1,"name":"error page"}]}})"#, status: 404)
        await #expect(throws: SiteUnreachable(.httpStatus(404), host: "www.tuxiaobei.com")) {
            _ = try await category(spider, "api_2", "1")
        }
    }

    @Test func aSubjectReadsAllItsPrimaryEntriesOnPageOneOnly() async throws {
        TuXiaoBeiMockProtocol.reset()
        TuXiaoBeiMockProtocol.route("\(base)subject/17",
                                    try fixture("e20c2e5713e340e0de56b38f1cbb45755a897e40a0d93d97fee2d43a98bd9ef6", subject17))
        TuXiaoBeiMockProtocol.route("\(base)subject/16", "<p>error</p>", status: 404)
        let spider = try await runtime()

        let page = try await category(spider, "sub_17", "1")
        let items = try #require(page["list"] as? [[String: String]])
        #expect(items.count == 266 && Set(items.map { $0["vod_id"] }).count == 266)
        #expect(items[0] == ["vod_id": "3840", "vod_name": "小闹钟",
                             "vod_pic": "https://resource-cdn.tuxiaobei.com/video/FlhBb795EmKVu9xMqcJPX5qcIEmI.jpg", "vod_remarks": "02:38"])
        #expect(items.last?["vod_id"] == "3817" && items.last?["vod_name"] == "冰淇淋会魔法")
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 1)

        let second = try await category(spider, "sub_17", "2")
        #expect((second["list"] as? [Any])?.isEmpty == true && second["pagecount"] as? Int == 1)
        await #expect(throws: SiteUnreachable(.httpStatus(404), host: "www.tuxiaobei.com")) {
            _ = try await category(spider, "sub_16", "1")
        }
        #expect(TuXiaoBeiMockProtocol.requests().map { $0.url?.absoluteString } == ["\(base)subject/17", "\(base)subject/16"])
        expectMobileHeaders()
    }

    @Test func aSubjectKeepsTheFirstOfEachIdAndFallsBackToBareLinksOnlyWhenEmpty() async throws {
        TuXiaoBeiMockProtocol.reset()
        // Synthetic, not live: the primary pattern twice for one id, then a bare link the primary
        // result must not pick up; and a page with bare links only.
        func entry(_ id: String, _ name: String) -> String {
            #"<a href="/play/\#(id)"><mip-img src="//cdn.example/\#(id).jpg"></mip-img><p class="title">\#(name)</p><span class="time">01:0\#(id)</span></a>"#
        }
        TuXiaoBeiMockProtocol.route("\(base)subject/1", entry("7", "first") + entry("8", "other") + entry("7", "again") + #"<a href="/play/9">x</a>"#)
        TuXiaoBeiMockProtocol.route("\(base)subject/2", #"<a href="/play/5">a</a><a href="/play/6">b</a><a href="/play/5">c</a>"#)
        let spider = try await runtime()

        let primary = try #require(try await category(spider, "sub_1", "1")["list"] as? [[String: String]])
        #expect(primary == [
            ["vod_id": "7", "vod_name": "first", "vod_pic": "https://cdn.example/7.jpg", "vod_remarks": "01:07"],
            ["vod_id": "8", "vod_name": "other", "vod_pic": "https://cdn.example/8.jpg", "vod_remarks": "01:08"],
        ])
        let fallback = try #require(try await category(spider, "sub_2", "1")["list"] as? [[String: String]])
        #expect(fallback == [["vod_id": "5", "vod_name": "视频5", "vod_pic": "", "vod_remarks": ""],
                             ["vod_id": "6", "vod_name": "视频6", "vod_pic": "", "vod_remarks": ""]])
    }

    @Test func detailSearchAndPlayShareOneCanonicalIdAndTheMobileHeaders() async throws {
        TuXiaoBeiMockProtocol.reset()
        let mp4 = "https://resource-cdn.tuxiaobei.com/video/8a/0b/8a0bfeedbda1edea3e5f04b4fbba46ac.mp4"
        TuXiaoBeiMockProtocol.route("\(base)play/2156",
                                    try fixture("c9f759177692ec6a16e0038ec6d20618278b4057a42ad9e2d4c5bb2b775eda82", play2156))
        TuXiaoBeiMockProtocol.route("\(base)search/index?key=%E6%88%91%E6%98%AF%E5%B7%A7%E5%85%8B%E5%8A%9B",
                                    try fixture("fcd9c50d4e2523ee685d4f3d44ea4995db563cc8eadbbfacc527fe4ac8feb6a4", searchQiaokeli))
        TuXiaoBeiMockProtocol.route("\(base)search/index?key=%E5%84%BF%E6%AD%8C",
                                    try fixture("e3a85670ca44643990144479a50aa7ba780e09ea031059d7b4ef98879c321429", searchErge))
        // Synthetic, not live: a title holding the play-list separators.
        TuXiaoBeiMockProtocol.route("\(base)play/77", #"<h1>第1集$特别#版</h1><video video-src="https://resource-cdn.tuxiaobei.com/video/77.mp4">"#)
        TuXiaoBeiMockProtocol.route("\(base)play/78", "gone", status: 404)
        // Synthetic: no <h1> and no mp4, so the name comes from <title> and play resolves the id later.
        TuXiaoBeiMockProtocol.route("\(base)play/79", "<title>小星星-兔小贝_儿歌</title>")
        let spider = try await runtime()

        for id in ["2156", "2156|||sub_17"] {
            let vod = try #require(try list(try await spider.detailContent(ids: [id])).first)
            #expect(vod["vod_id"] as? String == "2156" && vod["vod_name"] as? String == "我是巧克力")
            #expect(vod["vod_pic"] as? String == "https://resource-cdn.tuxiaobei.com/video/web_poster.jpg")
            #expect(vod["vod_play_from"] as? String == "兔小贝" && vod["vod_play_url"] as? String == "我是巧克力$\(mp4)")
        }
        let separators = try #require(try list(try await spider.detailContent(ids: ["77"])).first)
        let episodes = Episode.parse(try #require(separators["vod_play_url"] as? String))
        #expect(episodes.map(\.name) == ["第1集 特别 版"] && episodes.map(\.url) == ["https://resource-cdn.tuxiaobei.com/video/77.mp4"])
        #expect(try list(try await spider.detailContent(ids: ["78"])).isEmpty)
        let untitled = try #require(try list(try await spider.detailContent(ids: ["79"])).first)
        #expect(untitled["vod_name"] as? String == "小星星" && untitled["vod_play_url"] as? String == "小星星$79")

        let found = try list(try await spider.searchContent(key: "我是巧克力", quick: false, page: "1"))
        #expect(found.compactMap { $0 as? [String: String] } == [["vod_id": "2156", "vod_name": "我是巧克力",
            "vod_pic": "https://resource-cdn.tuxiaobei.com/video/Fhvw2gtPyVy3bhFQgdE6D9wk1Kph.png", "vod_remarks": "03:42"]])
        #expect(try list(try await spider.searchContent(key: "儿歌", quick: false, page: "1")).isEmpty)

        let play = try object(try await spider.playerContent(flag: "兔小贝", id: "2156|||api_2", vipFlags: []))
        #expect(play["url"] as? String == mp4 && play["parse"] as? Int == 0)
        #expect(play["header"] as? [String: String] == ["User-Agent": mobileUA, "Referer": referer])
        let direct = try object(try await spider.playerContent(flag: "兔小贝", id: mp4, vipFlags: []))
        #expect(direct["url"] as? String == mp4)
        #expect(TuXiaoBeiMockProtocol.requests().filter { $0.url?.path == "/play/2156" }.count == 3)
        expectMobileHeaders()
    }

    @Test func theSameVideoKeepsOneIdFromACategoryAndASubject() async throws {
        TuXiaoBeiMockProtocol.reset()
        TuXiaoBeiMockProtocol.route(listURL("2", 1), try fixture("8e99a1722c835dd1c98c1f2441faee57596fb009786dd76b2e966579a12a39a4", api2Page1))
        TuXiaoBeiMockProtocol.route("\(base)subject/17",
                                    try fixture("e20c2e5713e340e0de56b38f1cbb45755a897e40a0d93d97fee2d43a98bd9ef6", subject17))
        let spider = try await runtime()
        let fromCategory = try #require(try await category(spider, "api_2", "1")["list"] as? [[String: String]])
        let fromSubject = try #require(try await category(spider, "sub_17", "1")["list"] as? [[String: String]])
        // 我们的校车 (3693) is listed by both; watch history keys on the id, so both must say "3693".
        #expect(fromCategory.first { $0["vod_name"] == "我们的校车" }?["vod_id"] == "3693")
        #expect(fromSubject.contains { $0["vod_id"] == "3693" })
        #expect(!(fromCategory + fromSubject).contains { $0["vod_id"]?.contains("|||") == true })
    }
}

// MARK: - Fixtures (raw DEFLATE, base64)

private let api2Page1 = """
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
MpVLRZyf6CHtTvSYKiOE9RGPhfM8v7t06de/+S8=
"""

private let subject17 = """
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
"""

private let play2156 = """
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
"""

private let searchQiaokeli = """
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
"""

private let searchErge = """
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
"""
