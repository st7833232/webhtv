import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-11 (W-72): SportsKafei.js against the replies kafeizhibo.cc returned on 2026-10-12 (W-49 gate:
// schedule type 1 page 1, room 1007) and hand-made edge replies (W-59 design D5, Manager #1412 per-room cards).

/// Answers kafeizhibo.cc by path (query ignored) and remembers every request.
final class KafeiSite: URLProtocol, @unchecked Sendable {
    struct Seen { let url: URL; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func serve(_ served: [String: (status: Int, body: Data)]) { lock.withLock { replies = served; seen = [] } }
    static func serve(_ served: [String: Data]) { serve(served.mapValues { (200, $0) }) }
    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "kafeizhibo.cc" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append(Seen(url: url, headers: request.allHTTPHeaderFields ?? [:]))
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

private func schedule() throws -> Data { try fixture(schedulePacked, sha256: "7dc029883cda5088c533beb979184b2e67b2ecc8194ef00b7aaf931ff8238b99") }
private func room() throws -> Data { try fixture(roomPacked, sha256: "1a5a8b9fa2d299f9cc388877ec1c20eba36f7d81a1f13d6ac04da57162ee0286") }

private let schedulePath = "/api/v1/schedule"
private let roomPath = "/api/v1/room/1007"
private let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
private let originalSound = "https://pul-tenm.gkykp.com/live/sd-1-4641738.m3u8?txSecret=ae223f25ec515426fe26930d9f1f683c&txTime=6ACDCE08"

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private func match(_ room: Any?, _ home: String, status: String = "upcoming") -> [String: Any] {
    var item: [String: Any] = ["home_team": home, "away_team": "客", "home_team_logo": "https://x/\(home).png",
                               "league_name": "联赛", "status": status]
    if let room { item["archor"] = ["room_id": room] }
    return item
}
private func roomReply(_ signals: [[String: Any]]?) throws -> Data {
    var data: [String: Any] = ["room_info": ["room_id": "1007", "title": "t", "league": "l", "home_team": "甲", "away_team": "乙"]]
    if let signals { data["signals"] = signals }
    return try json(["code": 200, "data": data])
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [KafeiSite.self]
    return URLSession(configuration: configuration)
}

private let suite = "SportsKafei-test"

private func kafei() async throws -> JavaScriptSpiderRuntime {
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "SportsKafei", script: try #require(registry.entry(for: "csp_SportsKafei")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: suite, defaults: UserDefaults(suiteName: suite)!), session: session())
    try await runtime.initialize(extend: "")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}
private func list(_ text: String) throws -> [[String: Any]] { try #require(try object(text)["list"] as? [[String: Any]]) }
private func header(_ seen: KafeiSite.Seen, _ name: String) -> String? {
    seen.headers.first { $0.key.lowercased() == name.lowercased() }?.value
}

@Suite(.serialized) struct SportsKafeiSpiderTests {
    // D5 test 1.
    @Test func homeListsThreeClassesWithoutAsking() async throws {
        KafeiSite.serve([:] as [String: Data])
        let home = try object(try await kafei().homeContent(filter: true))
        #expect((home["class"] as? [[String: String]])?.map { $0["type_id"]! + $0["type_name"]! } == ["hot热门", "1足球", "2篮球"])
        #expect(home["filters"] == nil && KafeiSite.requests.isEmpty)
    }

    // D5 test 2, with one card per room: the gate page's 30 matches are 20 rooms.
    @Test func aCategoryShowsOneCardPerRoomFromTheGateReply() async throws {
        KafeiSite.serve([schedulePath: try schedule()])
        let page = try object(try await kafei().categoryContent(tid: "1", page: "1", filter: false, extend: [:]))
        let request = try #require(KafeiSite.requests.first)
        #expect(KafeiSite.requests.count == 1)
        #expect(request.url.absoluteString == "https://kafeizhibo.cc/api/v1/schedule?type=1&page=1&size=30")
        #expect(header(request, "User-Agent") == agent && header(request, "Accept") == "application/json")
        let items = try #require(page["list"] as? [[String: String]])
        #expect(items.count == 20 && Set(items.map { $0["vod_id"]! }).count == 20)
        #expect(items[0] == ["vod_id": "1007", "vod_name": "埃尔芬埼玉女足 VS 新潟天鹅女足",
                             "vod_pic": "https://cdn.sportnanoapi.com/football/team/9b1119aadf6f76ffbd2a59945a0aab73.png",
                             "vod_remarks": "日本女子联赛杯 直播中"])
        #expect(items[1]["vod_remarks"] == "印班超 直播中" && items[2]["vod_remarks"] == "中乙")
        #expect(items.filter { $0["vod_remarks"]!.hasSuffix(" 直播中") }.count == 2)
        #expect(items.map { $0["vod_id"]! } == ["1007", "1011", "1001", "1002", "1003", "1010", "1012", "1005", "1016", "1004",
                                                 "1006", "1017", "1022", "1023", "1008", "1029", "1009", "1018", "1019", "1020"])
        #expect(page["page"] as? Int == 1 && page["pagecount"] as? Int == 2 && page["limit"] as? Int == 30 && page["total"] as? Int == 20)
    }

    // D5 test 3, plus a numeric room id (upstream's getString reads it) and a room whose live match comes later.
    @Test func aBrokenCategorySkipsOnlyTheBadItemsOrAsksNothing() async throws {
        let spider = try await kafei()
        KafeiSite.serve([schedulePath: try json(["code": 500, "data": [match("1", "甲")]])])
        #expect(try list(try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])).isEmpty)
        KafeiSite.serve([schedulePath: try json(["code": 200, "data": ["a": match("1", "甲")]])])
        #expect(try list(try await spider.categoryContent(tid: "hot", page: "1", filter: false, extend: [:])).isEmpty)

        var noRoom = match(nil, "缺")
        noRoom["archor"] = ["name": "x"]
        KafeiSite.serve([schedulePath: try json(["code": 200, "data": [
            match("9", "甲"), match(nil, "无"), noRoom, match(1099, "数"), match("8", "乙"), match("9", "丙", status: "live"), 7,
        ] as [Any]])])
        let items = try #require(try object(try await spider.categoryContent(tid: "2", page: "0", filter: false, extend: [:]))["list"]
            as? [[String: String]])
        try #require(items.map { $0["vod_id"]! } == ["1099", "8", "9"])
        #expect(items[2]["vod_name"] == "丙 VS 客" && items[2]["vod_remarks"] == "联赛 直播中" && items[1]["vod_remarks"] == "联赛")

        for pg in ["x", "2.5", "-3"] {
            _ = try await spider.categoryContent(tid: "1", page: pg, filter: false, extend: [:])
            #expect(KafeiSite.requests.last?.url.query == "type=1&page=1&size=30", "pg \(pg)")
        }
        KafeiSite.serve([:] as [String: Data])
        #expect(try list(try await spider.categoryContent(tid: "a b", page: "1", filter: false, extend: [:])).isEmpty)
        #expect(KafeiSite.requests.isEmpty)
    }

    // D5 test 4.
    @Test func theDetailListsTheGateRoomsTwoLines() async throws {
        KafeiSite.serve([roomPath: try room()])
        let item = try #require(try list(try await kafei().detailContent(ids: ["1007"])).first as? [String: String])
        #expect(KafeiSite.requests.first?.url.absoluteString == "https://kafeizhibo.cc/api/v1/room/1007")
        #expect(header(try #require(KafeiSite.requests.first), "User-Agent") == agent)
        #expect(item["vod_id"] == "1007" && item["vod_name"] == "日本女子联赛杯 埃尔芬埼玉女足 vs 新潟天鹅女足")
        #expect(item["vod_director"] == "日本女子联赛杯" && item["vod_actor"] == "埃尔芬埼玉女足 VS 新潟天鹅女足")
        #expect(item["vod_play_from"] == "咖啡体育")
        #expect(item["vod_play_url"] == "直播7$https://hello.ooo0ooo.top/live/4641738.m3u8#原声4$" + originalSound)
    }

    // D5 test 5.
    @Test func aBrokenDetailKeepsRtmpAndSkipsWhatCannotPlay() async throws {
        let spider = try await kafei()
        KafeiSite.serve([roomPath: try json(["code": 404])])
        #expect(try list(try await spider.detailContent(ids: ["1007"])).isEmpty)
        KafeiSite.serve([roomPath: try json(["code": 200, "data": ["signals": []]])])
        #expect(try list(try await spider.detailContent(ids: ["1007"])).isEmpty)

        KafeiSite.serve([roomPath: try roomReply([
            ["name": "甲", "stream_url": "rtmp://r.example/live/1"],
            ["name": "乙", "stream_url": "ftp://f.example/1"],
            ["name": "丙", "stream_url": "https://h.example/a#b.m3u8"],
            ["name": "", "stream_url": "https://h.example/4.m3u8"],
            ["name": "A$B#C", "stream_url": "rtmps://r.example/live/5"],
            ["stream_url": "HTTPS://h.example/6.m3u8"],
        ])])
        let lines = try #require(try list(try await spider.detailContent(ids: ["1007"])).first?["vod_play_url"] as? String)
        #expect(lines == "甲$rtmp://r.example/live/1#线路4$https://h.example/4.m3u8#A B C$rtmps://r.example/live/5")

        for signals in [[], nil] as [[[String: Any]]?] {
            KafeiSite.serve([roomPath: try roomReply(signals)])
            let item = try #require(try list(try await spider.detailContent(ids: ["1007"])).first as? [String: String])
            #expect(item["vod_id"] == "1007" && item["vod_play_url"] == "")
        }
        KafeiSite.serve([:] as [String: Data])
        #expect(try list(try await spider.detailContent(ids: ["10 07"])).isEmpty && KafeiSite.requests.isEmpty)
    }

    // D5 test 6.
    @Test func playHandsBackPlayableUrlsWithoutAHeader() async throws {
        let spider = try await kafei()
        for url in [originalSound, "rtmp://r.example/live/1", "rtmps://r.example/live/1"] {
            let play = try object(try await spider.playerContent(flag: "咖啡体育", id: url, vipFlags: []))
            #expect(play["url"] as? String == url && play["parse"] as? Int == 0 && play["header"] == nil)
        }
        for url in ["ftp://x", "abc", "https://h.example/a#b"] {
            #expect(try object(try await spider.playerContent(flag: "咖啡体育", id: url, vipFlags: []))["url"] as? String == "")
        }
    }

    // D5 test 7.
    @Test func aServerErrorSaysWhichHostFailed() async throws {
        let spider = try await kafei()
        KafeiSite.serve([schedulePath: (500, Data())])
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "kafeizhibo.cc")) {
            _ = try await spider.categoryContent(tid: "1", page: "1", filter: false, extend: [:])
        }
    }

    // D5 test 8.
    @Test func searchIsEmptyAndAsksNothing() async throws {
        KafeiSite.serve([:] as [String: Data])
        #expect(try list(try await kafei().searchContent(key: "足球", quick: false, page: "1")).isEmpty)
        #expect(KafeiSite.requests.isEmpty)
    }
}

/// `schedule-1.json` from the W-49 gate (38428 bytes), raw-deflated.
private let schedulePacked = """
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
"""

/// `room-1007.json` from the W-49 gate (1960 bytes), raw-deflated.
private let roomPacked = """
vVXdTtRAFH6VzVx4tWw77fZvE0IM+gR6R0gzOz3drbSdpjNdQbIXhnihRiSGyAUYLoQLE4gYlGiib2OX9S2c6fKzyBIhEi+a6Zk5v98538wyoiwA1DJ0vY4S
4Jx0pIR4QakUUB0FRBDUWkY5Y4kfpSFTgohErNQGG7uDrb1y97DcXxs+XR9+2Ry8+1grt1fKg/Xhi71y+/vx6nN5PDw6rPV4bfD2YPBju9z58Ovbs9GuDJAQ
Qbt+FKCW6bkOrqOUJFElN+0mdky3fhJb7iCs6460iYF0iisTkApcEFFwqRBHPZBylyXgc8pyaSQLJY/J0phY/UntOb2uz8sEmIio8n689fJ4bWWwfjTceF1b
CJ90ozZrUJbUfn59Ve58kgHRqbbfta5rUOUigCTSYCJU6CTBE52JqJGe7EsuTzVVakS1IosZCbg2OuBaACEpYuGTnHZZ3sjSzkxvGjuu17SaZlPHriW9wKKA
PCWxz6OOXBQE85d3/YxecaCKnpvvSwTP7JeRapRTtbHCcPPz4M2+atqlLt5ODRH3cyAxaoUyAahkwbIzkRIBHZYvoRYeGwuWxlEK1aBI48QvcukAdYXIeEvT
uhDHrMEY0+XXkN40NUbayTw2ErNwVR+BCNTyvCokLfIcUimLvIB+fYSCobtnOJSr2+X7g+ZFHAy9+f9xMK6NQ1bEUwLSpNFZWFrI1CCPgODBFJ4aR2NGLD4A
moOYJmAYZmhYQC1sNQ07BMP2TD3wQhzarknviMWHUQLT9t3Ze7P39XMcLfcijlXa/fnbmtE6Umzi6vJS/FPraWOuoGDMOmwMCxqkDZ6xXKQkZSSLKjRCxkSb
xLGmnGteG2PsERKEdujYYdgODGJ5sklEJ6TtmKpxqD8i91gCE/l98+gWCT0KIQTYlvTyvLZHTQAjsHXQDdrGo+gqfDVFKoGrmHo7A/kP1Lo8n5cuj5vQ/pyp
XA4ppLzLxFh155tcc6Z6ttd4lE0s6EzPLzL5LkLgK7/Y8aSmZWOzP+E1+8vL88c7xSHvQe6LSHVk5NjGrt7v/wY=
"""
