import CryptoKit
import Foundation
import Testing
@testable import WebHTVCore

// IOS-POC-57B-10 (W-77): QingtingFM.js against the replies the live API returned on 2026-10-12 (W-55 gate: radioPage
// cid 217 page 1, radio 1259) and hand-made edge replies, following the W-64 design (qist-qingtingfm-gate-2026-10-12.md D3–D5).

/// Answers webbff.qtfm.cn and webapi.qtfm.cn by path and remembers every request's URL, body and headers.
final class QtfmSite: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var seen: [(url: URL, body: String, headers: [String: String])] = []

    static func serve(_ served: [String: Data], status: Int = 200) {
        lock.withLock { replies = served.mapValues { (status, $0) }; seen = [] }
    }
    static var requests: [(url: URL, body: String, headers: [String: String])] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["webbff.qtfm.cn", "webapi.qtfm.cn"].contains(request.url?.host ?? "")
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
        let reply = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.seen.append((url, String(decoding: body, as: UTF8.self), request.allHTTPHeaderFields ?? [:]))
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

private func radioPage217() throws -> Data { try fixture(radioPagePacked, sha256: "4b41c6c801fa22630b710fdbc260c271aa69e13522a8c4104291991ea6d437e9") }
private func radio1259() throws -> Data { try fixture(radioPacked, sha256: "a9875ab5eaa673dcb94b64a2672936c89d05cee557165c632db7f6cad00c6f4e") }

/// The body the gate sent and got 12 stations for (`radioPage-request.json`), byte for byte.
private let gateQuery = #"{"query":"{\n    radioPage(cid:217, page:1){\n      contents\n    }\n  }"}"#
private let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"

private func qingtingFM() async throws -> JavaScriptSpiderRuntime {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QtfmSite.self]
    let registry = SpiderRegistry.bundled()
    let runtime = try JavaScriptSpiderRuntime(
        name: "QingtingFM", script: try #require(registry.entry(for: "csp_QingtingFM")?.script), prelude: registry.prelude,
        storage: SpiderStorage(siteKey: "QingtingFM-test", defaults: UserDefaults(suiteName: "QingtingFM-test")!),
        session: URLSession(configuration: configuration))
    try await runtime.initialize(extend: "")
    return runtime
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func list(_ text: String) throws -> [[String: Any]] {
    try #require(try object(text)["list"] as? [[String: Any]])
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

private func stations(_ items: [Any]) throws -> Data {
    try json(["data": ["radioPage": ["contents": ["items": items, "count": items.count]]]])
}

@Suite(.serialized) struct QingtingFMSpiderTests {
    @Test func homeOffersUpstreamsFortyFourClassesWithoutTheNetwork() async throws {
        QtfmSite.serve([:])
        let classes = try #require(try object(try await qingtingFM().homeContent(filter: false))["class"] as? [[String: String]])
        #expect(classes.count == 44)
        #expect(classes.first == ["type_id": "217", "type_name": "广东"] && classes.last == ["type_id": "434", "type_name": "方言"])
        #expect(classes.map { $0["type_id"]! }.joined(separator: ",") == "217,99,3,5,7,83,19,31,44,59,69,85,111,129,139,151,169,187,202,239,254,257,"
                + "259,281,291,316,327,351,357,308,342,433,442,429,439,432,441,430,431,440,438,435,436,434")
        #expect(QtfmSite.requests.isEmpty)
    }

    @Test func aRegionPostsUpstreamsQueryAndMapsTheSavedReply() async throws {
        QtfmSite.serve(["/www": try radioPage217()])
        let page = try object(try await qingtingFM().categoryContent(tid: "217", page: "1", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.count == 12 && page["page"] as? Int == 1 && page["pagecount"] as? Int == 2 && page["limit"] as? Int == 12)
        #expect(items.first?["vod_id"] as? String == "1259" && items.first?["vod_name"] as? String == "广东珠江经济电台")
        #expect(items.first?["vod_pic"] as? String == "https://pic.qtfm.cn/2015/0209/20150209212831195.jpg")
        #expect(items.first?["vod_remarks"] as? String == "正在直播： 大湾区财富通")
        let sent = try #require(QtfmSite.requests.last)
        #expect(sent.url.absoluteString == "https://webbff.qtfm.cn/www" && sent.body == gateQuery)
        #expect(sent.headers["Content-Type"] == "application/json" && sent.headers["User-Agent"] == chrome
                && sent.headers["Referer"] == "https://www.qtfm.cn")
    }

    @Test func aTidThatIsNotANumberSendsNothingAndCateIdWins() async throws {
        let spider = try await qingtingFM()
        QtfmSite.serve(["/www": try radioPage217()])
        for tid in ["217){x}", "abc", ""] {
            #expect(try list(try await spider.categoryContent(tid: tid, page: "1", filter: false, extend: [:])).isEmpty)
        }
        #expect(QtfmSite.requests.isEmpty)
        _ = try await spider.categoryContent(tid: "217", page: "x", filter: false, extend: ["cateId": "99"])
        #expect(QtfmSite.requests.last?.body == gateQuery.replacingOccurrences(of: "cid:217", with: "cid:99"))
        QtfmSite.serve(["/www": try stations([
            ["id": 1, "title": "http 图", "imgUrl": "http://pic.qtfm.cn/a.jpg"],
            ["id": "x", "title": "坏 id"],
            "不是对象",
            ["id": "2", "title": "字符串 id", "imgUrl": "https://pic.qtfm.cn/b.jpg"],
        ])])
        let page = try object(try await spider.categoryContent(tid: "217", page: "3", filter: false, extend: [:]))
        let items = try #require(page["list"] as? [[String: Any]])
        #expect(items.map { $0["vod_id"] as? String } == ["1", "2"])
        #expect(items.map { $0["vod_pic"] as? String } == ["http://pic.qtfm.cn/a.jpg", "https://pic.qtfm.cn/b.jpg"])
        #expect(page["page"] as? Int == 3 && page["pagecount"] as? Int == 3)
    }

    @Test func aStationsDetailPlaysItsOwnId() async throws {
        QtfmSite.serve(["/api/pc/radio/1259": try radio1259()])
        let vod = try #require(try list(try await qingtingFM().detailContent(ids: ["1259"])).first)
        #expect(vod["vod_id"] as? String == "1259" && vod["vod_name"] as? String == "广东珠江经济电台")
        #expect(vod["vod_pic"] as? String == "http://pic.qtfm.cn/2015/0209/20150209212831195.jpg")
        #expect((vod["vod_content"] as? String)?.hasPrefix("珠江经济广播电台，FM97.4") == true)
        #expect(vod["vod_play_from"] as? String == "蜻蜓FM" && vod["vod_play_url"] as? String == "广东珠江经济电台$1259")
        let sent = try #require(QtfmSite.requests.last)
        #expect(sent.url.absoluteString == "https://webapi.qtfm.cn/api/pc/radio/1259")
        #expect(sent.headers["User-Agent"] == chrome && sent.headers["Referer"] == "https://www.qtfm.cn")
    }

    @Test func aDetailWithoutAUsableAlbumIsEmptyAndABadIdSendsNothing() async throws {
        let spider = try await qingtingFM()
        for body in [#"{"pList":[]}"#, #"{"album":{"id":"x","title":"t"}}"#, #"{"album":"none"}"#] {
            QtfmSite.serve(["/api/pc/radio/1259": Data(body.utf8)])
            #expect(try list(try await spider.detailContent(ids: ["1259"])).isEmpty)
        }
        QtfmSite.serve(["/api/pc/radio/1259": try json(["album": ["id": 1259, "title": "台$名#"]])])
        #expect(try list(try await spider.detailContent(ids: ["1259"])).first?["vod_play_url"] as? String == "台 名 $1259")
        QtfmSite.serve([:])
        #expect(try list(try await spider.detailContent(ids: ["x"])).isEmpty)
        #expect(try list(try await spider.detailContent(ids: ["../1259"])).isEmpty)
        #expect(QtfmSite.requests.isEmpty)
    }

    @Test func playIsTheFixedLiveStreamWithUAAndReferer() async throws {
        let spider = try await qingtingFM()
        let played = try object(try await spider.playerContent(flag: "蜻蜓FM", id: "1259", vipFlags: []))
        #expect(played["url"] as? String == "https://lhttp-hw.qtfm.cn/live/1259/64k.mp3" && played["parse"] as? Int == 0)
        #expect(played["header"] as? [String: String] == ["User-Agent": chrome, "Referer": "https://www.qtfm.cn"])
        for bad in ["x", "1259/../1", ""] {
            #expect(try object(try await spider.playerContent(flag: "", id: bad, vipFlags: []))["url"] as? String == "")
        }
    }

    @Test func aServerErrorOnARegionIsReported() async throws {
        let spider = try await qingtingFM()
        QtfmSite.serve(["/www": Data()], status: 500)
        await #expect(throws: SiteUnreachable(.httpStatus(500), host: "webbff.qtfm.cn")) {
            _ = try await spider.categoryContent(tid: "217", page: "1", filter: false, extend: [:])
        }
    }

    @Test func searchIsEmptyWithoutARequest() async throws {
        QtfmSite.serve([:])
        #expect(try list(try await qingtingFM().searchContent(key: "广东", quick: false, page: "1")).isEmpty)
        #expect(QtfmSite.requests.isEmpty)
    }
}

/// `radioPage-217-p1.json` from the W-55 gate (2718 bytes), raw-deflated.
private let radioPagePacked = """
jVVdTxtHFH3vr6j22bFnZmd2ZnirlKgSiZQq6sdDVVnGdokR9jp43QRFSCkNDQQCUcJHw0eggNKqQIEGgu2Q+M94du2n/IXe3cWwa3shlrAOC3vn3HPPPfNQ
y6SslNb3UBtJZXLmN6nBrPtL2ixY2YJVcnHOyuYB/Agoo/VhwmRMy+UHvxsZ1vq0RKKYS8fvWT/n4+lCgiDMEogg6SEXEEyEjrFk8aHioBbTrJw1DCdoqlpv
VFaduQ37cN15P2cfzzrzx2ruAP4lPWyWLThI17ER04rDqdG0WS7AE4IQooYe0zLZUhpq2HtbavVvZ+XIfrH36XT5S7X9l139qGZqzaNNtT/TerQM1YpmJp0q
WdkRrxVoQOcMIxHTyqXsSCGVd8k4OxvNqZrL7m45PwAP7lpWsa+zNYISiBLqIRcgTCRF0FfWbex+NjdgJs8KXu8/L+k/dw/WMNcJF4Qypo2NxXw21LhMTe9I
RM6OhC9KpI7jxUK3lGp9VlXGG9VptRUUkSCDhETEiOmGENEienWchVdQx16taedEBeWRTEslM4GlSGADGZILKQRDLHnzxu3RIT76oNTWqM3YfrrQPH7cON1Q
/7z4dDrZHP8TjoQ2PApTAfZY8k72FHzBI9n7pZzd3UblkVOrQ/FGZdqt2W4DE46uboNxYiAiYLyEJ/t/ET+w74du3elq4+RQrb5VE5Ot+WnoOcjbUzjAW+oG
pzKSdutlvTV/3Kq9URPTra3ZXrY13GUIeLY5vqjqS92evZcrDFrwc81tbADFy8VUbrRciKfNvLuUJFHKFVLJYXMQWhVgRaGDntcEeiDQ2YqGnOz3eH5Y0M3n
b1+4GRPXbdF2hnCAMPCQCxBlkhk97dyobcP+dtkZS0LDwiKMRbQf7LUD9aTW+PCyOf5fwAPCuCLCdKL7EQYAI11gHRa3I8Ja1W11eNgVWxCQKERRUMQMFE3x
t4lm/QQyUE1Ueg1eUmKER29/fGy/3gmp/jmeNihlFFpHjCdvfGX2Z27euvNtp6d99VvrbxvV5z3U71hHAyN0SSDbu5tqEUY5rbZ7RjHhFNNQa61Xk86ThdbK
/lVhjHk7jDH3wpghruvhMPZsigJZK6j4jAiDawcJA+ZoiOTo7fuZ4vWvZbGHTurktb140Fp632kBSQ0elglxSkikTNIgvuD20js1EcwqRi/bJpxAEksPuQB8
inXRe6A+UT9iL4gaoF6IKKSURNHbpJ5NquezzZl3zf21xunyxd0gGbtsoQyYFSYecgFxY4II1GPzQVN/8zupMsllB1XKUbSm9od/ncnfYfHV2kov61FmsI6t
2vzVXp9z6n90RWD7D/1mNhe8ucUVw2Ht4QBAOuIY9x6OerZkL1ad+XX7qGtElPNwmuhwJaHoNHFqm/bWVPPpoTp9FLz0LuPq7pLwYhl2CQCSDOu0k2ujsnce
d6q+A3YVInDnMczDyUykhMajveSV8H2vVg9U5Y029hNU819mcgw+X/wP
"""

/// `radio-1259.json` from the W-55 gate (21062 bytes), raw-deflated.
private let radioPacked = """
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
"""
